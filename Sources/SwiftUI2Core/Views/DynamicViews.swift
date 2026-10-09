import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Keyed dynamic lists (if/else, Optional, .id, AnyView)

@MainActor
private final class KeyedListState<Key: Hashable> {
    var key: Key?
    var subgraph: Subgraph?
    var list: ViewList?
}

/// A list whose content is rebuilt (fresh subgraph → fresh state) whenever `key` changes.
@MainActor
func makeKeyedList<Key: Hashable>(
    inputs: _ViewListInputs,
    key: Attribute<Key>,
    component: @escaping @MainActor (Key) -> ViewListID.Component?,
    build: @escaping @MainActor (Key, _ViewListInputs) -> ViewList
) -> ViewList {
    let state = KeyedListState<Key>()
    let parent = inputs.subgraph
    parent.onDestroy { state.subgraph = nil }
    let attribute = Attribute<ViewList>(inputs.subgraph, isEqual: ViewList.isStructurallyEqual) {
        let current = key.value
        if state.key != current || state.list == nil {
            state.subgraph?.destroy()
            let subgraph = parent.makeChild()
            state.subgraph = subgraph
            state.key = current
            state.list = AnyAttribute.withoutDependencies { build(current, inputs.with(subgraph: subgraph)) }
        }
        return ViewList(nodes: [.nested(component(current), state.list!)])
    }
    attribute.label = "keyed list \(inputs.path)"
    return ViewList(nodes: [.dynamic(nil, attribute)])
}

@MainActor
final class LastValue<Value> {
    var value: Value?
}

// MARK: - _ConditionalContent

public struct _ConditionalContent<TrueContent, FalseContent> {
    public enum Storage {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }

    public let storage: Storage

    public init(storage: Storage) { self.storage = storage }
}

extension _ConditionalContent: View where TrueContent: View, FalseContent: View {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let isTrue = Attribute<Bool>(inputs.subgraph, isEqual: { $0 == $1 }) {
            if case .trueContent = view.attribute.value.storage { return true }
            return false
        }
        let list = makeKeyedList(inputs: inputs, key: isTrue, component: { .branch($0 ? 0 : 1) }) { isTrue, inputs in
            if isTrue {
                let last = LastValue<TrueContent>()
                let content = view.project(inputs) { conditional -> TrueContent in
                    if case .trueContent(let value) = conditional.storage { last.value = value }
                    return last.value!
                }
                return TrueContent._makeViewList(view: content, inputs: inputs).list
            } else {
                let last = LastValue<FalseContent>()
                let content = view.project(inputs) { conditional -> FalseContent in
                    if case .falseContent(let value) = conditional.storage { last.value = value }
                    return last.value!
                }
                return FalseContent._makeViewList(view: content, inputs: inputs).list
            }
        }
        return _ViewListOutputs(list: list)
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

// MARK: - Optional

extension Optional: View where Wrapped: View {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let isSome = Attribute<Bool>(inputs.subgraph, isEqual: { $0 == $1 }) { view.attribute.value != nil }
        let list = makeKeyedList(inputs: inputs, key: isSome, component: { _ in .branch(0) }) { isSome, inputs in
            guard isSome else { return ViewList(nodes: []) }
            let last = LastValue<Wrapped>()
            let content = view.project(inputs) { optional -> Wrapped in
                if let value = optional { last.value = value }
                return last.value!
            }
            return Wrapped._makeViewList(view: content, inputs: inputs).list
        }
        return _ViewListOutputs(list: list)
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

// MARK: - .id(_:)

public struct IDView<Content: View, ID: Hashable>: View {
    let content: Content
    let id: ID

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let id = Attribute<ID>(inputs.subgraph, isEqual: { $0 == $1 }) { view.attribute.value.id }
        let list = makeKeyedList(inputs: inputs, key: id, component: { .explicit(AnyHashable($0)) }) { _, inputs in
            Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs).list
        }
        return _ViewListOutputs(list: list)
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

extension View {
    public func id<ID: Hashable>(_ id: ID) -> IDView<Self, ID> { IDView(content: self, id: id) }
}

// MARK: - AnyView

@MainActor
class AnyViewStorageBase {
    let type: any View.Type
    init(type: any View.Type) { self.type = type }
    func makeViewList(view: _GraphValue<AnyView>, inputs: _ViewListInputs) -> ViewList { fatalError() }
    func isIdentical(to other: AnyViewStorageBase) -> Bool { false }
    /// The erased view.
    var anyView: any View { fatalError() }
}

@MainActor
final class AnyViewStorage<V: View>: AnyViewStorageBase {
    let view: V
    init(_ view: V) {
        self.view = view
        super.init(type: V.self)
    }

    override var anyView: any View { view }

