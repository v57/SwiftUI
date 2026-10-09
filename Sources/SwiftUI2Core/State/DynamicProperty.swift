import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A stored property of a view that the graph keeps up to date. Mirrors `SwiftUI.DynamicProperty`.
/// User-defined dynamic properties are structs whose fields are themselves dynamic properties;
/// their `update()` is called after their fields were installed and before `body` runs.
@MainActor @preconcurrency
public protocol DynamicProperty {
    mutating func update()
}

extension DynamicProperty {
    public mutating func update() {}
}

/// Built-in dynamic properties implement this to connect themselves to persistent per-view
/// storage. `slot` is owned by the view's identity and survives across body evaluations.
@MainActor
protocol _DynamicPropertyInstallable: DynamicProperty {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext)
}

/// Per-view context shared by all dynamic properties of a view.
@MainActor
final class DynamicPropertyContext {
    unowned let host: ViewGraph
    let subgraph: Subgraph
    let environment: Attribute<EnvironmentValues>
    let path: ViewPath
    /// The body attribute; external invalidations (objectWillChange) target it.
    weak var owner: AnyAttribute?

    init(host: ViewGraph, subgraph: Subgraph, environment: Attribute<EnvironmentValues>, path: ViewPath) {
        self.host = host
        self.subgraph = subgraph
        self.environment = environment
        self.path = path
    }
}

/// Locates dynamic property fields of a view type (once per type, by runtime reflection of field
/// offsets) and installs them in place before each body evaluation.
@MainActor
final class DynamicPropertyBuffer {
    enum Entry {
        case install(any _DynamicPropertyInstallable.Type, offset: Int, slot: Int)
        case update(any DynamicProperty.Type, offset: Int)
    }

    private static var layouts: [ObjectIdentifier: [Entry]] = [:]

    private let entries: [Entry]
    private var slots: [AnyObject?]

    init(for type: Any.Type) {
        let key = ObjectIdentifier(type)
        let entries: [Entry]
        if let cached = Self.layouts[key] {
            entries = cached
        } else {
            var collected: [Entry] = []
            var slotCount = 0
            Self.collect(type, base: 0, into: &collected, slotCount: &slotCount)
            entries = collected
            Self.layouts[key] = collected
        }
        self.entries = entries
        let slotCount = entries.reduce(0) { count, entry in
            if case .install = entry { return count + 1 }
            return count
        }
        self.slots = Array(repeating: nil, count: slotCount)
    }

    var isEmpty: Bool { entries.isEmpty }

    private static func collect(_ type: Any.Type, base: Int, into entries: inout [Entry], slotCount: inout Int) {
        guard RuntimeReflection.kind(of: type) == .struct else { return }
        for field in RuntimeReflection.fields(of: type) {
            let offset = base + field.offset
            if let installable = field.type as? any _DynamicPropertyInstallable.Type {
                entries.append(.install(installable, offset: offset, slot: slotCount))
                slotCount += 1
            } else if let dynamic = field.type as? any DynamicProperty.Type {
                collect(field.type, base: offset, into: &entries, slotCount: &slotCount)
                entries.append(.update(dynamic, offset: offset))
            }
        }
    }

    func install<V>(into value: inout V, context: DynamicPropertyContext) {
        if entries.isEmpty { return }
        withUnsafeMutablePointer(to: &value) { pointer in
            let raw = UnsafeMutableRawPointer(pointer)
            for entry in entries {
                switch entry {
                case let .install(type, offset, slot):
                    Self.install(type, at: raw + offset, slot: &slots[slot], context: context)
                case let .update(type, offset):
                    Self.update(type, at: raw + offset)
                }
            }
        }
    }

    private static func install<P: _DynamicPropertyInstallable>(_: P.Type, at pointer: UnsafeMutableRawPointer, slot: inout AnyObject?, context: DynamicPropertyContext) {
        pointer.assumingMemoryBound(to: P.self).pointee._install(slot: &slot, context: context)
    }

    private static func update<P: DynamicProperty>(_: P.Type, at pointer: UnsafeMutableRawPointer) {
        pointer.assumingMemoryBound(to: P.self).pointee.update()
    }
}
