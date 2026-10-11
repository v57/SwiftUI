// Foundation types that SwiftUI's API mentions but swift-corelibs-foundation lacks
// (`NSItemProvider`, `NSUserActivity`, `FileWrapper`). Built on non-Apple platforms only.
#if !canImport(ObjectiveC)
import Foundation

/// Lazily provides data for drag & drop, copy/paste and sharing, by type identifier.
open class NSItemProvider: NSObject, @unchecked Sendable {
    public enum RepresentationVisibility: Int, Sendable { case all, team, group, ownProcess }
    public struct FileOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let openInPlace = FileOptions(rawValue: 1)
    }
    public typealias LoadHandler = (@escaping @Sendable (Data?, (any Error)?) -> Void) -> Progress?

    private struct Representation {
        let type: String
        let load: LoadHandler
    }

    private var representations: [Representation] = []
    private let lock = NSLock()
    public var suggestedName: String?

    public override init() { super.init() }

    /// Strings, URLs and data, registered under their natural type identifiers.
    public convenience init(object: Any) {
        self.init()
        switch object {
        case let string as String: registerString(string)
        case let string as NSString: registerString(string as String)
        case let url as URL: registerURL(url)
        case let url as NSURL: registerURL(url as URL)
        case let data as Data: registerData(data, type: "public.data")
        default: registerString(String(describing: object))
        }
    }

    public convenience init?(contentsOf fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        self.init()
        suggestedName = fileURL.lastPathComponent
        registerURL(fileURL)
        registerData(data, type: "public.data")
    }

    private func registerString(_ string: String) {
        let data = Data(string.utf8)
        registerData(data, type: "public.utf8-plain-text")
        registerData(data, type: "public.plain-text")
    }

    private func registerURL(_ url: URL) {
        registerData(url.dataRepresentation, type: url.isFileURL ? "public.file-url" : "public.url")
    }

    private func registerData(_ data: Data, type: String) {
        registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
    }

    public var registeredTypeIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return representations.map(\.type)
    }

    public func registeredTypeIdentifiers(fileOptions: FileOptions) -> [String] { registeredTypeIdentifiers }

    public func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool {
        registeredTypeIdentifiers.contains(typeIdentifier)
    }

    public func hasRepresentationConforming(toTypeIdentifier typeIdentifier: String, fileOptions: FileOptions = []) -> Bool {
        hasItemConformingToTypeIdentifier(typeIdentifier)
    }

    public func registerDataRepresentation(forTypeIdentifier typeIdentifier: String, visibility: RepresentationVisibility, loadHandler: @escaping LoadHandler) {
        lock.lock(); defer { lock.unlock() }
        representations.append(Representation(type: typeIdentifier, load: loadHandler))
    }

    public func registerFileRepresentation(forTypeIdentifier typeIdentifier: String, fileOptions: FileOptions = [], visibility: RepresentationVisibility,
                                           loadHandler: @escaping (@escaping @Sendable (URL?, Bool, (any Error)?) -> Void) -> Progress?) {
        registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: visibility) { completion in
            loadHandler { url, _, error in
                completion(url.flatMap { try? Data(contentsOf: $0) }, error)
            }
        }
    }

    public func registerObject(_ object: Any, visibility: RepresentationVisibility) {
        let other = NSItemProvider(object: object)
        lock.lock(); defer { lock.unlock() }
        representations += other.representations
    }

    @discardableResult
    public func loadDataRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void) -> Progress {
        let representation = { lock.lock(); defer { lock.unlock() }; return representations.first { $0.type == typeIdentifier } }()
        guard let representation else {
            completionHandler(nil, CocoaError(.fileReadUnknown))
            return Progress(totalUnitCount: 0)
        }
        return representation.load(completionHandler) ?? Progress(totalUnitCount: 1)
    }

    @discardableResult
    public func loadFileRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            guard let data else { return completionHandler(nil, error) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try data.write(to: url)
                completionHandler(url, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    /// `loadItem(forTypeIdentifier:options:)`: the item as data, string or URL.
    public func loadItem(forTypeIdentifier typeIdentifier: String, options: [AnyHashable: Any]? = nil, completionHandler: (@Sendable ((any NSSecureCoding)?, (any Error)?) -> Void)? = nil) {
        loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            guard let data else { completionHandler?(nil, error); return }
            if typeIdentifier.hasSuffix("url"), let url = URL(dataRepresentation: data, relativeTo: nil) {
                completionHandler?(url as NSURL, nil)
            } else if typeIdentifier.contains("text"), let string = String(data: data, encoding: .utf8) {
                completionHandler?(string as NSString, nil)
            } else {
                completionHandler?(data as NSData, nil)
            }
        }
    }

    public func canLoadObject(ofClass aClass: Any.Type) -> Bool {
        if aClass == String.self || aClass == NSString.self { return registeredTypeIdentifiers.contains { $0.contains("text") } }
        if aClass == URL.self || aClass == NSURL.self { return registeredTypeIdentifiers.contains { $0.hasSuffix("url") } }
        return false
    }

    /// Strings and URLs (`loadObject(ofClass: String.self)` / `URL.self`).
    @discardableResult
    public func loadObject<T>(ofClass aClass: T.Type, completionHandler: @escaping @Sendable (T?, (any Error)?) -> Void) -> Progress {
        if aClass == String.self || aClass == NSString.self, let type = registeredTypeIdentifiers.first(where: { $0.contains("text") }) {
            return loadDataRepresentation(forTypeIdentifier: type) { data, error in
                let string = data.flatMap { String(data: $0, encoding: .utf8) }
                completionHandler((aClass == NSString.self ? string.map { $0 as NSString } as Any? : string as Any?) as? T, error)
            }
        }
        if aClass == URL.self || aClass == NSURL.self, let type = registeredTypeIdentifiers.first(where: { $0.hasSuffix("url") }) {
            return loadDataRepresentation(forTypeIdentifier: type) { data, error in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                completionHandler((aClass == NSURL.self ? url.map { $0 as NSURL } as Any? : url as Any?) as? T, error)
            }
        }
        completionHandler(nil, CocoaError(.fileReadUnknown))
        return Progress(totalUnitCount: 0)
    }
}

