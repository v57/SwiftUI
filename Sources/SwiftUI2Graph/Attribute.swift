// The attribute graph.
//
// Model: "push dirty, pull recompute, cut off on equality".
//
//  * An attribute is either a *source* (value set from outside, e.g. @State storage) or *computed*
//    (a rule closure). While a rule runs, every attribute it reads is recorded as an input; the
//    dependency set is therefore exact and dynamic (a rule that stops reading X stops depending on X).
//  * When a source changes, all transitive dependents are flagged `dirty` (cheap bit flips, no
//    evaluation). Eager attributes (render sinks, dynamic containers) are put in the graph's queue.
//  * During `AttributeGraph.update()` eager attributes are pulled. Pulling a dirty attribute first
//    brings its inputs up to date; if none of them actually *changed* the attribute is simply marked
//    clean without running its rule. If its rule runs and produces a value equal to the previous one,
//    its `changedRevision` is not bumped, so dependents downstream are not recomputed either.
//
// This gives the two properties SwiftUI relies on: work is proportional to what actually changed,
// and equality cut-off stops invalidation from leaking (e.g. out of an `.overlay`).

@MainActor
public class AnyAttribute {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let dirty = Flags(rawValue: 1 << 0)
        static let forced = Flags(rawValue: 1 << 1)
        static let computing = Flags(rawValue: 1 << 2)
        static let queued = Flags(rawValue: 1 << 3)
        static let destroyed = Flags(rawValue: 1 << 4)
        static let eager = Flags(rawValue: 1 << 5)
        static let reinvalidated = Flags(rawValue: 1 << 6)
        /// An input was marked dirty while this attribute was computing (e.g. by its own onChange).
        static let dirtiedWhileComputing = Flags(rawValue: 1 << 7)
    }

    struct Edge {
        let attribute: AnyAttribute
        var revision: UInt64
    }

    public let graph: AttributeGraph
    final var flags: Flags
    final var inputs: ContiguousArray<Edge> = []
    final var outputs: ContiguousArray<Unmanaged<AnyAttribute>> = []
    /// Revision at which the value last changed.
    public final internal(set) var changedRevision: UInt64 = 0
    final var readStamp: UInt64 = 0
    final var queueSequence: UInt64 = 0
    /// Ordering key for eager attributes. Lower orders are updated first (parents before children).
    public final var order: Int = 0
    /// Free-form debug label; also used by tracers.
    public final var label: String?

    init(graph: AttributeGraph, flags: Flags) {
        self.graph = graph
        self.flags = flags
        graph.liveAttributeCount += 1
    }

    isolated deinit {
        graph.liveAttributeCount -= 1
        for edge in inputs { edge.attribute.removeOutput(self) }
    }

    public final var isDestroyed: Bool { flags.contains(.destroyed) }
    public final var isDirty: Bool { flags.contains(.dirty) }

    /// Eager attributes are pulled by `AttributeGraph.update()` whenever they become dirty.
    public final var isEager: Bool {
        get { flags.contains(.eager) }
        set {
            if newValue {
                flags.insert(.eager)
                if flags.contains(.dirty) { graph.enqueue(self) }
            } else {
                flags.remove(.eager)
            }
        }
    }

    // MARK: Subclass hooks

    /// Runs the rule; returns true when the stored value changed.
    func runRule() -> Bool { false }
    func didDestroy() {}

    // MARK: Pull

    /// Brings the value up to date without registering a dependency.
    public final func updateIfNeeded() {
        guard flags.contains(.dirty) else { return }
        if flags.contains(.destroyed) {
            flags.remove([.dirty, .forced])
            return
        }
        precondition(!flags.contains(.computing), "SwiftUI2: attribute cycle detected at \(label ?? "<unnamed>")")
        if !flags.contains(.forced) {
            var stale = false
            var index = 0
            let count = inputs.count
            while index < count {
                let edge = inputs[index]
                edge.attribute.updateIfNeeded()
                if edge.attribute.changedRevision != edge.revision {
                    stale = true
                    break
                }
                index += 1
            }
            if !stale {
                flags.remove(.dirty)
                return
            }
        }
        evaluate()
    }

    final func evaluate() {
        flags.insert(.computing)
        let oldInputs = inputs
        inputs.removeAll(keepingCapacity: true)

        let savedReader = AnyAttribute.currentReader
        let savedStamp = AnyAttribute.currentStamp
        AnyAttribute.currentReader = self
        AnyAttribute.currentStamp = graph.nextStamp()

        let changed = runRule()

        AnyAttribute.currentReader = savedReader
        AnyAttribute.currentStamp = savedStamp

        flags.remove([.computing, .dirty, .forced])
        graph.evaluationCount += 1
        reconcileEdges(old: oldInputs)
        // An input dirtied during this evaluation (possibly before the edge existed) must keep this
        // attribute dirty too.
        for edge in inputs where edge.attribute.flags.contains(.dirty) {
            flags.insert(.dirtiedWhileComputing)
            break
        }
        if changed {
            changedRevision = graph.nextRevision()
        }
        graph.tracer?.attributeDidEvaluate(self, changed: changed)
        if flags.contains(.reinvalidated) {
            // Invalidated while computing (e.g. a mutation during body); run again on next pass.
            flags.remove([.reinvalidated, .dirtiedWhileComputing])
            invalidate()
        } else if flags.contains(.dirtiedWhileComputing) {
            // Keep the invariant "dirty input ⇒ dirty output": re-check inputs on the next pull.
            flags.remove(.dirtiedWhileComputing)
            flags.insert(.dirty)
            if flags.contains(.eager) { graph.enqueue(self) }
            graph.setNeedsUpdate()
        }
    }

    private final func reconcileEdges(old: ContiguousArray<Edge>) {
        if old.count == inputs.count {
            var same = true
            for i in 0..<old.count where old[i].attribute !== inputs[i].attribute {
                same = false
                break
            }
            if same { return }
        }
        var oldSet = Set<ObjectIdentifier>(minimumCapacity: old.count)
        for edge in old { oldSet.insert(ObjectIdentifier(edge.attribute)) }
        var newSet = Set<ObjectIdentifier>(minimumCapacity: inputs.count)
        for edge in inputs {
            let id = ObjectIdentifier(edge.attribute)
            if newSet.insert(id).inserted, !oldSet.contains(id) {
                edge.attribute.outputs.append(.passUnretained(self))
            }
        }
        for edge in old where !newSet.contains(ObjectIdentifier(edge.attribute)) {
            edge.attribute.removeOutput(self)
            newSet.insert(ObjectIdentifier(edge.attribute)) // avoid double removal of duplicates
        }
    }

    final func removeOutput(_ attribute: AnyAttribute) {
        let target = Unmanaged.passUnretained(attribute).toOpaque()
        if let index = outputs.firstIndex(where: { $0.toOpaque() == target }) {
            outputs.swapAt(index, outputs.count - 1)
            outputs.removeLast()
        }
    }

    // MARK: Dependency tracking

    static var currentReader: AnyAttribute?
    static var currentStamp: UInt64 = 0

    final func recordRead() {
        guard let reader = AnyAttribute.currentReader else { return }
        if readStamp == AnyAttribute.currentStamp { return }
        readStamp = AnyAttribute.currentStamp
        reader.inputs.append(Edge(attribute: self, revision: changedRevision))
    }

    /// Runs `body` without recording dependencies for the attribute currently being computed.
    public static func withoutDependencies<R>(_ body: () throws -> R) rethrows -> R {
        let savedReader = currentReader
        currentReader = nil
        defer { currentReader = savedReader }
        return try body()
    }

    /// The attribute whose rule is currently running, if any.
    public static var current: AnyAttribute? { currentReader }

    // MARK: Push

    final func propagateDirtyToOutputs() {
        if outputs.isEmpty { return }
        var stack: [AnyAttribute] = []
        stack.reserveCapacity(outputs.count)
        for output in outputs { stack.append(output.takeUnretainedValue()) }
        while let attribute = stack.popLast() {
            if attribute.flags.contains(.computing) {
                // Its evaluation would clear the dirty bit; remember to re-check afterwards.
                attribute.flags.insert(.dirtiedWhileComputing)
                continue
            }
            if attribute.flags.contains(.dirty) { continue }
            attribute.flags.insert(.dirty)
            if attribute.flags.contains(.eager) { graph.enqueue(attribute) }
            for output in attribute.outputs { stack.append(output.takeUnretainedValue()) }
        }
    }

    /// Forces the rule to run again on next pull (used for external invalidation such as
    /// Observation `onChange` or `objectWillChange`).
    public final func invalidate() {
        if flags.contains(.destroyed) { return }
        if flags.contains(.computing) {
            flags.insert(.reinvalidated)
            return
        }
        graph.willChangeSource?()
        let wasDirty = flags.contains(.dirty)
        flags.insert([.dirty, .forced])
        if flags.contains(.eager) { graph.enqueue(self) }
        if !wasDirty { propagateDirtyToOutputs() }
        graph.setNeedsUpdate()
    }

    // MARK: Lifetime

    public final func destroy() {
        if flags.contains(.destroyed) { return }
        flags.insert(.destroyed)
        flags.remove([.dirty, .forced])
        for edge in inputs { edge.attribute.removeOutput(self) }
        inputs.removeAll()
        didDestroy()
    }
}

