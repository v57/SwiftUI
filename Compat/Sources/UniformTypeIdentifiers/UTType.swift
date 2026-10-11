import Foundation

/// The subset of Apple's `UTType` that apps and SwiftUI use: identifiers, conformance, file
/// extensions and MIME types for the common system types, plus app-declared types.
public struct UTType: Hashable, Sendable, Codable, CustomStringConvertible {
    public let identifier: String

    struct Declaration: Sendable {
        var conformsTo: [String]
        var extensions: [String] = []
        var mimeTypes: [String] = []
        var isDynamic = false
    }

    public init?(_ identifier: String) {
        guard Registry.declaration(identifier) != nil else { return nil }
        self.identifier = identifier
    }

    init(known identifier: String) { self.identifier = identifier }

    /// A type the app exports (declared in its Info.plist on Apple platforms).
    public init(exportedAs identifier: String, conformingTo parentType: UTType? = nil) {
        self.identifier = identifier
        Registry.declare(identifier, conformsTo: [parentType?.identifier ?? "public.data"])
    }

    /// A type the app imports (declared by another app).
    public init(importedAs identifier: String, conformingTo parentType: UTType? = nil) {
        self.init(exportedAs: identifier, conformingTo: parentType)
    }

    /// The type for a file extension; unknown extensions get a dynamic type conforming to
    /// `supertype` (like Apple's `dyn.` types).
    public init?(filenameExtension: String, conformingTo supertype: UTType = .data) {
        let ext = filenameExtension.lowercased()
        if let match = Registry.lookup(extension: ext), UTType(known: match).conforms(to: supertype) {
            identifier = match
            return
        }
        let dynamic = "dyn.ext-\(ext)"
        Registry.declare(dynamic, conformsTo: [supertype.identifier], extensions: [ext], isDynamic: true)
        identifier = dynamic
    }

    public init?(mimeType: String, conformingTo supertype: UTType = .data) {
        guard let match = Registry.lookup(mimeType: mimeType.lowercased()), UTType(known: match).conforms(to: supertype) else { return nil }
        identifier = match
    }

    public init?(tag: String, tagClass: UTTagClass, conformingTo supertype: UTType?) {
        switch tagClass {
        case .filenameExtension: self.init(filenameExtension: tag, conformingTo: supertype ?? .data)
        case .mimeType: self.init(mimeType: tag, conformingTo: supertype ?? .data)
        default: return nil
        }
    }

    public var preferredFilenameExtension: String? { Registry.declaration(identifier)?.extensions.first }
    public var preferredMIMEType: String? { Registry.declaration(identifier)?.mimeTypes.first }
    public var tags: [UTTagClass: [String]] {
        guard let declaration = Registry.declaration(identifier) else { return [:] }
        var tags: [UTTagClass: [String]] = [:]
        if !declaration.extensions.isEmpty { tags[.filenameExtension] = declaration.extensions }
        if !declaration.mimeTypes.isEmpty { tags[.mimeType] = declaration.mimeTypes }
        return tags
    }
    public var localizedDescription: String? { identifier }
    public var isDynamic: Bool { Registry.declaration(identifier)?.isDynamic ?? false }
    public var isDeclared: Bool { !isDynamic }
    public var isPublic: Bool { identifier.hasPrefix("public.") || identifier.hasPrefix("com.apple.") }
    public var isSystemDeclared: Bool { isPublic }
    public var description: String { identifier }

    /// All types this one conforms to, transitively (not including itself).
    public var supertypes: Set<UTType> {
        var result: Set<String> = []
        var queue = Registry.declaration(identifier)?.conformsTo ?? []
        while let next = queue.popLast() {
            guard result.insert(next).inserted else { continue }
            queue += Registry.declaration(next)?.conformsTo ?? []
        }
        return Set(result.map(UTType.init(known:)))
    }

    public func conforms(to type: UTType) -> Bool {
        type.identifier == identifier || supertypes.contains(type)
    }

    public func isSupertype(of type: UTType) -> Bool { type.conforms(to: self) }
    public func isSubtype(of type: UTType) -> Bool { conforms(to: self) && self != type }

    public static func types(tag: String, tagClass: UTTagClass, conformingTo supertype: UTType?) -> [UTType] {
        UTType(tag: tag, tagClass: tagClass, conformingTo: supertype).map { [$0] } ?? []
    }

    public init(from decoder: any Decoder) throws {
        identifier = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

public struct UTTagClass: Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let filenameExtension = UTTagClass(rawValue: "public.filename-extension")
    public static let mimeType = UTTagClass(rawValue: "public.mime-type")
}

enum Registry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var declarations: [String: UTType.Declaration] = builtIn

