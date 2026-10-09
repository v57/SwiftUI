import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Bionic)
import Bionic
#endif

/// Types that want to control how the graph compares them (e.g. `State`, which is graph-managed and
/// must never make a view look "changed").
public protocol _GraphComparable {
    static func _isIdentical(_ lhs: Self, _ rhs: Self) -> Bool
}

/// Structural value comparison used for equality cut-off (mirrors SwiftUI's `compareValues`):
///
///  1. `_GraphComparable` types use their own rule.
///  2. POD types are compared bitwise.
///  3. `Equatable` types use `==`.
///  4. Structs and tuples are compared field by field.
///  5. Class references compare by identity; closures by (function, context) pointer.
///  6. Existentials compare dynamic type then value.
///  7. Anything else (non-POD enums, weak refs, ...) is conservatively "different".
public enum GraphComparison {
    public typealias RawComparator = @Sendable (UnsafeRawPointer, UnsafeRawPointer) -> Bool

    private static let cache = LockedValue<[ObjectIdentifier: RawComparator]>([:])

    public static func isIdentical<T>(_ lhs: T, _ rhs: T) -> Bool {
        let comparator = comparator(for: T.self)
        return withUnsafePointer(to: lhs) { l in
            withUnsafePointer(to: rhs) { r in comparator(UnsafeRawPointer(l), UnsafeRawPointer(r)) }
        }
    }

    public static func never<T>(_: T, _: T) -> Bool { false }

    public static func comparator(for type: Any.Type) -> RawComparator {
        let key = ObjectIdentifier(type)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let made = makeComparator(for: type)
        cache.withLock { $0[key] = made }
        return made
    }

    private static func makeComparator(for type: Any.Type) -> RawComparator {
        if let custom = type as? any _GraphComparable.Type {
            return customComparator(custom)
        }
        if _isPOD(type) {
            let size = RuntimeReflection.size(of: type)
            if size == 0 { return { _, _ in true } }
            return { memcmp($0, $1, size) == 0 }
        }
        if let equatable = type as? any Equatable.Type {
            return equatableComparator(equatable)
        }
        switch RuntimeReflection.kind(of: type) {
        case .struct, .tuple:
            let fields = RuntimeReflection.fields(of: type)
            if fields.isEmpty { return { _, _ in true } }
            var parts: [(Int, RawComparator)] = []
            for field in fields {
                guard field.isStrong || RuntimeReflection.kind(of: field.type) != .class else {
                    return { _, _ in false } // weak/unowned storage: be conservative
                }
                parts.append((field.offset, comparator(for: field.type)))
            }
            let frozen = parts
            return { lhs, rhs in
                for (offset, compare) in frozen where !compare(lhs + offset, rhs + offset) {
                    return false
                }
                return true
            }
        case .class:
            return { lhs, rhs in
                lhs.load(as: UnsafeRawPointer.self) == rhs.load(as: UnsafeRawPointer.self)
            }
        case .function:
            let size = RuntimeReflection.size(of: type)
            return { memcmp($0, $1, size) == 0 }
        case .optional:
            return optionalComparator(RuntimeReflection.optionalWrappedType(type), optionalType: type)
        case .existential:
            return existentialComparator(type)
        case .metatype:
            return { lhs, rhs in
                lhs.load(as: UnsafeRawPointer.self) == rhs.load(as: UnsafeRawPointer.self)
            }
        case .enum, .other:
            return { _, _ in false }
        }
    }

    private static func customComparator<T: _GraphComparable>(_: T.Type) -> RawComparator {
        { lhs, rhs in
            T._isIdentical(lhs.assumingMemoryBound(to: T.self).pointee, rhs.assumingMemoryBound(to: T.self).pointee)
        }
    }

    private static func equatableComparator<T: Equatable>(_: T.Type) -> RawComparator {
        { lhs, rhs in
            lhs.assumingMemoryBound(to: T.self).pointee == rhs.assumingMemoryBound(to: T.self).pointee
        }
    }

    private static func optionalComparator(_ wrapped: Any.Type, optionalType: Any.Type) -> RawComparator {
        func open<W>(_: W.Type) -> RawComparator {
            let inner = comparator(for: W.self)
            return { lhs, rhs in
                let l = lhs.assumingMemoryBound(to: Optional<W>.self).pointee
                let r = rhs.assumingMemoryBound(to: Optional<W>.self).pointee
                switch (l, r) {
                case (nil, nil): return true
                case (nil, _), (_, nil): return false
                case let (lv?, rv?):
                    return withUnsafePointer(to: lv) { lp in
                        withUnsafePointer(to: rv) { rp in inner(UnsafeRawPointer(lp), UnsafeRawPointer(rp)) }
                    }
                }
            }
        }
        return open(wrapped)
    }

    private static func existentialComparator(_ type: Any.Type) -> RawComparator {
        func open<E>(_: E.Type) -> RawComparator {
            { lhs, rhs in
                let l: Any = lhs.assumingMemoryBound(to: E.self).pointee
                let r: Any = rhs.assumingMemoryBound(to: E.self).pointee
                return compareAny(l, r)
            }
        }
        return open(type)
    }

    /// Compares two type-erased values (dynamic types must match).
    public static func compareAny(_ lhs: Any, _ rhs: Any) -> Bool {
        let lhsType = type(of: lhs)
        guard lhsType == type(of: rhs) else { return false }
        if RuntimeReflection.kind(of: lhsType) == .class {
            // Opening an `Any` that holds a class-bound existential can re-yield the existential
            // type itself; compare instance identity directly instead.
            return (lhs as AnyObject) === (rhs as AnyObject)
        }
        func open<T>(_ value: T) -> Bool {
            guard let other = rhs as? T else { return false }
            return isIdentical(value, other)
        }
        return _openExistential(lhs, do: open)
    }
}

/// Minimal lock-protected box (`Synchronization.Mutex` needs macOS 15; we support 14).
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
