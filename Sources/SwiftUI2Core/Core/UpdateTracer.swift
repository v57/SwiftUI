/// Structural path of a view in the graph, e.g. `Root/VStack/[1]/Counter/Text`.
/// Used for diagnostics and by tests to assert *where* updates happened.
public final class ViewPath: CustomStringConvertible, @unchecked Sendable {
    public let parent: ViewPath?
    public let component: String
    private var cached: String?

    public init(_ component: String, parent: ViewPath? = nil) {
        self.component = component
        self.parent = parent
    }

    public func appending(_ component: String) -> ViewPath { ViewPath(component, parent: self) }

    public var description: String {
        if let cached { return cached }
        let value = parent.map { "\($0.description)/\(component)" } ?? component
        cached = value
        return value
    }
}

/// Records what the view graph did. Every kind of work that SwiftUI performs per view is counted
/// here, so tests (and the parity harness) can assert that an update touched exactly the views it
/// had to touch.
@MainActor
public final class UpdateTracer {
    public enum Kind: String, CaseIterable, Sendable {
        /// A composite view's `body` (or a modifier's `body(content:)`) was evaluated.
        case body
        /// A layout computer answered `sizeThatFits` without a cache hit.
        case sizeThatFits
        /// A container recomputed the placement of its children.
        case placement
        /// The geometry (origin/size) assigned to a view changed.
        case geometry
        /// A dynamic list (ForEach / if / AnyView) re-diffed its children.
        case listUpdate
        case renderInsert
        case renderRemove
        case renderContent
        case renderFrame
    }

    public struct Event: CustomStringConvertible, Sendable {
        public let kind: Kind
        public let path: String
        public var description: String { "\(kind.rawValue) \(path)" }
    }

    public var isRecording = true
    public private(set) var events: [Event] = []

    public init() {}

    func record(_ kind: Kind, _ path: ViewPath?) {
        guard isRecording else { return }
        events.append(Event(kind: kind, path: path?.description ?? "<root>"))
    }

    public func reset() { events.removeAll(keepingCapacity: true) }

    public func count(_ kind: Kind, where predicate: (String) -> Bool = { _ in true }) -> Int {
        events.reduce(0) { $0 + ($1.kind == kind && predicate($1.path) ? 1 : 0) }
    }

    public func events(_ kinds: Set<Kind>) -> [Event] { events.filter { kinds.contains($0.kind) } }

    public static let layoutKinds: Set<Kind> = [.sizeThatFits, .placement, .geometry, .renderFrame]
}
