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

    // The graph's hot state skips dynamic exclusivity checks (a `swift_beginAccess` per access
    // was a tenth of building a view): attributes are main-actor objects, and no access to these
    // fields overlaps another (reads of an attribute during its own rule go through other fields).
    public let graph: AttributeGraph
    @exclusivity(unchecked) final var flags: Flags
    @exclusivity(unchecked) final var inputs: ContiguousArray<Edge> = []
    @exclusivity(unchecked) final var outputs: ContiguousArray<Unmanaged<AnyAttribute>> = []
    /// Revision at which the value last changed.
    @exclusivity(unchecked) public final internal(set) var changedRevision: UInt64 = 0
    @exclusivity(unchecked) final var readStamp: UInt64 = 0
    /// Scratch stamp for reconciling edges (set membership without allocating sets).
    @exclusivity(unchecked) final var mark: UInt64 = 0
    @exclusivity(unchecked) final var queueSequence: UInt64 = 0
    /// Ordering key for eager attributes. Lower orders are updated first (parents before children).
    @exclusivity(unchecked) public final var order: Int = 0
    /// Free-form debug label; also used by tracers. Views label their attributes with
    /// `setLabel`, which builds the string only while the graph records labels.
    @exclusivity(unchecked) public final var label: String?

    init(graph: AttributeGraph, flags: Flags) {
        self.graph = graph
        self.flags = flags
        graph.liveAttributeCount += 1
    }

    // Not `isolated`: hopping to the main executor in every deinit (to check it) cost more than
    // the deinit. A destroyed attribute (the usual case: its subgraph went away) left the graph in
    // `destroy`, so its deinit touches nothing shared, on whatever thread releases it last. Only
    // one never destroyed (a whole graph released) leaves its inputs here, on the main thread.
    deinit {
        _assumeMainActor {
            guard !flags.contains(.destroyed) else { return }
            graph.liveAttributeCount -= 1
            for edge in inputs { edge.attribute.removeOutput(self) }
        }
    }

    /// Sets `label` when the graph records labels (`AttributeGraph.recordsLabels`); the string
    /// (usually a view path) is not built otherwise.
    public final func setLabel(_ make: @autoclosure () -> String) {
        if graph.recordsLabels { label = make() }
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
        precondition(!flags.contains(.computing), "SwiftUI: attribute cycle detected at \(label ?? "<unnamed>")")
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
        // Reads are recorded on the graph's read stack (above the reads of the attributes whose
        // rules are running further out), then adopted as this attribute's inputs: re-evaluating
        // with the same inputs allocates nothing.
        let base = graph.readStack.count

        let savedReader = AnyAttribute.currentReader
        let savedStamp = AnyAttribute.currentStamp
        AnyAttribute.currentReader = self
        AnyAttribute.currentStamp = graph.nextStamp()

        let changed = runRule()

        AnyAttribute.currentReader = savedReader
        AnyAttribute.currentStamp = savedStamp

        flags.remove([.computing, .dirty, .forced])
        graph.evaluationCount += 1
        adoptReads(from: base)
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

    /// Makes the reads above `base` on the graph's read stack this attribute's inputs, and pops them.
    private final func adoptReads(from base: Int) {
        let graph = self.graph
        let count = graph.readStack.count - base
        if count == inputs.count {
            var same = true
            var index = 0
            while index < count {
                if graph.readStack[base + index].attribute !== inputs[index].attribute {
                    same = false
                    break
                }
                index += 1
            }
            if same {
                index = 0
                while index < count {
                    inputs[index].revision = graph.readStack[base + index].revision
                    index += 1
                }
                graph.readStack.removeLast(count)
                return
            }
        }
        let old = inputs
        inputs = ContiguousArray(graph.readStack[base...])
        graph.readStack.removeLast(count)
        // New inputs that were not inputs before gain this output (once, even when read twice).
        let oldMark = graph.nextStamp()
        for edge in old { edge.attribute.mark = oldMark }
        for edge in inputs where edge.attribute.mark != oldMark {
            edge.attribute.mark = oldMark
            edge.attribute.outputs.append(.passUnretained(self))
        }
        // Old inputs that are no longer read lose it.
        if old.isEmpty { return }
        let newMark = graph.nextStamp()
        for edge in inputs { edge.attribute.mark = newMark }
        for edge in old where edge.attribute.mark != newMark {
            edge.attribute.mark = newMark
            edge.attribute.removeOutput(self)
        }
    }

    final func removeOutput(_ attribute: AnyAttribute) {
        // A loop, not `firstIndex(where:)`: a main-actor closure passed to the standard library
        // checks the executor on every call.
        let target = Unmanaged.passUnretained(attribute).toOpaque()
        var index = outputs.count - 1
        while index >= 0 {
            if outputs[index].toOpaque() == target {
                outputs.swapAt(index, outputs.count - 1)
                outputs.removeLast()
                return
            }
            index -= 1
        }
    }

    // MARK: Dependency tracking

    @exclusivity(unchecked) static var currentReader: AnyAttribute?
    @exclusivity(unchecked) static var currentStamp: UInt64 = 0

    @usableFromInline
    final func recordRead() {
        guard AnyAttribute.currentReader != nil else { return }
        if readStamp == AnyAttribute.currentStamp { return }
        readStamp = AnyAttribute.currentStamp
        graph.readStack.append(Edge(attribute: self, revision: changedRevision))
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
        graph.liveAttributeCount -= 1
        flags.remove([.dirty, .forced])
        // An input destroyed already (in a child subgraph, destroyed first) keeps no outputs.
        for edge in inputs where !edge.attribute.flags.contains(.destroyed) { edge.attribute.removeOutput(self) }
        inputs.removeAll()
        outputs.removeAll()
        didDestroy()
    }
}