    static func declaration(_ identifier: String) -> UTType.Declaration? {
        lock.lock(); defer { lock.unlock() }
        return declarations[identifier]
    }

    static func declare(_ identifier: String, conformsTo: [String], extensions: [String] = [], isDynamic: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if declarations[identifier] == nil {
            declarations[identifier] = UTType.Declaration(conformsTo: conformsTo, extensions: extensions, isDynamic: isDynamic)
        }
    }

    static func lookup(extension ext: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        // Prefer static (non-dynamic) declarations, deterministically.
        return declarations.filter { !$0.value.isDynamic && $0.value.extensions.contains(ext) }.keys.sorted().first
            ?? declarations.first { $0.value.extensions.contains(ext) }?.key
    }

    static func lookup(mimeType: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return declarations.filter { $0.value.mimeTypes.contains(mimeType) }.keys.sorted().first
    }

    private static func d(_ conforms: [String], _ extensions: [String] = [], _ mime: [String] = []) -> UTType.Declaration {
        UTType.Declaration(conformsTo: conforms, extensions: extensions, mimeTypes: mime)
    }

    static let builtIn: [String: UTType.Declaration] = [
        "public.item": d([]),
        "public.content": d([]),
        "public.composite-content": d(["public.content"]),
        "public.data": d(["public.item"], [], ["application/octet-stream"]),
        "public.directory": d(["public.item"]),
        "public.folder": d(["public.directory"]),
        "public.volume": d(["public.folder"]),
        "com.apple.package": d(["public.directory"]),
        "com.apple.bundle": d(["public.directory"]),
        "com.apple.application": d(["public.item"]),
        "com.apple.application-bundle": d(["com.apple.application", "com.apple.package"], ["app"]),
        "public.executable": d(["public.item"]),
        "public.unix-executable": d(["public.data", "public.executable"]),
        "public.symlink": d(["public.item"]),
        "com.apple.alias-file": d(["public.data"]),
        "public.url": d(["public.data"]),
        "public.file-url": d(["public.url"]),
        "com.apple.bookmark": d(["public.data"]),
        "public.text": d(["public.data", "public.content"]),
        "public.plain-text": d(["public.text"], ["txt", "text"], ["text/plain"]),
        "public.utf8-plain-text": d(["public.plain-text"]),
        "public.utf16-plain-text": d(["public.plain-text"]),
        "public.utf16-external-plain-text": d(["public.plain-text"]),
        "public.utf8-tab-separated-values-text": d(["public.delimited-values-text"], ["tsv"], ["text/tab-separated-values"]),
        "public.delimited-values-text": d(["public.text"]),
        "public.comma-separated-values-text": d(["public.delimited-values-text"], ["csv"], ["text/csv"]),
        "public.tab-separated-values-text": d(["public.delimited-values-text"]),
        "public.rtf": d(["public.text"], ["rtf"], ["text/rtf", "application/rtf"]),
        "public.html": d(["public.text"], ["html", "htm"], ["text/html"]),
        "public.xml": d(["public.text"], ["xml"], ["application/xml", "text/xml"]),
        "public.yaml": d(["public.text"], ["yaml", "yml"], ["application/x-yaml"]),
        "public.json": d(["public.text"], ["json"], ["application/json"]),
        "com.apple.property-list": d(["public.data"], ["plist"]),
        "com.apple.xml-property-list": d(["com.apple.property-list", "public.xml"]),
        "com.apple.binary-property-list": d(["com.apple.property-list"]),
        "public.source-code": d(["public.plain-text"]),
        "public.swift-source": d(["public.source-code"], ["swift"], ["text/x-swift"]),
        "public.c-source": d(["public.source-code"], ["c"], ["text/x-c"]),
        "public.c-header": d(["public.source-code"], ["h"]),
        "public.c-plus-plus-source": d(["public.source-code"], ["cpp", "cc", "cxx"]),
        "public.objective-c-source": d(["public.source-code"], ["m"]),
        "public.script": d(["public.source-code"]),
        "public.shell-script": d(["public.script"], ["sh", "command"], ["application/x-sh"]),
        "public.python-script": d(["public.script"], ["py"], ["text/x-python"]),
        "com.netscape.javascript-source": d(["public.script"], ["js", "mjs"], ["text/javascript"]),
        "public.ruby-script": d(["public.script"], ["rb"]),
        "public.log": d(["public.plain-text"], ["log"]),
        "net.daringfireball.markdown": d(["public.plain-text"], ["md", "markdown"], ["text/markdown"]),
        "public.vcard": d(["public.text"], ["vcf", "vcard"], ["text/vcard"]),
        "public.calendar-event": d(["public.item"]),
        "com.apple.ical.ics": d(["public.data"], ["ics"], ["text/calendar"]),
        "public.email-message": d(["public.data"], ["eml"], ["message/rfc822"]),
        "public.image": d(["public.data", "public.content"]),
        "public.png": d(["public.image"], ["png"], ["image/png"]),
        "public.jpeg": d(["public.image"], ["jpg", "jpeg"], ["image/jpeg"]),
        "com.compuserve.gif": d(["public.image"], ["gif"], ["image/gif"]),
        "public.tiff": d(["public.image"], ["tiff", "tif"], ["image/tiff"]),
        "com.microsoft.bmp": d(["public.image"], ["bmp"], ["image/bmp"]),
        "com.microsoft.ico": d(["public.image"], ["ico"], ["image/x-icon"]),
        "public.heic": d(["public.image"], ["heic"], ["image/heic"]),
        "public.heif": d(["public.image"], ["heif"], ["image/heif"]),
        "org.webmproject.webp": d(["public.image"], ["webp"], ["image/webp"]),
        "public.svg-image": d(["public.image", "public.xml"], ["svg"], ["image/svg+xml"]),
        "public.camera-raw-image": d(["public.image"]),
        "com.adobe.pdf": d(["public.data", "public.composite-content"], ["pdf"], ["application/pdf"]),
        "public.audiovisual-content": d(["public.data", "public.content"]),
        "public.movie": d(["public.audiovisual-content"]),
        "public.video": d(["public.movie"]),
        "public.mpeg-4": d(["public.movie"], ["mp4"], ["video/mp4"]),
        "com.apple.quicktime-movie": d(["public.movie"], ["mov"], ["video/quicktime"]),
        "public.avi": d(["public.movie"], ["avi"], ["video/avi"]),
        "public.audio": d(["public.audiovisual-content"]),
        "public.mp3": d(["public.audio"], ["mp3"], ["audio/mpeg"]),
        "public.mpeg-4-audio": d(["public.audio"], ["m4a"], ["audio/mp4"]),
        "com.microsoft.waveform-audio": d(["public.audio"], ["wav"], ["audio/wav"]),
        "public.archive": d(["public.data"]),
        "public.zip-archive": d(["public.archive"], ["zip"], ["application/zip"]),
        "org.gnu.gnu-zip-archive": d(["public.archive"], ["gz"], ["application/gzip"]),
        "public.tar-archive": d(["public.archive"], ["tar"], ["application/x-tar"]),
        "public.database": d(["public.data"]),
        "public.spreadsheet": d(["public.content"]),
        "public.presentation": d(["public.composite-content"]),
        "public.font": d(["public.data"]),
        "public.truetype-ttf-font": d(["public.font"], ["ttf"], ["font/ttf"]),
        "public.opentype-font": d(["public.font"], ["otf"], ["font/otf"]),
        "public.disk-image": d(["public.data"]),
        "com.apple.disk-image-udif": d(["public.disk-image"], ["dmg"]),
        "public.3d-content": d(["public.content"]),
        "com.pkware.zip-archive": d(["public.zip-archive"]),
        "public.message": d(["public.item"]),
        "public.contact": d(["public.item"]),
        "public.x509-certificate": d(["public.data"], ["cer", "crt", "der"], ["application/x-x509-ca-cert"]),
        "public.mpeg-2-transport-stream": d(["public.movie"], ["ts"]),
    ]
}

