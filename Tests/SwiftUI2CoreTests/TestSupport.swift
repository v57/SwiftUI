import Foundation
import SwiftUI2Core
import SwiftUI2Headless

/// Counts body evaluations by name (used inside `body` via `let _ = Counter.hit("Name")`).
@MainActor
enum Counter {
    static var counts: [String: Int] = [:]
    static func hit(_ name: String) { counts[name, default: 0] += 1 }
    static func reset() { counts = [:] }
    static subscript(name: String) -> Int { counts[name, default: 0] }
}

extension TestHost {
    /// Paths of views that did any layout-related work since the last reset.
    func layoutTouchedPaths() -> [String] {
        tracer.events(UpdateTracer.layoutKinds).map(\.path)
    }

    func bodyEvaluations(of name: String) -> Int {
        tracer.count(.body) { $0.hasSuffix("/\(name)") || $0 == name }
    }
}

extension HeadlessView {
    /// Color views and filled shapes (`.background(Color.red)` renders a filled rectangle, as in SwiftUI).
    var isFill: Bool {
        switch content {
        case .color: return true
        case .shape(let shape): return shape.fill != nil
        default: return false
        }
    }
}