    override func makeViewList(view: _GraphValue<AnyView>, inputs: _ViewListInputs) -> ViewList {
        let last = LastValue<V>()
        let content = view.project(inputs) { any -> V in
            if let storage = any.storage as? AnyViewStorage<V> { last.value = storage.view }
            return last.value!
        }
        return V._makeViewList(view: content, inputs: inputs).list
    }

    override func isIdentical(to other: AnyViewStorageBase) -> Bool {
        guard let other = other as? AnyViewStorage<V> else { return false }
        return GraphComparison.isIdentical(view, other.view)
    }
}

/// Type-erased view. Changing the wrapped *type* replaces the subtree (new identity); changing
/// only the value updates in place.
public struct AnyView: View {
    let storage: AnyViewStorageBase

    public init<V: View>(_ view: V) {
        if let any = view as? AnyView {
            storage = any.storage
        } else {
            storage = AnyViewStorage(view)
        }
    }

    public init<V: View>(erasing view: V) { self.init(view) }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let type = Attribute<ObjectIdentifier>(inputs.subgraph, isEqual: { $0 == $1 }) {
            ObjectIdentifier(view.attribute.value.storage.type)
        }
        let list = makeKeyedList(inputs: inputs, key: type, component: { .explicit(AnyHashable($0)) }) { _, inputs in
            let storage = AnyAttribute.withoutDependencies { view.attribute.value.storage }
            return storage.makeViewList(view: view, inputs: inputs)
        }
        return _ViewListOutputs(list: list)
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

extension AnyView: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: AnyView, _ rhs: AnyView) -> Bool {
        MainActor.assumeIsolated { lhs.storage === rhs.storage || lhs.storage.isIdentical(to: rhs.storage) }
    }
}

// MARK: - ForEach

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content> {
    public var data: Data
    public var content: (Data.Element) -> Content
    let identify: (Data.Element) -> ID
}

extension ForEach {
    /// For content protocols defined outside the core (charts, ...).
    public init(_unchecked data: Data, id: KeyPath<Data.Element, ID>, content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        self.identify = { $0[keyPath: id] }
    }
}

extension ForEach: View where Content: View {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) where Data.Element: Identifiable, ID == Data.Element.ID {
        self.data = data
        self.content = content
        self.identify = { $0.id }
    }

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        self.identify = { $0[keyPath: id] }
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let state = ForEachState<Data, ID>()
        let parent = inputs.subgraph
        let inputs = inputs.with(path: "ForEach")
        let attribute = Attribute<ViewList>(inputs.subgraph, isEqual: ViewList.isStructurallyEqual) {
            let forEach = view.attribute.value
            var ids: [ID] = []
            var index: [ID: Data.Index] = [:]
            ids.reserveCapacity(forEach.data.count)
            for position in forEach.data.indices {
                let id = forEach.identify(forEach.data[position])
                guard index[id] == nil else {
                    runtimeWarning("ForEach: the ID \(id) occurs multiple times within the collection, this will give undefined results!")
                    continue
                }
                index[id] = position
                ids.append(id)
            }
            state.index = index
            AnyAttribute.withoutDependencies {
                for id in ids where state.elements[id] == nil {
                    let subgraph = parent.makeChild()
                    let item = Attribute<Content>(subgraph)
                    item.label = "ForEach item \(id)"
                    item.setRule { [unowned item] in
                        let forEach = view.attribute.value
                        guard let position = state.index[id] else { return item.peekValue! }
                        return observingChanges(invalidating: item) { forEach.content(forEach.data[position]) }
                    }
                    let content = Content._makeViewList(view: _GraphValue(item), inputs: inputs.with(subgraph: subgraph).with(path: "#\(id)")).list
                    // ForEach tags its elements with their id unless they carry an explicit tag.
                    let tag = Attribute<AnyHashable?>(subgraph, value: AnyHashable(id))
                    let list = content.mapElements(in: subgraph) { element in
                        guard element.traits[TagTraitKey.self] == nil else { return element }
                        var copy = element
                        copy.traits[TagTraitKey.self] = tag
                        return copy
                    }
                    state.elements[id] = (subgraph, list)
                }
                if state.elements.count != ids.count {
                    let live = Set(ids)
                    for (id, element) in state.elements where !live.contains(id) {
                        element.subgraph.destroy()
                        state.elements[id] = nil
                    }
                }
            }
            return ViewList(nodes: ids.map { .nested(.explicit(AnyHashable($0)), state.elements[$0]!.list) })
        }
        attribute.label = "ForEach \(inputs.path)"
        return _ViewListOutputs(list: ViewList(nodes: [.dynamic(nil, attribute)]))
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

extension ForEach where Data == Range<Int>, ID == Int, Content: View {
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.data = data
        self.content = content
        self.identify = { $0 }
    }
}

@MainActor
private final class ForEachState<Data: RandomAccessCollection, ID: Hashable> {
    var index: [ID: Data.Index] = [:]
    var elements: [ID: (subgraph: Subgraph, list: ViewList)] = [:]
}
