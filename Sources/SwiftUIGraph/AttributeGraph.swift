@MainActor
public protocol AttributeGraphDelegate: AnyObject {
    /// Called once when the graph goes from "clean" to "has pending work". The host should schedule
    /// `update()` (e.g. before the run loop sleeps).
    func graphNeedsUpdate(_ graph: AttributeGraph)
}

@MainActor
public protocol AttributeGraphTracer: AnyObject {
    func attributeDidEvaluate(_ attribute: AnyAttribute, changed: Bool)
}

@MainActor
public final class AttributeGraph {
    public weak var delegate: AttributeGraphDelegate?
    public weak var tracer: AttributeGraphTracer?
    /// Called whenever a source changes or an attribute is invalidated from outside (used by the
    /// view layer to capture the transaction of the change).
    public var willChangeSource: (() -> Void)?

    public private(set) var revision: UInt64 = 0
    private var stamp: UInt64 = 0
    private var queueSequence: UInt64 = 0
    public private(set) var isUpdating = false
    private var updateRequested = false
    private var queue = EagerQueue()

    /// Total number of rule evaluations; handy for performance tests.
    public internal(set) var evaluationCount = 0
    public internal(set) var liveAttributeCount = 0

    public init() {}

    func nextRevision() -> UInt64 {
        revision &+= 1
        return revision
    }

    func nextStamp() -> UInt64 {
        stamp &+= 1
        return stamp
    }

    func enqueue(_ attribute: AnyAttribute) {
        if attribute.flags.contains(.queued) { return }
        attribute.flags.insert(.queued)
        queueSequence &+= 1
        attribute.queueSequence = queueSequence
        queue.push(attribute)
        setNeedsUpdate()
    }

    public var hasPendingUpdates: Bool { !queue.isEmpty }

    public func setNeedsUpdate() {
        if isUpdating || updateRequested { return }
        updateRequested = true
        delegate?.graphNeedsUpdate(self)
    }

    /// Pulls every dirty eager attribute, lowest `order` first. Attributes enqueued while updating
    /// (e.g. children created by a dynamic container) are processed in the same pass.
    public func update() {
        if isUpdating { return }
        isUpdating = true
        updateRequested = false
        defer { isUpdating = false }
        while let attribute = queue.pop() {
            attribute.flags.remove(.queued)
            if attribute.isDestroyed { continue }
            attribute.updateIfNeeded()
        }
    }
}

/// Binary min-heap ordered by (order, insertion sequence).
struct EagerQueue {
    private var heap: [AnyAttribute] = []

    var isEmpty: Bool { heap.isEmpty }

    @MainActor
    private static func less(_ a: AnyAttribute, _ b: AnyAttribute) -> Bool {
        a.order != b.order ? a.order < b.order : a.queueSequence < b.queueSequence
    }

    @MainActor
    mutating func push(_ attribute: AnyAttribute) {
        heap.append(attribute)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            if Self.less(heap[child], heap[parent]) {
                heap.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    @MainActor
    mutating func pop() -> AnyAttribute? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let result = heap.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, Self.less(heap[left], heap[smallest]) { smallest = left }
            if right < heap.count, Self.less(heap[right], heap[smallest]) { smallest = right }
            if smallest == parent { break }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
        return result
    }
}
