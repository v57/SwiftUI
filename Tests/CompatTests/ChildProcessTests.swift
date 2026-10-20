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
