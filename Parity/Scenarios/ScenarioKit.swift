// Shared between Apple SwiftUI and SwiftUI builds (symlinked into two targets).
// Only use API both frameworks provide.
import SwiftUI
import Foundation
import Observation

/// Counters incremented from inside view code; identical in both frameworks.
/// Not actor-isolated: Apple's `Layout` methods are nonisolated. Only touched on the main thread.
public enum Probe {
    nonisolated(unsafe) public static var counts: [String: Int] = [:]

    public static func hit(_ key: String) { counts[key, default: 0] += 1 }
    public static func reset() { counts.removeAll() }

    /// `let _ = Probe.body("Name")` inside `body`.
    public static func body(_ name: String) { hit("body.\(name)") }
}

/// Transparent single-child layout that counts how often it is measured / placed. Wrapping a view
/// in it lets us observe layout work in Apple's SwiftUI, whose internals are otherwise opaque.
public struct ProbeLayout: Layout {
    let name: String

    public init(name: String) { self.name = name }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Probe.hit("layout.\(name).sizeThatFits")
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        Probe.hit("layout.\(name).place")
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

extension View {
    /// Counts layout work for this view under `name`.
    public func probeLayout(_ name: String) -> some View {
        ProbeLayout(name: name) { self }
    }
}

public struct ParityStep {
    public let name: String
    public let action: @MainActor () -> Void

    public init(_ name: String, _ action: @escaping @MainActor () -> Void) {
        self.name = name
        self.action = action
    }
}

/// One parity scenario: a root view plus a scripted sequence of model mutations.
@MainActor
public struct ParityScenario {
    public let name: String
    public let root: AnyView
    public let steps: [ParityStep]

    public init<V: View>(_ name: String, root: V, steps: [ParityStep]) {
        self.name = name
        self.root = AnyView(root)
        self.steps = steps
    }
}

/// Counter snapshot per step: `[step: [counter: value]]`.
public typealias ParityRecording = [String: [String: Int]]

public enum ParityPolicy {
    /// Body evaluations must match SwiftUI exactly (fewer means a missed update, more means waste).
    public static func isExact(_ counter: String) -> Bool { counter.hasPrefix("body.") }
}
