// Foundation file APIs Apple platforms have and swift-corelibs-foundation lacks. Built on non-Apple platforms only.
#if !canImport(ObjectiveC)
import Foundation

#if os(Windows)
import WinSDK
#endif

extension URL {
    /// Apple's sandbox access to a URL the user picked; off Apple platforms there is no sandbox to ask.
    public func startAccessingSecurityScopedResource() -> Bool { true }
    public func stopAccessingSecurityScopedResource() {}
}

extension FileManager {
    /// Moves an item to the Trash (the Recycle Bin on Windows; the freedesktop.org trash elsewhere).
    public func trashItem(at url: URL, resultingItemURL outResultingURL: UnsafeMutablePointer<NSURL?>?) throws {
        #if os(Windows)
        // SHFileOperation takes a list of paths ending in two NULs.
        let path = url.path.replacingOccurrences(of: "/", with: "\\")
        var from = Array(path.utf16) + [0, 0]
        let status = from.withUnsafeMutableBufferPointer { buffer -> Int32 in
            var operation = SHFILEOPSTRUCTW()
            operation.wFunc = UINT(FO_DELETE)
            operation.pFrom = UnsafePointer(buffer.baseAddress)
            operation.fFlags = FILEOP_FLAGS(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI)
            return SHFileOperationW(&operation)
        }
        guard status == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, "SHFileOperation": status])
        }
        outResultingURL?.pointee = nil
        #else
        let home = homeDirectoryForCurrentUser
        let trash = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        let files = trash.appendingPathComponent("Trash/files", isDirectory: true)
        let info = trash.appendingPathComponent("Trash/info", isDirectory: true)
        try createDirectory(at: files, withIntermediateDirectories: true)
        try createDirectory(at: info, withIntermediateDirectories: true)
        var target = files.appendingPathComponent(url.lastPathComponent)
        var number = 2
        while fileExists(atPath: target.path) {
            target = files.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(number)")
                .appendingPathExtension(url.pathExtension)
            number += 1
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try "[Trash Info]\nPath=\(url.path)\nDeletionDate=\(stamp)\n".write(
            to: info.appendingPathComponent(target.lastPathComponent + ".trashinfo"), atomically: true, encoding: .utf8)
        try moveItem(at: url, to: target)
        outResultingURL?.pointee = target as NSURL
        #endif
    }
}

extension URL {
    /// The user's well-known folders (Apple's `URL.documentsDirectory` and friends).
    public static var documentsDirectory: URL { folder(.documentDirectory) }
    public static var applicationSupportDirectory: URL { folder(.applicationSupportDirectory) }
    public static var cachesDirectory: URL { folder(.cachesDirectory) }
    public static var downloadsDirectory: URL { folder(.downloadsDirectory) }
    public static var desktopDirectory: URL { folder(.desktopDirectory) }
    public static var moviesDirectory: URL { folder(.moviesDirectory) }
    public static var musicDirectory: URL { folder(.musicDirectory) }
    public static var picturesDirectory: URL { folder(.picturesDirectory) }
    public static var libraryDirectory: URL { folder(.libraryDirectory) }

    private static func folder(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    public struct BookmarkCreationOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let minimalBookmark = BookmarkCreationOptions(rawValue: 1 << 9)
        public static let suitableForBookmarkFile = BookmarkCreationOptions(rawValue: 1 << 10)
        public static let withSecurityScope = BookmarkCreationOptions(rawValue: 1 << 11)
        public static let securityScopeAllowOnlyReadAccess = BookmarkCreationOptions(rawValue: 1 << 12)
        public static let withoutImplicitSecurityScope = BookmarkCreationOptions(rawValue: 1 << 29)
    }

