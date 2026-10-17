import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@MainActor @preconcurrency
public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = _ViewModifier_Content<Self>

    @ViewBuilder @MainActor @preconcurrency func body(content: Content) -> Body

    static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs
    static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs, body: @escaping @MainActor (_ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs
}

extension ViewModifier where Body == Never {
    public func body(content: Content) -> Never { primitiveBody(Self.self) }
}

extension ViewModifier {
    /// Custom modifiers: evaluate `body(content:)` (with dynamic properties of the modifier) and
    /// route `_ViewModifier_Content` back to the wrapped view.
    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        precondition(Body.self != Never.self, "\(Self.self) is a primitive modifier but does not implement _makeView")
        let path = inputs.path.appending(typeName(Self.self))
        let modifierBody = makeBodyAttribute(view: modifier.attribute, inputs: inputs.listInputs, path: path) {
            $0.body(content: _ViewModifier_Content())
        }
        var bodyInputs = inputs
        bodyInputs.path = path
        bodyInputs.modifierContent = ModifierContentEntry(modifierType: ObjectIdentifier(Self.self), make: body, previous: inputs.modifierContent)
        return Body._makeView(view: _GraphValue(modifierBody), inputs: bodyInputs)
    }

    /// In a list context a modifier applies to each element (like SwiftUI).
    ///
    /// The content list is built before the modifier's body runs, so it reads a proxy environment
    /// that is rebound to the environment the body gives `content` (e.g. `content.lineLimit(3)`)
    /// when an element is made. With several elements the most recently made one wins (their
    /// bodies normally produce the same environment); when it goes away the proxy falls back to
    /// the modifier's outer environment.
    public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs, body: @escaping @MainActor (_ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        let outer = inputs.environment
        let proxy = Attribute<EnvironmentValues>(inputs.subgraph)
        proxy.setLabel("modifier content environment \(inputs.path)")
        proxy.setRule { outer.value }
        let binding = _ContentEnvironmentBinding(outer: outer)
        var contentListInputs = inputs
        contentListInputs.environment = proxy
        let content = body(contentListInputs)
        let list = content.list.mapElements(in: inputs.subgraph) { element in
            ViewListElement(traits: element.traits) { placement in
                Self._makeView(modifier: modifier, inputs: inputs.instantiate(placement)) { contentInputs in
                    let environment = contentInputs.environment
                    if environment !== outer {
                        binding.push(environment, proxy: proxy)
                        contentInputs.subgraph.onDestroy { [weak proxy] in
                            guard let proxy else { return }
                            binding.remove(environment, proxy: proxy)
                        }
                    }
                    return element.make(contentInputs)
                }
            }
        }
        return _ViewListOutputs(list: list)
    }
}

/// Environments of a modifier's live elements; the content proxy forwards the newest one (or the
/// modifier's outer environment when there is none).
@MainActor
final class _ContentEnvironmentBinding {
    let outer: Attribute<EnvironmentValues>
    private var live: [Attribute<EnvironmentValues>] = []
    init(outer: Attribute<EnvironmentValues>) { self.outer = outer }

    func push(_ environment: Attribute<EnvironmentValues>, proxy: Attribute<EnvironmentValues>) {
        if live.last === environment { return }
        live.removeAll { $0 === environment }
        live.append(environment)
        bind(proxy)
    }

    func remove(_ environment: Attribute<EnvironmentValues>, proxy: Attribute<EnvironmentValues>) {
        let wasCurrent = live.last === environment
        live.removeAll { $0 === environment }
        if wasCurrent { bind(proxy) }
    }

    private func bind(_ proxy: Attribute<EnvironmentValues>) {
        let target = live.last ?? outer
        proxy.setRule { target.value }
    }
}

/// Placeholder for the content inside a custom modifier's body.
public struct _ViewModifier_Content<Modifier: ViewModifier>: View {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        var entry = inputs.modifierContent
        let target = ObjectIdentifier(Modifier.self)
        while let current = entry, current.modifierType != target { entry = current.previous }
        guard let entry else { fatalError("_ViewModifier_Content used outside of its modifier") }
        var contentInputs = inputs
        contentInputs.modifierContent = entry.previous
        return entry.make(contentInputs)
    }
}

// MARK: - ModifiedContent

public struct ModifiedContent<Content, Modifier> {
    public var content: Content
    public var modifier: Modifier

    public init(content: Content, modifier: Modifier) {
        self.content = content
        self.modifier = modifier
    }
}

extension ModifiedContent: View where Content: View, Modifier: ViewModifier {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let modifier = view.project(inputs) { $0.modifier }
        let content = view.project(inputs) { $0.content }
        return Modifier._makeView(modifier: modifier, inputs: inputs) { inputs in
            Content._makeView(view: content, inputs: inputs)
        }
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let modifier = view.project(inputs) { $0.modifier }
        let content = view.project(inputs) { $0.content }
        return Modifier._makeViewList(modifier: modifier, inputs: inputs) { inputs in
            Content._makeViewList(view: content, inputs: inputs)
        }
    }
}

extension ModifiedContent: ViewModifier where Content: ViewModifier, Modifier: ViewModifier {
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let first = modifier.project(inputs) { $0.content }
        let second = modifier.project(inputs) { $0.modifier }
        return Content._makeView(modifier: first, inputs: inputs) { inputs in
            Modifier._makeView(modifier: second, inputs: inputs, body: body)
        }
    }

    public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs, body: @escaping @MainActor (_ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        let first = modifier.project(inputs) { $0.content }
        let second = modifier.project(inputs) { $0.modifier }
        return Content._makeViewList(modifier: first, inputs: inputs) { inputs in
            Modifier._makeViewList(modifier: second, inputs: inputs, body: body)
        }
    }
}

extension View {
    public func modifier<M>(_ modifier: M) -> ModifiedContent<Self, M> {
        ModifiedContent(content: self, modifier: modifier)
    }
}

extension ViewModifier {
    public func concat<T>(_ modifier: T) -> ModifiedContent<Self, T> {
        ModifiedContent(content: self, modifier: modifier)
    }
}

public struct EmptyModifier: ViewModifier {
    public static let identity = EmptyModifier()
    public init() {}
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        body(inputs)
    }

    public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs, body: @escaping @MainActor (_ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        body(inputs)
    }
}

/// Base for primitive modifiers that only transform the environment: they apply to the list
/// inputs too, so composite views inside the content see the modified environment.
protocol EnvironmentModifier: ViewModifier where Body == Never {
    static func makeEnvironment(modifier: Attribute<Self>, environment: Attribute<EnvironmentValues>, subgraph: Subgraph) -> Attribute<EnvironmentValues>
}

extension EnvironmentModifier {
    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        var inputs = inputs
        inputs.environment = makeEnvironment(modifier: modifier.attribute, environment: inputs.environment, subgraph: inputs.subgraph)
        return body(inputs)
    }

    public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs, body: @escaping @MainActor (_ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        var inputs = inputs
        inputs.environment = makeEnvironment(modifier: modifier.attribute, environment: inputs.environment, subgraph: inputs.subgraph)
        return body(inputs)
    }
}