/// A typed attribute. Either a source (`init(_:value:)`) or computed (`init(_:rule:)`).
@MainActor
public final class Attribute<Value>: AnyAttribute {
    public typealias Comparator = (Value, Value) -> Bool

    private var storage: Value?
    private var rule: (() -> Value)?
    private let isEqual: Comparator
    /// Called after the value changed as the result of a rule evaluation (not for sources).
    public var onChange: ((Value) -> Void)?

    /// Source attribute.
    public init(_ subgraph: Subgraph, value: Value, isEqual: @escaping Comparator = GraphComparison.isIdentical) {
        self.storage = value
        self.isEqual = isEqual
        super.init(graph: subgraph.graph, flags: [])
        self.changedRevision = graph.nextRevision()
        subgraph.register(self)
    }

    /// Computed attribute. The rule runs lazily on first read.
    public init(_ subgraph: Subgraph, isEqual: @escaping Comparator = GraphComparison.isIdentical, rule: @escaping () -> Value) {
        self.rule = rule
        self.isEqual = isEqual
        super.init(graph: subgraph.graph, flags: [.dirty, .forced])
        subgraph.register(self)
    }

    /// Computed attribute whose rule is supplied later via `setRule` (for late-bound graphs, e.g. a
    /// child's geometry that depends on the child's own layout outputs).
    public init(_ subgraph: Subgraph, isEqual: @escaping Comparator = GraphComparison.isIdentical) {
        self.isEqual = isEqual
        super.init(graph: subgraph.graph, flags: [.dirty, .forced])
        subgraph.register(self)
    }