extension UTType {
    public static let item = UTType(known: "public.item")
    public static let content = UTType(known: "public.content")
    public static let compositeContent = UTType(known: "public.composite-content")
    public static let data = UTType(known: "public.data")
    public static let directory = UTType(known: "public.directory")
    public static let folder = UTType(known: "public.folder")
    public static let volume = UTType(known: "public.volume")
    public static let package = UTType(known: "com.apple.package")
    public static let bundle = UTType(known: "com.apple.bundle")
    public static let application = UTType(known: "com.apple.application")
    public static let applicationBundle = UTType(known: "com.apple.application-bundle")
    public static let executable = UTType(known: "public.executable")
    public static let unixExecutable = UTType(known: "public.unix-executable")
    public static let symbolicLink = UTType(known: "public.symlink")
    public static let aliasFile = UTType(known: "com.apple.alias-file")
    public static let url = UTType(known: "public.url")
    public static let fileURL = UTType(known: "public.file-url")
    public static let urlBookmarkData = UTType(known: "com.apple.bookmark")
    public static let text = UTType(known: "public.text")
    public static let plainText = UTType(known: "public.plain-text")
    public static let utf8PlainText = UTType(known: "public.utf8-plain-text")
    public static let utf16PlainText = UTType(known: "public.utf16-plain-text")
    public static let utf16ExternalPlainText = UTType(known: "public.utf16-external-plain-text")
    public static let delimitedText = UTType(known: "public.delimited-values-text")
    public static let commaSeparatedText = UTType(known: "public.comma-separated-values-text")
    public static let tabSeparatedText = UTType(known: "public.tab-separated-values-text")
    public static let utf8TabSeparatedText = UTType(known: "public.utf8-tab-separated-values-text")
    public static let rtf = UTType(known: "public.rtf")
    public static let html = UTType(known: "public.html")
    public static let xml = UTType(known: "public.xml")
    public static let yaml = UTType(known: "public.yaml")
    public static let json = UTType(known: "public.json")
    public static let propertyList = UTType(known: "com.apple.property-list")
    public static let xmlPropertyList = UTType(known: "com.apple.xml-property-list")
    public static let binaryPropertyList = UTType(known: "com.apple.binary-property-list")
    public static let sourceCode = UTType(known: "public.source-code")
    public static let swiftSource = UTType(known: "public.swift-source")
    public static let cSource = UTType(known: "public.c-source")
    public static let cHeader = UTType(known: "public.c-header")
    public static let cPlusPlusSource = UTType(known: "public.c-plus-plus-source")
    public static let objectiveCSource = UTType(known: "public.objective-c-source")
    public static let script = UTType(known: "public.script")
    public static let shellScript = UTType(known: "public.shell-script")
    public static let pythonScript = UTType(known: "public.python-script")
    public static let javaScript = UTType(known: "com.netscape.javascript-source")
    public static let rubyScript = UTType(known: "public.ruby-script")
    public static let log = UTType(known: "public.log")
    public static let vCard = UTType(known: "public.vcard")
    public static let calendarEvent = UTType(known: "public.calendar-event")
    public static let ics = UTType(known: "com.apple.ical.ics")
    public static let emailMessage = UTType(known: "public.email-message")
    public static let message = UTType(known: "public.message")
    public static let contact = UTType(known: "public.contact")
    public static let image = UTType(known: "public.image")
    public static let png = UTType(known: "public.png")
    public static let jpeg = UTType(known: "public.jpeg")
    public static let gif = UTType(known: "com.compuserve.gif")
    public static let tiff = UTType(known: "public.tiff")
    public static let bmp = UTType(known: "com.microsoft.bmp")
    public static let ico = UTType(known: "com.microsoft.ico")
    public static let heic = UTType(known: "public.heic")
    public static let heif = UTType(known: "public.heif")
    public static let webP = UTType(known: "org.webmproject.webp")
    public static let svg = UTType(known: "public.svg-image")
    public static let rawImage = UTType(known: "public.camera-raw-image")
    public static let pdf = UTType(known: "com.adobe.pdf")
    public static let audiovisualContent = UTType(known: "public.audiovisual-content")
    public static let movie = UTType(known: "public.movie")
    public static let video = UTType(known: "public.video")
    public static let mpeg4Movie = UTType(known: "public.mpeg-4")
    public static let quickTimeMovie = UTType(known: "com.apple.quicktime-movie")
    public static let avi = UTType(known: "public.avi")
    public static let mpeg2TransportStream = UTType(known: "public.mpeg-2-transport-stream")
    public static let audio = UTType(known: "public.audio")
    public static let mp3 = UTType(known: "public.mp3")
    public static let mpeg4Audio = UTType(known: "public.mpeg-4-audio")
    public static let wav = UTType(known: "com.microsoft.waveform-audio")
    public static let archive = UTType(known: "public.archive")
    public static let zip = UTType(known: "public.zip-archive")
    public static let gzip = UTType(known: "org.gnu.gnu-zip-archive")
    public static let database = UTType(known: "public.database")
    public static let spreadsheet = UTType(known: "public.spreadsheet")
    public static let presentation = UTType(known: "public.presentation")
    public static let font = UTType(known: "public.font")
    public static let diskImage = UTType(known: "public.disk-image")
    public static let threeDContent = UTType(known: "public.3d-content")
    public static let x509Certificate = UTType(known: "public.x509-certificate")
}

extension URL {
    /// `url.appendingPathComponent(_:conformingTo:)` (adds the type's preferred extension).
    public func appendingPathComponent(_ partialName: String, conformingTo contentType: UTType) -> URL {
        let base = appendingPathComponent(partialName)
        guard let ext = contentType.preferredFilenameExtension, base.pathExtension.isEmpty else { return base }
        return base.appendingPathExtension(ext)
    }

    public func appendingPathExtension(for contentType: UTType) -> URL {
        guard let ext = contentType.preferredFilenameExtension else { return self }
        return appendingPathExtension(ext)
    }
}
