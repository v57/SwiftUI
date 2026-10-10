import Foundation

// MARK: - Transaction keys

public protocol TransactionKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

// MARK: - Container values

public protocol ContainerValueKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// Values a container's subviews carry for it (`containerValue(_:_:)`, read from `Subview`).
public struct ContainerValues: @unchecked Sendable {
    var storage: [ObjectIdentifier: Any] = [:]

    public init() {}

    public subscript<Key: ContainerValueKey>(key: Key.Type) -> Key.Value {
        get { storage[ObjectIdentifier(key)] as? Key.Value ?? Key.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}

public enum ContainerValuesTraitKey: _ViewTraitKey {
    public static var defaultValue: ContainerValues { ContainerValues() }
}

extension View {
    /// Sets a container value on this view (or on each element in a list context).
    public func containerValue<V>(_ keyPath: WritableKeyPath<ContainerValues, V>, _ value: V) -> some View {
        _transformTrait(ContainerValuesTraitKey.self) { $0[keyPath: keyPath] = value }
    }
}

// MARK: - Subviews

/// One resolved subview of some content (`Group(subviews:)`, `ForEach(subviews:)`).
public struct Subview: View, Identifiable {
    public struct ID: Hashable, @unchecked Sendable {
        let value: ViewListID
    }

    public let id: ID
    let element: ViewListElement

    public var containerValues: ContainerValues { MainActor.assumeIsolated { element.traits.value(ContainerValuesTraitKey.self) } }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let element = AnyAttribute.withoutDependencies { view.attribute.value.element }
        return element.make(inputs)
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        // Keep the element's traits (tags, container values) for containers of subviews.
        let element = AnyAttribute.withoutDependencies { view.attribute.value.element }
        return _ViewListOutputs(list: ViewList(element: ViewListElement(traits: element.traits) { placement in
            element.make(placement)
        }))
    }
}

extension Subview: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: Subview, _ rhs: Subview) -> Bool { lhs.id == rhs.id }
}

/// The subviews of some content, in order.
public struct SubviewsCollection: RandomAccessCollection, @unchecked Sendable {
    let subviews: [Subview]
    public var startIndex: Int { subviews.startIndex }
    public var endIndex: Int { subviews.endIndex }
    public subscript(position: Int) -> Subview { subviews[position] }
}

public typealias SubviewsCollectionSlice = Slice<SubviewsCollection>

extension SubviewsCollection: _GraphComparable {
    public static func _isIdentical(_ lhs: SubviewsCollection, _ rhs: SubviewsCollection) -> Bool { lhs.subviews.map(\.id) == rhs.subviews.map(\.id) }
}

@MainActor
func makeSubviews(_ list: ViewList) -> SubviewsCollection {
    var flattened: [(ViewListID, ViewListElement)] = []
    list.flatten(into: &flattened)
    return SubviewsCollection(subviews: flattened.map { Subview(id: Subview.ID(value: $0.0), element: $0.1) })
}

/// `Group(subviews:transform:)`: the transform receives the content's subviews.
public struct _SubviewsGroup<Base: View, Result: View>: View {
    let base: Base
    let transform: @MainActor (SubviewsCollection) -> Result

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let baseList = Base._makeViewList(view: view.project(inputs) { $0.base }, inputs: inputs).list
        let subviews = Attribute<SubviewsCollection>(inputs.subgraph) { makeSubviews(baseList) }
        let result = makeObservedAttribute(inputs.subgraph, of: Result.self) { view.attribute.value.transform(subviews.value) }
        return Result._makeViewList(view: _GraphValue(result), inputs: inputs)
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

extension Group where Content: View {
    @MainActor
    public init<Base: View, Result: View>(subviews view: Base, @ViewBuilder transform: @escaping @MainActor (SubviewsCollection) -> Result) where Content == _SubviewsGroup<Base, Result> {
        self.init { _SubviewsGroup(base: view, transform: transform) }
    }