/// A typed attribute. Either a source (`init(_:value:)`) or computed (`init(_:rule:)`).
@MainActor
public final class Attribute<Value>: AnyAttribute {
    public typealias Comparator = (Value, Value) -> Bool

    @exclusivity(unchecked) @usableFromInline var storage: Value?
    @exclusivity(unchecked) private var rule: (() -> Value)?
    /// The comparator given, or nil for `GraphComparison.isIdentical` (resolved once per type:
    /// `rawIsEqual`).
    private let isEqual: Comparator?
    private let rawIsEqual: GraphComparison.RawComparator?
    /// Called after the value changed as the result of a rule evaluation (not for sources).
    @exclusivity(unchecked) public var onChange: ((Value) -> Void)?

    /// Source attribute.
    public init(_ subgraph: Subgraph, value: Value, isEqual: Comparator? = nil) {
        self.storage = value
        self.isEqual = isEqual
        self.rawIsEqual = isEqual == nil ? GraphComparison.mainActorComparator(for: Value.self) : nil
        super.init(graph: subgraph.graph, flags: [])
        self.changedRevision = graph.nextRevision()
        subgraph.register(self)
    }

    /// Computed attribute. The rule runs lazily on first read.
    public init(_ subgraph: Subgraph, isEqual: Comparator? = nil, rule: @escaping () -> Value) {
        self.rule = rule
        self.isEqual = isEqual
        self.rawIsEqual = isEqual == nil ? GraphComparison.mainActorComparator(for: Value.self) : nil
        super.init(graph: subgraph.graph, flags: [.dirty, .forced])
        subgraph.register(self)
    }

    /// Computed attribute whose rule is supplied later via `setRule` (for late-bound graphs, e.g. a
    /// child's geometry that depends on the child's own layout outputs).
    public init(_ subgraph: Subgraph, isEqual: Comparator? = nil) {
        self.isEqual = isEqual
        self.rawIsEqual = isEqual == nil ? GraphComparison.mainActorComparator(for: Value.self) : nil
        super.init(graph: subgraph.graph, flags: [.dirty, .forced])
        subgraph.register(self)
    }

    public func setRule(_ rule: @escaping () -> Value) {
        self.rule = rule
        if !isDestroyed { invalidate() }
    }

    /// Current value; registers a dependency when read from inside another attribute's rule.
    /// Inlinable, so modules reading attributes do it in code specialized for the value's type
    /// (generic code instantiated `Optional<Value>`'s metadata on every read).
    @inlinable
    public var value: Value {
        updateIfNeeded()
        recordRead()
        guard let storage else { readBeforeValue() }
        return storage
    }

    @usableFromInline
    func readBeforeValue() -> Never {
        preconditionFailure("SwiftUI: attribute \(label ?? "<unnamed>") read before it had a value")
    }

    /// Like `value`, but nil (still registering the dependency) while a late-bound attribute has
    /// no rule yet; the dependent stays dirty and recomputes once the rule is set.
    @inlinable
    public var valueIfPresent: Value? {
        updateIfNeeded()
        recordRead()
        return storage
    }

    /// Value without bringing it up to date or registering a dependency.
    @inlinable
    public var peekValue: Value? { storage }

    /// Sets a source value. No-op when equal to the current value.
    public func setValue(_ newValue: Value) {
        precondition(rule == nil, "setValue on a computed attribute")
        if isDestroyed { return }
        if let storage, isSame(storage, newValue) { return }
        graph.willChangeSource?()
        storage = newValue
        changedRevision = graph.nextRevision()
        propagateDirtyToOutputs()
        graph.setNeedsUpdate()
    }

    /// Sets a source value from a rule (an attribute that distributes values, such as a stack
    /// placing its items): like `setValue`, without reporting a change from outside the graph.
    public func setSourceValueDuringUpdate(_ newValue: Value) {
        precondition(rule == nil, "setValue on a computed attribute")
        if isDestroyed { return }
        if let storage, isSame(storage, newValue) { return }
        storage = newValue
        changedRevision = graph.nextRevision()
        propagateDirtyToOutputs()
        graph.setNeedsUpdate()
    }

    override func runRule() -> Bool {
        guard let rule else { return false }
        let newValue = rule()
        if let old = storage, isSame(old, newValue) { return false }
        storage = newValue
        if let onChange { onChange(newValue) }
        return true
    }

    private func isSame(_ lhs: Value, _ rhs: Value) -> Bool {
        if let rawIsEqual {
            return withUnsafePointer(to: lhs) { l in withUnsafePointer(to: rhs) { r in rawIsEqual(l, r) } }
        }
        return isEqual!(lhs, rhs)
    }

    override func didDestroy() {
        rule = nil
        onChange = nil
    }

    public func map<T>(_ subgraph: Subgraph, isEqual: ((T, T) -> Bool)? = nil, _ transform: @escaping (Value) -> T) -> Attribute<T> {
        Attribute<T>(subgraph, isEqual: isEqual) { transform(self.value) }
    }
}

extension Attribute where Value: Equatable {
    public convenience init(_ subgraph: Subgraph, equatable value: Value) {
        self.init(subgraph, value: value, isEqual: { $0 == $1 })
    }
}

/// Runs main-actor code from a nonisolated context that runs on the main actor (deinits of
/// attributes), without the runtime check of `MainActor.assumeIsolated`.
@inline(__always)
nonisolated func _assumeMainActor<T>(_ body: @MainActor () -> T) -> T {
    withoutActuallyEscaping(body) { body in
        unsafeBitCast(body, to: (() -> T).self)()
    }
}
