import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@_exported import SwiftUIGraph
// Like SwiftUI: `@Observable` is available with just the UI framework imported.
@_exported import Observation
#if !canImport(ObjectiveC)
// CGAffineTransform, NSItemProvider, FileWrapper, ... (part of Apple's SDKs) and UTType.
@_exported import SwiftUIPortability
@_exported import UniformTypeIdentifiers
@_exported import CoreTransferable
#endif

/// A piece of user interface. Mirrors `SwiftUI.View`.
///
/// View values are ephemeral descriptions. The *graph* is built once per structural identity from
/// the static type (`_makeView` / `_makeViewList`); afterwards view values only flow through
/// attributes and are compared field-by-field to decide whether `body` must run again.
@MainActor @preconcurrency
public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor @preconcurrency var body: Body { get }

    /// Builds the graph for this view in a unary (single view) context.
    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs
    /// Builds the graph for this view in a list context (stack children, ForEach rows, ...).
    static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError("Never has no body") }

    public static func _makeView(view: _GraphValue<Never>, inputs: _ViewInputs) -> _ViewOutputs {
        fatalError("Never cannot be instantiated")
    }
}

@inline(never)
func primitiveBody<V>(_: V.Type) -> Never {
    fatalError("\(V.self) is a primitive view and has no body")
}

extension View {
    /// Composite views: evaluate `body` in an attribute and recurse.
    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        precondition(Body.self != Never.self, "\(Self.self) is a primitive view but does not implement _makeView")
        let path = inputs.path.appending(typeName(Self.self))
        let body = makeBodyAttribute(view: view.attribute, inputs: inputs.listInputs, path: path) { $0.body }
        var childInputs = inputs
        childInputs.path = path
        return Body._makeView(view: _GraphValue(body), inputs: childInputs)
    }

    /// Composite views are flattened into the enclosing list; primitives form a single element.
    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        if Body.self == Never.self {
            return .unary(view: view, inputs: inputs)
        }
        let path = inputs.path.appending(typeName(Self.self))
        let body = makeBodyAttribute(view: view.attribute, inputs: inputs, path: path) { $0.body }
        var childInputs = inputs
        childInputs.path = path
        return Body._makeViewList(view: _GraphValue(body), inputs: childInputs)
    }
}

func typeName(_ type: Any.Type) -> String {
    let name = _typeName(type, qualified: false)
    if let index = name.firstIndex(of: "<") { return String(name[..<index]) }
    return name
}

// MARK: - Graph values

/// A view (or modifier) value living in the graph.
///
/// A projection (`project`) makes no attribute of its own: it reads the value it projects from
/// whenever it is read. Its attribute, with the equality cut-off that keeps an unchanged child
/// from updating, is made when a consumer first asks for `attribute` (a body, a primitive's rules,
/// a layout). Values that are only projected further (a stack's content, a tuple's elements, the
/// content of a modifier wrapping another modifier) cost nothing, like SwiftUI's offset
/// attributes; they were a third of the attributes a page built.
@MainActor
public struct _GraphValue<Value> {
    private let source: Attribute<Value>?
    private let projection: _LazyGraphValue<Value>?

    public init(_ attribute: Attribute<Value>) {
        source = attribute
        projection = nil
    }

    private init(projection: _LazyGraphValue<Value>) {
        source = nil
        self.projection = projection
    }

    /// The value as an attribute (made on first use for a projection).
    public var attribute: Attribute<Value> { source ?? projection!.attribute }

    /// The current value, read like an attribute's (registers a dependency on what it comes from).
    var value: Value { source?.value ?? projection!.read() }

    /// Projection; consumers that make its attribute get structural equality cut-off.
    func project<T>(_ subgraph: Subgraph, _ transform: @escaping (Value) -> T) -> _GraphValue<T> {
        if let source {
            return _GraphValue<T>(projection: _LazyGraphValue(subgraph) { transform(source.value) })
        }
        let parent = projection!
        return _GraphValue<T>(projection: _LazyGraphValue(subgraph) { transform(parent.read()) })
    }

    func project<T>(_ inputs: _ViewInputs, _ transform: @escaping (Value) -> T) -> _GraphValue<T> {
        project(inputs.subgraph, transform)
    }

    func project<T>(_ inputs: _ViewListInputs, _ transform: @escaping (Value) -> T) -> _GraphValue<T> {
        project(inputs.subgraph, transform)
    }
}

/// A projected value whose attribute is made when first asked for.
@MainActor
final class _LazyGraphValue<Value> {
    private let subgraph: Subgraph
    private let get: () -> Value
    private var made: Attribute<Value>?

    init(_ subgraph: Subgraph, _ get: @escaping () -> Value) {
        self.subgraph = subgraph
        self.get = get
    }

    var attribute: Attribute<Value> {
        if let made { return made }
        let attribute = Attribute<Value>(subgraph, rule: get)
        made = attribute
        return attribute
    }

    /// Reads through the attribute once there is one (its cut-off), else projects anew.
    func read() -> Value { made?.value ?? get() }
}

// MARK: - Inputs / outputs

/// Where a view's platform nodes go, and the origin their frames are relative to.
public struct _RenderInputs {
    /// Render node new nodes are appended to.
    let parent: RenderNode
    /// Origin (host / content space) of the nearest platform container; nil means zero.
    let origin: Attribute<CGPoint>?
}