/// Activity state for handoff / state restoration (`userActivity`, `onContinueUserActivity`).
open class NSUserActivity: NSObject, @unchecked Sendable {
    public let activityType: String
    open var title: String?
    open var userInfo: [AnyHashable: Any]?
    open var requiredUserInfoKeys: Set<String>?
    open var webpageURL: URL?
    open var referrerURL: URL?
    open var expirationDate: Date?
    open var keywords: Set<String> = []
    open var targetContentIdentifier: String?
    open var persistentIdentifier: String?
    open var isEligibleForHandoff = true
    open var isEligibleForSearch = false
    open var isEligibleForPublicIndexing = false
    open var isEligibleForPrediction = false
    open var needsSave = false

    public init(activityType: String) {
        self.activityType = activityType
        super.init()
    }

    open func addUserInfoEntries(from otherDictionary: [AnyHashable: Any]) {
        var info = userInfo ?? [:]
        for (key, value) in otherDictionary { info[key] = value }
        userInfo = info
    }

    open func becomeCurrent() {}
    open func resignCurrent() {}
    open func invalidate() {}
}

/// A file or directory tree in memory (`FileDocument`).
open class FileWrapper: NSObject, @unchecked Sendable {
    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let immediate = ReadingOptions(rawValue: 1)
        public static let withoutMapping = ReadingOptions(rawValue: 2)
    }
    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let atomic = WritingOptions(rawValue: 1)
        public static let withNameUpdating = WritingOptions(rawValue: 2)
    }

    private enum Kind { case regular(Data), directory([String: FileWrapper]), symbolicLink(URL) }
    private var kind: Kind
    open var filename: String?
    open var preferredFilename: String?
    open var fileAttributes: [String: Any] = [:]

    public init(regularFileWithContents contents: Data) {
        kind = .regular(contents)
        super.init()
    }

    public init(directoryWithFileWrappers childrenByPreferredName: [String: FileWrapper]) {
        kind = .directory(childrenByPreferredName)
        super.init()
        for (name, child) in childrenByPreferredName where child.preferredFilename == nil { child.preferredFilename = name }
    }

    public init(symbolicLinkWithDestinationURL url: URL) {
        kind = .symbolicLink(url)
        super.init()
    }

    public init(url: URL, options: ReadingOptions = []) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw CocoaError(.fileReadNoSuchFile) }
        if let destination = try? manager.destinationOfSymbolicLink(atPath: url.path) {
            kind = .symbolicLink(URL(fileURLWithPath: destination))
        } else if isDirectory.boolValue {
            var children: [String: FileWrapper] = [:]
            for name in try manager.contentsOfDirectory(atPath: url.path) {
                children[name] = try FileWrapper(url: url.appendingPathComponent(name), options: options)
            }
            kind = .directory(children)
        } else {
            kind = .regular(try Data(contentsOf: url))
        }
        super.init()
        filename = url.lastPathComponent
        preferredFilename = url.lastPathComponent
    }

    open var isRegularFile: Bool { if case .regular = kind { return true }; return false }
    open var isDirectory: Bool { if case .directory = kind { return true }; return false }
    open var isSymbolicLink: Bool { if case .symbolicLink = kind { return true }; return false }

    open var regularFileContents: Data? { if case .regular(let data) = kind { return data }; return nil }
    open var fileWrappers: [String: FileWrapper]? { if case .directory(let children) = kind { return children }; return nil }
    open var symbolicLinkDestinationURL: URL? { if case .symbolicLink(let url) = kind { return url }; return nil }
    open var serializedRepresentation: Data? { regularFileContents }

    @discardableResult
    open func addFileWrapper(_ child: FileWrapper) -> String {
        guard case .directory(var children) = kind else { return "" }
        let name = child.preferredFilename ?? child.filename ?? UUID().uuidString
        children[name] = child
        kind = .directory(children)
        return name
    }

    @discardableResult
    open func addRegularFile(withContents data: Data, preferredFilename fileName: String) -> String {
        let child = FileWrapper(regularFileWithContents: data)
        child.preferredFilename = fileName
        return addFileWrapper(child)
    }

    open func removeFileWrapper(_ child: FileWrapper) {
        guard case .directory(var children) = kind else { return }
        children = children.filter { $0.value !== child }
        kind = .directory(children)
    }

    open func keyForChildFileWrapper(_ child: FileWrapper) -> String? {
        fileWrappers?.first { $0.value === child }?.key
    }

    open func matchesContents(of url: URL) -> Bool {
        guard let other = try? FileWrapper(url: url) else { return false }
        return regularFileContents == other.regularFileContents
    }

    open func read(from url: URL, options: ReadingOptions = []) throws {
        kind = try FileWrapper(url: url, options: options).kind
    }

    open func write(to url: URL, options: WritingOptions = [], originalContentsURL: URL?) throws {
        let manager = FileManager.default
        switch kind {
        case .regular(let data):
            try data.write(to: url, options: options.contains(.atomic) ? .atomic : [])
        case .directory(let children):
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, child) in children {
                try child.write(to: url.appendingPathComponent(name), options: options, originalContentsURL: nil)
            }
        case .symbolicLink(let destination):
            try manager.createSymbolicLink(at: url, withDestinationURL: destination)
        }
        if options.contains(.withNameUpdating) { filename = url.lastPathComponent }
    }
}
#endif