    public struct BookmarkResolutionOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let withoutUI = BookmarkResolutionOptions(rawValue: 1 << 8)
        public static let withoutMounting = BookmarkResolutionOptions(rawValue: 1 << 9)
        public static let withSecurityScope = BookmarkResolutionOptions(rawValue: 1 << 10)
        public static let withoutImplicitStartAccessing = BookmarkResolutionOptions(rawValue: 1 << 15)
    }

    private static let bookmarkPrefix = "v57-bookmark:"

    /// A bookmark: off Apple platforms, the file's path (there is no sandbox to carry access through a relaunch).
    public func bookmarkData(
        options: BookmarkCreationOptions = [], includingResourceValuesForKeys keys: Set<URLResourceKey>? = nil,
        relativeTo url: URL? = nil
    ) throws -> Data {
        Data((Self.bookmarkPrefix + standardizedFileURL.path).utf8)
    }

    public init(
        resolvingBookmarkData data: Data, options: BookmarkResolutionOptions = [], relativeTo url: URL? = nil,
        bookmarkDataIsStale: inout Bool
    ) throws {
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix(Self.bookmarkPrefix) else { throw CocoaError(.fileReadCorruptFile) }
        let path = String(text.dropFirst(Self.bookmarkPrefix.count))
        guard FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        bookmarkDataIsStale = false
        self = URL(fileURLWithPath: path)
    }
}

extension FileManager {
    /// iCloud: off Apple platforms there is no signed-in account.
    public var ubiquityIdentityToken: (any NSObjectProtocol)? { nil }
    public func url(forUbiquityContainerIdentifier containerIdentifier: String?) -> URL? { nil }
}

// MARK: - File coordination

/// Apple's file presenter: an object that shows a file or folder and hears about changes to it. Off Apple platforms
/// `NSFileCoordinator.addFilePresenter` watches the item by looking at it once a second.
public protocol NSFilePresenter: AnyObject {
    var presentedItemURL: URL? { get }
    var presentedItemOperationQueue: OperationQueue { get }
    func presentedItemDidChange()
    func presentedItemDidMove(to newURL: URL)
    func presentedSubitemDidChange(at url: URL)
    func presentedSubitemDidAppear(at url: URL)
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL)
    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void)
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void)
    func savePresentedItemChanges(completionHandler: @escaping @Sendable ((any Error)?) -> Void)
}

extension NSFilePresenter {
    public func presentedItemDidChange() {}
    public func presentedItemDidMove(to newURL: URL) {}
    public func presentedSubitemDidChange(at url: URL) {}
    public func presentedSubitemDidAppear(at url: URL) {}
    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {}
    public func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) { completionHandler(nil) }
    public func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) { completionHandler(nil) }
    public func savePresentedItemChanges(completionHandler: @escaping @Sendable ((any Error)?) -> Void) { completionHandler(nil) }
}

/// Coordinated file access. Off Apple platforms reads and writes run at once (no other process coordinates), and
/// presenters hear about changes from a watcher that compares the item's files once a second.
open class NSFileCoordinator: NSObject, @unchecked Sendable {
    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let withoutChanges = ReadingOptions(rawValue: 1 << 0)
        public static let resolvesSymbolicLink = ReadingOptions(rawValue: 1 << 1)
        public static let immediatelyAvailableMetadataOnly = ReadingOptions(rawValue: 1 << 2)
        public static let forUploading = ReadingOptions(rawValue: 1 << 3)
    }

    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let forDeleting = WritingOptions(rawValue: 1 << 0)
        public static let forMoving = WritingOptions(rawValue: 1 << 1)
        public static let forMerging = WritingOptions(rawValue: 1 << 2)
        public static let forReplacing = WritingOptions(rawValue: 1 << 3)
        public static let contentIndependentMetadataOnly = WritingOptions(rawValue: 1 << 4)
    }

    private weak var filePresenter: (any NSFilePresenter)?

    public init(filePresenter: (any NSFilePresenter)? = nil) {
        self.filePresenter = filePresenter
        super.init()
    }

    open class func addFilePresenter(_ filePresenter: any NSFilePresenter) { PresenterWatcher.shared.add(filePresenter) }
    open class func removeFilePresenter(_ filePresenter: any NSFilePresenter) { PresenterWatcher.shared.remove(filePresenter) }
    open class var filePresenters: [any NSFilePresenter] { PresenterWatcher.shared.presenters }

    open func coordinate(
        readingItemAt url: URL, options: ReadingOptions = [], error outError: UnsafeMutablePointer<NSError?>?,
        byAccessor reader: (URL) -> Void
    ) {
        reader(url)
    }

    open func coordinate(
        writingItemAt url: URL, options: WritingOptions = [], error outError: UnsafeMutablePointer<NSError?>?,
        byAccessor writer: (URL) -> Void
    ) {
        writer(url)
        wrote()
    }

    open func coordinate(
        readingItemAt readingURL: URL, options readingOptions: ReadingOptions = [], writingItemAt writingURL: URL,
        options writingOptions: WritingOptions = [], error outError: UnsafeMutablePointer<NSError?>?,
        byAccessor readerWriter: (URL, URL) -> Void
    ) {
        readerWriter(readingURL, writingURL)
        wrote()
    }

    open func coordinate(
        writingItemAt url1: URL, options options1: WritingOptions = [], writingItemAt url2: URL,
        options options2: WritingOptions = [], error outError: UnsafeMutablePointer<NSError?>?,
        byAccessor writer: (URL, URL) -> Void
    ) {
        writer(url1, url2)
        wrote()
    }

    open func item(at oldURL: URL, willMoveTo newURL: URL) {}
    open func item(at oldURL: URL, didMoveTo newURL: URL) {}
    open func cancel() {}

    /// The writer's own presenter doesn't hear about its change (as on Apple platforms).
    private func wrote() {
        if let filePresenter { PresenterWatcher.shared.resnapshot(filePresenter) }
    }
}

