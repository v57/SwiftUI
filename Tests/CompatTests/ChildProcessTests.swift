#if os(Windows)
import Foundation
@testable import SwiftUIPortability
import Testing

struct ChildProcessTests {
    /// cmd runs a command line given as is, from its own (native) path, and the output and exit code come back.
    @Test func runsCmdWithVerbatimArguments() throws {
        let cmd = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe")
        let child = try ChildProcess(
            executable: cmd, arguments: ["/d", "/s", "/c", "\"echo hello & exit 3\""], directory: nil,
            environment: ProcessInfo.processInfo.environment, verbatimArguments: true)
        var output = Data()
        child.read(.output) { output.append($0) }
        #expect(child.waitUntilExit() == 3)
        #expect(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test func quotesArgumentsForTheCRuntime() {
        #expect(ChildProcess.quote("plain") == "plain")
        #expect(ChildProcess.quote("two words") == "\"two words\"")
        #expect(ChildProcess.quote("say \"hi\"") == #""say \"hi\"""#)
        #expect(ChildProcess.quote("dir\\") == "dir\\")
        #expect(ChildProcess.quote("a dir\\") == #""a dir\\""#)
        #expect(ChildProcess.nativePath("/C:/dev/sample") == "C:\\dev\\sample")
    }
}
#endif

#if os(Linux)
import Foundation
import SwiftUIPortability
import Testing

struct LinuxChildProcessTests {
    private func shell(_ script: String, input: Bool = false) throws -> ChildProcess {
        try ChildProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], directory: URL(fileURLWithPath: "/tmp"),
            environment: ["PATH": "/usr/bin:/bin"], input: input)
    }

    @Test func runsAndReportsTheExitCode() throws {
        let child = try shell("pwd; echo oops >&2; exit 3")
        var output = Data(), error = Data()
        child.read(.output) { output.append($0) }
        child.read(.error) { error.append($0) }
        #expect(child.waitUntilExit() == 3)
        #expect(String(decoding: output, as: UTF8.self) == "/tmp\n")
        #expect(String(decoding: error, as: UTF8.self) == "oops\n")
    }

    @Test func passesInput() throws {
        let child = try shell("tr a-z A-Z", input: true)
        child.write(Data("hello".utf8))
        child.closeInput()
        var output = Data()
        child.read(.output) { output.append($0) }
        #expect(child.waitUntilExit() == 0)
        #expect(String(decoding: output, as: UTF8.self) == "HELLO")
    }

    /// Children started at once each finish on their own: none holds another's pipes open (Foundation's Process
    /// hangs here).
    @Test func concurrentChildrenFinish() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let child = try shell("sleep 0.$((\(index) % 3)); echo \(index)")
                    var output = Data()
                    child.read(.output) { output.append($0) }
                    _ = child.waitUntilExit()
                    return String(decoding: output, as: UTF8.self)
                }
            }
            var lines: [String] = []
            for try await line in group { lines.append(line) }
            #expect(lines.sorted() == (0..<8).map { "\($0)\n" })
        }
    }

    @Test func terminateEndsTheGroup() throws {
        let child = try shell("sleep 30 & sleep 30; echo late")
        Thread.sleep(forTimeInterval: 0.2)
        child.terminate()
        var output = Data()
        child.read(.output) { output.append($0) }
        #expect(child.waitUntilExit() == 128 + SIGTERM)
        #expect(output.isEmpty)
    }
}
#endif
