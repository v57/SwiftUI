#if os(Linux)
import Foundation
import SwiftUIPortability
import Testing

/// inotify under the kits' watchers: files and folders made, written and removed, folders made after the start.
struct DirectoryWatcherTests {
    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var changes: [DirectoryWatcher.Change] = []
        func add(_ batch: [DirectoryWatcher.Change]) { lock.withLock { changes += batch } }
        func take() -> [DirectoryWatcher.Change] { lock.withLock { defer { changes = [] }; return changes } }
    }

    func waitFor(_ collected: Collected, _ condition: ([DirectoryWatcher.Change]) -> Bool) async throws -> [DirectoryWatcher.Change] {
        var seen: [DirectoryWatcher.Change] = []
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            seen += collected.take()
            if condition(seen) { return seen }
        }
        return seen
    }

    @Test func reportsChangesInNewFoldersToo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let collected = Collected()
        let queue = DispatchQueue(label: "test")
        let watcher = try #require(DirectoryWatcher(paths: [root], latency: 0.05, queue: queue) { collected.add($0) })
        defer { watcher.stop() }

        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/a/file.txt"))
        var seen = try await waitFor(collected) { $0.contains { $0.path == root + "/a/file.txt" && $0.structural } }
        #expect(seen.contains { $0.path == root + "/a/file.txt" && $0.structural })

        try FileManager.default.createDirectory(atPath: root + "/b/c", withIntermediateDirectories: true)
        _ = try await waitFor(collected) { $0.contains { $0.path == root + "/b" } }
        try Data("y".utf8).write(to: URL(fileURLWithPath: root + "/b/c/new.txt"))
        seen = try await waitFor(collected) { $0.contains { $0.path == root + "/b/c/new.txt" } }
        #expect(seen.contains { $0.path == root + "/b/c/new.txt" })

        try FileManager.default.removeItem(atPath: root + "/a/file.txt")
        seen = try await waitFor(collected) { $0.contains { $0.path == root + "/a/file.txt" } }
        #expect(seen.contains { $0.path == root + "/a/file.txt" && $0.structural })

        watcher.stop()
        try Data("z".utf8).write(to: URL(fileURLWithPath: root + "/a/late.txt"))
        seen = try await waitFor(collected) { _ in false }
        #expect(seen.isEmpty)
    }
}
#endif