    @MainActor
    public init<Base: View, Result: View>(sections view: Base, @ViewBuilder transform: @escaping @MainActor (SectionCollection) -> Result) where Content == _SectionsGroup<Base, Result> {
        self.init { _SectionsGroup(base: view, transform: transform) }
    }
}

/// `ForEach(subviews:content:)` data: the content's subviews, each transformed by the closure.
public struct ForEachSubviewCollection<Content: View>: RandomAccessCollection {
    let make: @MainActor (_ViewListInputs) -> _ViewListOutputs
    public var startIndex: Int { 0 }
    public var endIndex: Int { 0 }
    public subscript(position: Int) -> Subview { fatalError("ForEachSubviewCollection is resolved by the view graph") }
}

public struct ForEachSectionCollection<Content: View>: RandomAccessCollection {
    let make: @MainActor (_ViewListInputs) -> _ViewListOutputs
    public var startIndex: Int { 0 }
    public var endIndex: Int { 0 }
    public subscript(position: Int) -> SectionConfiguration { fatalError("ForEachSectionCollection is resolved by the view graph") }
}

/// Data of a `ForEach` that the graph builds itself (subview and section collections).
protocol _GraphResolvedForEachData {
    var _make: @MainActor (_ViewListInputs) -> _ViewListOutputs { get }
}

extension ForEachSubviewCollection: _GraphResolvedForEachData { var _make: @MainActor (_ViewListInputs) -> _ViewListOutputs { make } }
extension ForEachSectionCollection: _GraphResolvedForEachData { var _make: @MainActor (_ViewListInputs) -> _ViewListOutputs { make } }

extension ForEach where Data == ForEachSubviewCollection<Content>, ID == Subview.ID, Content: View {
    @MainActor
    public init<V: View>(subviews view: V, @ViewBuilder content: @escaping @MainActor (Subview) -> Content) {
        let group = _SubviewsGroup(base: view) { subviews in ForEach<SubviewsCollection, Subview.ID, Content>(subviews) { content($0) } }
        self.init(_unchecked: ForEachSubviewCollection(make: { inputs in
            _SubviewsGroup<V, ForEach<SubviewsCollection, Subview.ID, Content>>._makeViewList(view: _GraphValue(Attribute(inputs.subgraph, value: group)), inputs: inputs)
        }), id: \.id, content: { _ in fatalError() })
    }
}

extension ForEach where Data == ForEachSectionCollection<Content>, ID == SectionConfiguration.ID, Content: View {
    @MainActor
    public init<V: View>(sections view: V, @ViewBuilder content: @escaping @MainActor (SectionConfiguration) -> Content) {
        let group = _SectionsGroup(base: view) { sections in ForEach<SectionCollection, SectionConfiguration.ID, Content>(sections) { content($0) } }
        self.init(_unchecked: ForEachSectionCollection(make: { inputs in
            _SectionsGroup<V, ForEach<SectionCollection, SectionConfiguration.ID, Content>>._makeViewList(view: _GraphValue(Attribute(inputs.subgraph, value: group)), inputs: inputs)
        }), id: \.id, content: { _ in fatalError() })
    }
}

// MARK: - Sections

/// A section of some content: its header, content and footer subviews.
public struct SectionConfiguration: Identifiable, @unchecked Sendable {
    public struct ID: Hashable, @unchecked Sendable { let value: ViewListID }
    public let id: ID
    public let header: SubviewsCollection
    public let content: SubviewsCollection
    public let footer: SubviewsCollection
    public var containerValues: ContainerValues { content.first?.containerValues ?? ContainerValues() }
}

public struct SectionCollection: RandomAccessCollection, @unchecked Sendable {
    let sections: [SectionConfiguration]
    public var startIndex: Int { sections.startIndex }
    public var endIndex: Int { sections.endIndex }
    public subscript(position: Int) -> SectionConfiguration { sections[position] }
}

extension SectionCollection: _GraphComparable {
    public static func _isIdentical(_ lhs: SectionCollection, _ rhs: SectionCollection) -> Bool {
        lhs.sections.map { $0.content.subviews.map(\.id) + $0.header.subviews.map(\.id) + $0.footer.subviews.map(\.id) }
            == rhs.sections.map { $0.content.subviews.map(\.id) + $0.header.subviews.map(\.id) + $0.footer.subviews.map(\.id) }
    }
}

@MainActor
func makeSections(_ list: ViewList) -> SectionCollection {
    var flattened: [(ViewListID, ViewListElement)] = []
    list.flatten(into: &flattened)
    var sections: [SectionConfiguration] = []
    var header: [Subview] = []
    var content: [Subview] = []
    var footer: [Subview] = []
    var sectionID: ViewListID?
    func finish() {
        guard !header.isEmpty || !content.isEmpty || !footer.isEmpty else { return }
        let id = sectionID ?? content.first?.id.value ?? header.first?.id.value ?? footer[0].id.value
        sections.append(SectionConfiguration(id: SectionConfiguration.ID(value: id), header: SubviewsCollection(subviews: header),
                                             content: SubviewsCollection(subviews: content), footer: SubviewsCollection(subviews: footer)))
        header = []
        content = []
        footer = []
        sectionID = nil
    }
    for (id, element) in flattened {
        let subview = Subview(id: Subview.ID(value: id), element: element)
        switch element.traits.value(ListElementRoleKey.self) {
        case .header:
            finish()
            sectionID = id
            header.append(subview)
        case .sectionGap:
            finish()
            sectionID = id
        case .footer:
            footer.append(subview)
        case .row:
            if !footer.isEmpty { finish() }
            content.append(subview)
        }
    }
    finish()
    return SectionCollection(sections: sections)
}

/// `Group(sections:transform:)`: the transform receives the content's sections.
public struct _SectionsGroup<Base: View, Result: View>: View {
    let base: Base
    let transform: @MainActor (SectionCollection) -> Result

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        var sectionInputs = inputs
        sectionInputs.flattensSections = true
        sectionInputs.rawSectionHeaders = true
        sectionInputs.groupsSections = false
        let baseList = Base._makeViewList(view: view.project(inputs) { $0.base }, inputs: sectionInputs).list
        let sections = Attribute<SectionCollection>(inputs.subgraph) { makeSections(baseList) }
        let result = makeObservedAttribute(inputs.subgraph, of: Result.self) { view.attribute.value.transform(sections.value) }
        return Result._makeViewList(view: _GraphValue(result), inputs: inputs)
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

// MARK: - Subview collections as views

@MainActor
func _subviewsList(_ subviews: [Subview], inputs: _ViewListInputs) -> _ViewListOutputs {
    _ViewListOutputs(list: ViewList(nodes: subviews.map { subview in
        .nested(.explicit(AnyHashable(subview.id)), ViewList(element: ViewListElement(traits: subview.element.traits) { placement in
            subview.element.make(placement)
        }))
    }))
}

/// A collection of subviews renders all of them (`section.header`, `subviews[1...]`).
extension SubviewsCollection: View {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let list = Attribute<ViewList>(inputs.subgraph, isEqual: ViewList.isStructurallyEqual) {
            _subviewsList(view.attribute.value.subviews, inputs: inputs).list
        }
        return _ViewListOutputs(list: ViewList(nodes: [.dynamic(nil, list)]))
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

extension Slice: View where Base == SubviewsCollection {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let list = Attribute<ViewList>(inputs.subgraph, isEqual: ViewList.isStructurallyEqual) {
            _subviewsList(Array(view.attribute.value), inputs: inputs).list
        }
        return _ViewListOutputs(list: ViewList(nodes: [.dynamic(nil, list)]))
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}