/// Compares each presenter's item (a file, or a folder's files) once a second.
final class PresenterWatcher: @unchecked Sendable {
    static let shared = PresenterWatcher()

    private struct Watched {
        weak var presenter: (any NSFilePresenter)?
        var snapshot: [String: [Double]]
    }

    private let lock = NSLock()
    private var watched: [ObjectIdentifier: Watched] = [:]
    private var timer: DispatchSourceTimer?

    var presenters: [any NSFilePresenter] { lock.withLock { watched.values.compactMap(\.presenter) } }

    func add(_ presenter: any NSFilePresenter) {
        let snapshot = Self.snapshot(presenter.presentedItemURL)
        lock.withLock {
            watched[ObjectIdentifier(presenter)] = Watched(presenter: presenter, snapshot: snapshot)
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
                timer.setEventHandler { [weak self] in self?.check() }
                timer.resume()
                self.timer = timer
            }
        }
    }

    func remove(_ presenter: any NSFilePresenter) {
        lock.withLock { _ = watched.removeValue(forKey: ObjectIdentifier(presenter)) }
    }

    func resnapshot(_ presenter: any NSFilePresenter) {
        let snapshot = Self.snapshot(presenter.presentedItemURL)
        lock.withLock { watched[ObjectIdentifier(presenter)]?.snapshot = snapshot }
    }

    private func check() {
        let entries = lock.withLock { watched }
        for (key, entry) in entries {
            guard let presenter = entry.presenter else {
                lock.withLock { _ = watched.removeValue(forKey: key) }
                continue
            }
            let current = Self.snapshot(presenter.presentedItemURL)
            guard current != entry.snapshot else { continue }
            lock.withLock { watched[key]?.snapshot = current }
            let changed = Set(current.keys).union(entry.snapshot.keys).filter { current[$0] != entry.snapshot[$0] }
            let appeared = Set(current.keys).subtracting(entry.snapshot.keys)
            let root = presenter.presentedItemURL?.standardizedFileURL.path
            // The presenter's queue is where it expects its calls (Apple's contract), from any thread.
            nonisolated(unsafe) let target = presenter
            presenter.presentedItemOperationQueue.addOperation {
                for path in changed where path != root {
                    let url = URL(fileURLWithPath: path)
                    if appeared.contains(path) { target.presentedSubitemDidAppear(at: url) }
                    target.presentedSubitemDidChange(at: url)
                }
                target.presentedItemDidChange()
            }
        }
    }

    /// Paths → (modification date, size) of the item and, for a folder, everything in it.
    static func snapshot(_ url: URL?) -> [String: [Double]] {
        guard let url = url?.standardizedFileURL else { return [:] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        func entry(_ item: URL) -> [Double] {
            let values = try? item.resourceValues(forKeys: Set(keys))
            return [values?.contentModificationDate?.timeIntervalSince1970 ?? 0, Double(values?.fileSize ?? 0)]
        }
        var result: [String: [Double]] = [:]
        guard FileManager.default.fileExists(atPath: url.path) else { return result }
        result[url.path] = entry(url)
        if let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in files { result[file.standardizedFileURL.path] = entry(file) }
        }
        return result
    }
}
#endif
