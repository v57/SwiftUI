// Minimal runtime reflection built on the stable Swift runtime entry points that back `Mirror`.
// Unlike `Mirror` it yields field *offsets*, which lets us compare view values field-by-field
// without boxing and install dynamic properties (State, Environment, ...) in place.

typealias _NameFreeFunc = @convention(c) (UnsafePointer<CChar>?) -> Void

struct _FieldReflectionMetadata {
    var name: UnsafePointer<CChar>? = nil
    var freeFunc: _NameFreeFunc? = nil
    var isStrong: Bool = false
    var isVar: Bool = false
}

@_silgen_name("swift_reflectionMirror_recursiveCount")
func _swiftui2_recursiveCount(_: Any.Type) -> Int

@_silgen_name("swift_reflectionMirror_recursiveChildMetadata")
func _swiftui2_recursiveChildMetadata(_: Any.Type, index: Int, fieldMetadata: UnsafeMutablePointer<_FieldReflectionMetadata>) -> Any.Type

@_silgen_name("swift_reflectionMirror_recursiveChildOffset")
func _swiftui2_recursiveChildOffset(_: Any.Type, index: Int) -> Int

public enum TypeKind: Equatable, Sendable {
    case `struct`, `enum`, optional, tuple, function, existential, metatype, `class`, other
}

public enum RuntimeReflection {
    public struct Field: Sendable {
        public let name: String
        public let offset: Int
        public let type: Any.Type
        public let isStrong: Bool
    }

    public static func kind(of type: Any.Type) -> TypeKind {
        let raw = unsafeBitCast(type, to: UnsafePointer<Int>.self).pointee
        switch raw {
        case 0x200: return .struct
        case 0x201: return .enum
        case 0x202: return .optional
        case 0x301: return .tuple
        case 0x302: return .function
        case 0x303: return .existential
        case 0x304: return .metatype
        case 0, 0x305...0x7FF: // 0 = Swift class without ObjC interop; others are runtime-private kinds
            return raw == 0 ? .class : .other
        default:
            // On Apple platforms a class metadata kind word is the ObjC isa pointer.
            return raw > 0x7FF ? .class : .other
        }
    }

    /// Stored fields of a struct or tuple, in declaration order.
    public static func fields(of type: Any.Type) -> [Field] {
        let count = _swiftui2_recursiveCount(type)
        var result: [Field] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            var metadata = _FieldReflectionMetadata()
            let fieldType = _swiftui2_recursiveChildMetadata(type, index: index, fieldMetadata: &metadata)
            let name = metadata.name.map { String(cString: $0) } ?? ""
            metadata.freeFunc?(metadata.name)
            let offset = _swiftui2_recursiveChildOffset(type, index: index)
            result.append(Field(name: name, offset: offset, type: fieldType, isStrong: metadata.isStrong))
        }
        return result
    }

    /// The `Wrapped` type of an `Optional<Wrapped>` metatype.
    public static func optionalWrappedType(_ type: Any.Type) -> Any.Type {
        // Optional metadata: [kind, description, generic argument 0]
        let words = unsafeBitCast(type, to: UnsafePointer<Any.Type>.self)
        return words[2]
    }

    public static func size(of type: Any.Type) -> Int {
        func open<T>(_: T.Type) -> Int { MemoryLayout<T>.size }
        return open(type)
    }
}
