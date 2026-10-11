// Records update counts of the parity scenarios on Apple's SwiftUI. The output is the golden data
// SwiftUI is checked against (Tests/ParityTests).
//
//   swift run --package-path AppleSwiftUI parity-recorder [output-path]
//
// Default output (relative to the working directory, normally the repository root):
// Parity/Golden/swiftui-golden.json
import AppKit
import Foundation
import AppleParityScenarios
import SwiftUI

@MainActor
func pump() {
    // Let SwiftUI run its update/layout transaction(s) like a real run loop turn would.
    for _ in 0..<3 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
    }
}

@MainActor
func record(_ scenario: ParityScenario) -> ParityRecording {
    let window = NSWindow(
        contentRect: CGRect(x: -10_000, y: -10_000, width: 400, height: 600),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let host = NSHostingView(rootView: scenario.root)
    host.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
    var recording: ParityRecording = [:]

    Probe.reset()
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    pump()
    recording["initial"] = Probe.counts

    for step in scenario.steps {
        Probe.reset()
        step.action()
        pump()
        host.layoutSubtreeIfNeeded()
        pump()
        recording[step.name] = Probe.counts
    }
    window.orderOut(nil)
    window.contentView = nil
    return recording
}

@MainActor
func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let output = CommandLine.arguments.dropFirst().first ?? "Parity/Golden/swiftui-golden.json"

    var scenarios: [String: ParityRecording] = [:]
    for scenario in ScenarioCatalog.all() {
        scenarios[scenario.name] = record(scenario)
        print("recorded \(scenario.name)")
    }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let document: [String: Any] = [
        "recordedWith": "SwiftUI on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        "windowSize": [400, 600],
        "scenarios": scenarios,
    ]
    let data = try! JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
}

MainActor.assumeIsolated { run() }
