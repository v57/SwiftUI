import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@resultBuilder @MainActor
public enum ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }

    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }

    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<(repeat each Content)> {
        TupleView((repeat each content))
    }

    public static func buildExpression<Content: View>(_ content: Content) -> Content { content }

    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }

    public static func buildEither<TrueContent: View, FalseContent: View>(first: TrueContent) -> _ConditionalContent<TrueContent, FalseContent> {
        _ConditionalContent(storage: .trueContent(first))
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(second: FalseContent) -> _ConditionalContent<TrueContent, FalseContent> {
        _ConditionalContent(storage: .falseContent(second))
    }

    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
}

// MARK: - EmptyView

public struct EmptyView: View, Equatable {
    public init() {}
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let tracer = inputs.tracer
        let path = inputs.path
        return _ViewOutputs(layout: inputs.makeLayoutAttribute { EmptyLayoutComputer(path: path, tracer: tracer) })
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs { .empty }
}

// MARK: - TupleView

/// Built by `ViewBuilder` for multiple children. `T` is a tuple of views; elements are found by
/// runtime reflection of the tuple layout (once per type).
public struct TupleView<T>: View {
    public var value: T
    public init(_ value: T) { self.value = value }
    public var body: Never { primitiveBody(Self.self) }

    typealias Element = TupleViewElement

    @MainActor static var elements: [Element] {
        if let cached = TupleLayoutCache.layouts[ObjectIdentifier(T.self)] { return cached }
        let fields = RuntimeReflection.kind(of: T.self) == .tuple ? RuntimeReflection.fields(of: T.self) : []
        let elements = fields.map { field -> Element in
            guard let viewType = field.type as? any View.Type else {
                fatalError("TupleView element \(field.type) is not a View")
            }
            return Element(offset: field.offset, type: viewType)
        }
        TupleLayoutCache.layouts[ObjectIdentifier(T.self)] = elements
        return elements
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        var nodes: [ViewList.Node] = []
        for (index, element) in elements.enumerated() {
            nodes.append(.nested(.index(index), makeElementList(element.type, offset: element.offset, view: view, inputs: inputs.with(path: "[\(index)]"))))
        }
        return _ViewListOutputs(list: ViewList(nodes: nodes))
    }

    private static func makeElementList<V: View>(_: V.Type, offset: Int, view: _GraphValue<Self>, inputs: _ViewListInputs) -> ViewList {
        let element = view.project(inputs) { tuple -> V in
            withUnsafePointer(to: tuple.value) { UnsafeRawPointer($0).load(fromByteOffset: offset, as: V.self) }
        }
        return V._makeViewList(view: element, inputs: inputs).list
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

struct TupleViewElement {
    let offset: Int
    let type: any View.Type
}

@MainActor
enum TupleLayoutCache {
    static var layouts: [ObjectIdentifier: [TupleViewElement]] = [:]
}

// MARK: - Group

public struct Group<Content> {
    let content: Content
}

extension Group: View where Content: View {
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        Content._makeView(view: view.project(inputs) { $0.content }, inputs: inputs)
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs)
    }
}