    public func setRule(_ rule: @escaping () -> Value) {
        self.rule = rule
        if !isDestroyed { invalidate() }
    }

    /// Current value; registers a dependency when read from inside another attribute's rule.
    public var value: Value {
        updateIfNeeded()
        recordRead()
        guard let storage else {
            preconditionFailure("SwiftUI2: attribute \(label ?? "<unnamed>") read before it had a value")
        }
        return storage
    }

    /// Value without bringing it up to date or registering a dependency.
    public var peekValue: Value? { storage }

    /// Sets a source value. No-op when equal to the current value.
    public func setValue(_ newValue: Value) {
        precondition(rule == nil, "setValue on a computed attribute")
        if isDestroyed { return }
        if let storage, isEqual(storage, newValue) { return }
        graph.willChangeSource?()
        storage = newValue
        changedRevision = graph.nextRevision()
        propagateDirtyToOutputs()
        graph.setNeedsUpdate()
    }

    override func runRule() -> Bool {
        guard let rule else { return false }
        let newValue = rule()
        if let old = storage, isEqual(old, newValue) { return false }
        storage = newValue
        if let onChange { onChange(newValue) }
        return true
    }

    override func didDestroy() {
        rule = nil
        onChange = nil
    }

    public func map<T>(_ subgraph: Subgraph, isEqual: @escaping (T, T) -> Bool = GraphComparison.isIdentical, _ transform: @escaping (Value) -> T) -> Attribute<T> {
        Attribute<T>(subgraph, isEqual: isEqual) { transform(self.value) }
    }
}

extension Attribute where Value: Equatable {
    public convenience init(_ subgraph: Subgraph, equatable value: Value) {
        self.init(subgraph, value: value, isEqual: { $0 == $1 })
    }
}
