import Foundation
import Testing
import ParityScenarios
import SwiftUIHeadless

/// Runs every shared scenario on SwiftUI and compares counters with the golden recording made on
/// Apple's SwiftUI (`swift run parity-recorder`):
///  * `body.*` counters must match exactly,
///  * `layout.*` counters must be ≤ SwiftUI's (doing less layout work is allowed, more is a bug).
/// Keep in sync with `ScenarioCatalog.all()` (checked by `catalogIsCovered`).
let scenarioNames = [
    "observable-fine-grained", "observable-object-coarse", "environment-object", "unchanged-child-inputs",
    "overlay-isolation", "background-isolation", "fixed-frame-boundary", "color-change", "foreach-edits",
    "conditional-branches", "environment-keys", "lazy-list",
]

@MainActor
@Suite(.serialized)
struct ParityTests {
    @Test func catalogIsCovered() {
        #expect(ScenarioCatalog.all().map(\.name).sorted() == scenarioNames.sorted())
    }

    struct Golden: Decodable {
        let recordedWith: String
        let scenarios: [String: [String: [String: Int]]]
    }

    static func loadGolden() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "swiftui-golden", withExtension: "json", subdirectory: "Golden"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }


    @Test(arguments: scenarioNames)
    func matchesSwiftUI(_ name: String) throws {
        let golden = try Self.loadGolden()
        let scenario = try #require(ScenarioCatalog.all().first { $0.name == name })
        let expected = try #require(golden.scenarios[name], "No golden data for \(name); run `swift run parity-recorder`")

        if Self.report { print("── \(name)") }
        Probe.reset()
        let host = TestHost(scenario.root, size: CGSize(width: 400, height: 600))
        compare(step: "initial", actual: Probe.counts, expected: expected["initial"] ?? [:])

        for step in scenario.steps {
            Probe.reset()
            step.action()
            host.flush()
            compare(step: step.name, actual: Probe.counts, expected: expected[step.name] ?? [:])
        }
    }

    /// Set `PARITY_REPORT=1` to print a side-by-side table.
    private static let report = ProcessInfo.processInfo.environment["PARITY_REPORT"] != nil

    private func compare(step: String, actual: [String: Int], expected: [String: Int]) {
        for key in Set(actual.keys).union(expected.keys).sorted() {
            let ours = actual[key] ?? 0
            let theirs = expected[key] ?? 0
            if Self.report {
                let pad = { (s: String, n: Int) in s.padding(toLength: n, withPad: " ", startingAt: 0) }
                print("  \(pad(step, 16)) \(pad(key, 34)) SwiftUI \(pad(String(theirs), 4)) SwiftUI \(ours)")
            }
            if ParityPolicy.isExact(key) {
                #expect(ours == theirs, "[\(step)] \(key): SwiftUI \(ours) vs SwiftUI \(theirs)")
            } else {
                #expect(ours <= theirs, "[\(step)] \(key): SwiftUI did more layout work (\(ours)) than SwiftUI (\(theirs))")
            }
        }
    }
}
