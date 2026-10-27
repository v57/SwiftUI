// Linux's file-system events (inotify), as the kits' watchers need them where macOS has FSEvents.
#if os(Linux)
import Foundation
import Glibc

/// Watches folder trees with inotify and hands what changed under them to `handler` on `queue`, gathered over
/// `latency` seconds, as an FSEvents stream does. inotify watches one folder at a time: the watcher adds every
/// folder below the roots (symbolic links aren't followed) and each folder made or moved in later. A thread reads
/// the events; `stop` ends it.
public final class DirectoryWatcher: @unchecked Sendable {
    /// One changed path. `structural`: an item was created, removed or renamed (not just written). `rescan`: events
    /// were dropped (the kernel's queue overflowed), so everything under `path` may have changed.
    public struct Change: Sendable, Equatable {
        public let path: String
        public let structural: Bool
        public let rescan: Bool

        public init(path: String, structural: Bool, rescan: Bool) {
            self.path = path
            self.structural = structural
            self.rescan = rescan
        }
    }

    private let fd: Int32
    private var wake: [Int32] = [-1, -1]
    private let lock = NSLock()
    /// Watch descriptor → its folder's path.
    private var folders: [Int32: String] = [:]
    private var pending: [Change] = []
    private var flushScheduled = false
    private var stopped = false
    private let roots: [String]
    private let fileEvents: Bool
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let handler: @Sendable ([Change]) -> Void

    /// Nil when inotify can't be used. Without `fileEvents` a change is the folder whose items changed, like an
    /// FSEvents stream without its file-events flag.
    public init?(
        paths: [String], fileEvents: Bool = true, latency: TimeInterval = 0.3, queue: DispatchQueue = .main,
        handler: @escaping @Sendable ([Change]) -> Void
    ) {
        fd = inotify_init1(Int32(IN_CLOEXEC | IN_NONBLOCK))
        guard fd >= 0 else { return nil }
        guard pipe(&wake) == 0 else {
            close(fd)
            return nil
        }
        roots = paths.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        self.fileEvents = fileEvents
        self.latency = latency
        self.queue = queue
        self.handler = handler
        lock.withLock { for root in roots { addTree(root) } }
        let thread = Thread { [self] in run() }
        thread.name = "SwiftUIPortability.DirectoryWatcher"
        thread.start()
    }

    deinit { stop() }

    /// Stops watching; no handler call is scheduled after it returns.
    public func stop() {
        let wasStopped: Bool = lock.withLock {
            defer { stopped = true }
            return stopped
        }
        guard !wasStopped else { return }
        var byte: UInt8 = 1
        _ = Glibc.write(wake[1], &byte, 1)
    }

    private static let mask: UInt32 = {
        let changes: Int32 = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_MODIFY | IN_CLOSE_WRITE
        let selfChanges: Int32 = IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF
        let flags: Int32 = IN_DONT_FOLLOW | IN_ONLYDIR
        return UInt32(bitPattern: changes | selfChanges | flags)
    }()

    /// Watches `path` and every folder below it. Called with the lock held.
    private func addTree(_ path: String) {
        var stack = [path]
        while let folder = stack.popLast() {
            let descriptor = inotify_add_watch(fd, folder, Self.mask)
            guard descriptor >= 0 else { continue }
            folders[descriptor] = folder
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names {
                let child = folder == "/" ? "/" + name : folder + "/" + name
                var info = stat()
                // lstat: a link to a folder isn't followed, as FSEvents doesn't.
                if lstat(child, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { stack.append(child) }
            }
        }
    }

    private func run() {
        defer {
            close(fd)
            close(wake[0])
            close(wake[1])
        }
        let size = MemoryLayout<inotify_event>.size
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var descriptors = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 || descriptors[1].revents != 0 || lock.withLock({ stopped }) { return }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { continue }
            var changes: [Change] = []
            buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset + size <= count {
                    let descriptor = raw.load(fromByteOffset: offset, as: Int32.self)
                    let mask = raw.load(fromByteOffset: offset + 4, as: UInt32.self)
                    let length = Int(raw.load(fromByteOffset: offset + 12, as: UInt32.self))
                    var name = ""
                    if length > 0 {
                        let bytes = UnsafeRawBufferPointer(rebasing: raw[(offset + size)..<(offset + size + length)])
                        name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    offset += size + length
                    handle(descriptor: descriptor, mask: mask, name: name, into: &changes)
                }
            }
            guard !changes.isEmpty else { continue }
            let flush: Bool = lock.withLock {
                pending += changes
                guard !flushScheduled else { return false }
                flushScheduled = true
                return true
            }
            if flush {
                queue.asyncAfter(deadline: .now() + latency) { [self] in
                    let batch: [Change] = lock.withLock {
                        flushScheduled = false
                        defer { pending = [] }
                        guard !stopped else { return [] }
                        var seen = Set<String>()
                        // The last change of a path wins its place; a structural one is kept over writes.
                        let structural = Set(pending.filter(\.structural).map(\.path))
                        return pending.reversed().filter { seen.insert($0.path).inserted }.reversed().map {
                            structural.contains($0.path) && !$0.structural
                                ? Change(path: $0.path, structural: true, rescan: $0.rescan) : $0
                        }
                    }
                    if !batch.isEmpty { handler(batch) }
                }
            }
        }
    }

    private func handle(descriptor: Int32, mask: UInt32, name: String, into changes: inout [Change]) {
        if mask & UInt32(IN_Q_OVERFLOW) != 0 {
            changes += roots.map { Change(path: $0, structural: true, rescan: true) }
            return
        }
        lock.withLock {
            guard let folder = folders[descriptor] else { return }
            if mask & UInt32(IN_IGNORED) != 0 {
                folders[descriptor] = nil
                return
            }
            let path = name.isEmpty ? folder : (folder == "/" ? "/" + name : folder + "/" + name)
            let structural = mask & UInt32(IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF) != 0
            // A folder made or moved in: watch it and what's already inside.
            if mask & UInt32(IN_ISDIR) != 0, mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0 { addTree(path) }
            let change = Change(path: fileEvents ? path : folder, structural: structural, rescan: false)
            // A write comes as several events (modify, close): one is enough.
            if changes.last != change { changes.append(change) }
        }
    }
}
#endif