/// Everything a view needs to build its part of the graph in a unary context.
@MainActor
public struct _ViewInputs {
    unowned let host: ViewGraph
    var subgraph: Subgraph
    var environment: Attribute<EnvironmentValues>
    /// Placement assigned by the parent.
    var geometry: Attribute<ViewGeometry>
    var render: _RenderInputs
    /// Ordering key for eager attributes (parents update before children).
    var depth: Int
    var path: ViewPath
    /// Axis of the enclosing stack, used by Spacer / Divider.
    var stackAxis: Axis?
    var modifierContent: ModifierContentEntry?
    var animationScope: AnimationScope?
    /// The scope outside `animation(_:body:)`, restored for its placeholder content.
    var savedAnimationScope: _SavedAnimationScope?
    /// Preference keys some ancestor wants (only these are produced/combined).
    var preferenceKeys: [any AnyPreferenceKeyBox] = []
    var coordinateSpaces: CoordinateSpaces?
    /// Visible rect of the enclosing scroll view, in its content space (drives lazy stacks).
    var scrollViewport: Attribute<CGRect>?
    /// Scroll targets of the enclosing scroll view (`.id` views, lazy stacks) for ScrollViewReader.
    var scrollTargets: ScrollTargets?
    /// Where this view's geometry space starts in the enclosing scroll content (or root) space:
    /// nil there, the item's origin inside an item that starts its own space (see
    /// `ViewListContainer.isolatesItems`).
    var spaceOrigin: Attribute<CGPoint>?
    /// Position of a container child among its siblings (set by list containers).
    var listItem: ListItemReference?
    /// Accessibility properties waiting for the next platform node (consumed once).
    var accessibility: AccessibilityAttachment?

    var listInputs: _ViewListInputs {
        _ViewListInputs(host: host, subgraph: subgraph, environment: environment, depth: depth, path: path, modifierContent: modifierContent, animationScope: animationScope)
    }

    var tracer: UpdateTracer { host.tracer }
    var services: any PlatformServices { host.renderer.backend }

    func with(path component: String) -> _ViewInputs {
        var copy = self
        copy.path = path.appending(component)
        return copy
    }

    /// Inputs for a child placed at `geometry` and rendered under `parent`.
    func child(geometry: Attribute<ViewGeometry>, render: _RenderInputs? = nil, path component: String? = nil) -> _ViewInputs {
        var copy = self
        copy.geometry = geometry
        if let render { copy.render = render }
        if let component { copy.path = path.appending(component) }
        copy.depth += 1
        return copy
    }

    /// Creates a late-bound geometry attribute for a child of this view.
    func makeChildGeometry(label: @autoclosure () -> String? = nil) -> Attribute<ViewGeometry> {
        let attribute = Attribute<ViewGeometry>(subgraph, isEqual: { $0 == $1 })
        if host.graph.recordsLabels { attribute.label = label() }
        return attribute
    }
}

/// Inputs for building a view in a list context. No geometry/render yet: elements receive them when
/// the containing layout instantiates them.
@MainActor
public struct _ViewListInputs {
    unowned let host: ViewGraph
    var subgraph: Subgraph
    var environment: Attribute<EnvironmentValues>
    var depth: Int
    var path: ViewPath
    var modifierContent: ModifierContentEntry?
    var animationScope: AnimationScope?
    /// Sections contribute their header, rows and footer as separate list elements (List).
    var flattensSections = false
    /// Sections stay single (grouped) elements (Form).
    var groupsSections = false
    /// With `flattensSections`: headers stay as written (Group(sections:)), not list-styled.
    var rawSectionHeaders = false
    /// Inside a List's rows: the outline depth (disclosure groups and outline groups contribute
    /// their label and children as separate rows, children one level deeper). Nil elsewhere.
    var outlineLevel: Int?

    func with(path component: String) -> _ViewListInputs {
        var copy = self
        copy.path = path.appending(component)
        return copy
    }

    func with(subgraph: Subgraph) -> _ViewListInputs {
        var copy = self
        copy.subgraph = subgraph
        return copy
    }

    /// Combines the list-level context captured by an element with placement from the container.
    func instantiate(_ placement: _ViewInputs) -> _ViewInputs {
        var inputs = placement
        inputs.environment = environment
        inputs.path = path
        inputs.modifierContent = modifierContent
        // animationScope: keep the placement's (container or per-element modifier wrapper).
        return inputs
    }
}

public struct _ViewOutputs {
    let layout: Attribute<LayoutComputer>
    var preferences = PreferenceOutputs()

    init(layout: Attribute<LayoutComputer>, preferences: PreferenceOutputs = PreferenceOutputs()) {
        self.layout = layout
        self.preferences = preferences
    }
}

@MainActor
public struct _ViewListOutputs {
    let list: ViewList

    init(list: ViewList) { self.list = list }

    static func unary<V: View>(view: _GraphValue<V>, inputs: _ViewListInputs) -> _ViewListOutputs {
        _ViewListOutputs(list: ViewList(element: ViewListElement { placement in
            V._makeView(view: view, inputs: inputs.instantiate(placement))
        }))
    }

    static var empty: _ViewListOutputs { _ViewListOutputs(list: ViewList(nodes: [])) }

    /// A single-element list for a unary view (for views defined outside the core module).
    public static func unaryElement<V: View>(view: _GraphValue<V>, inputs: _ViewListInputs) -> _ViewListOutputs {
        unary(view: view, inputs: inputs)
    }
}

/// Stack used by custom `ViewModifier`s to find the content they wrap.
final class ModifierContentEntry {
    let modifierType: ObjectIdentifier
    let make: @MainActor (_ViewInputs) -> _ViewOutputs
    let previous: ModifierContentEntry?

    init(modifierType: ObjectIdentifier, make: @escaping @MainActor (_ViewInputs) -> _ViewOutputs, previous: ModifierContentEntry?) {
        self.modifierType = modifierType
        self.make = make
        self.previous = previous
    }
}
