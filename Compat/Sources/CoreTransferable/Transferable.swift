// CoreTransferable's API on non-Apple platforms: `Transferable` types describe how they export
// to / import from data or files of given content types. Representations resolve to a flat
// list of type-erased entries (`_TransferEntry`) that item providers (SwiftUIPortability)
// and apps use.
import Foundation
import UniformTypeIdentifiers

public protocol Transferable {
    associatedtype Representation: TransferRepresentation
    @TransferRepresentationBuilder<Self> static var transferRepresentation: Representation { get }
}

public protocol TransferRepresentation<Item>: Sendable {
    associatedtype Item: Transferable
    associatedtype Body: TransferRepresentation
    @TransferRepresentationBuilder<Item> var body: Body { get }
}

/// Representations that are entries themselves (Body == Never).
public protocol _PrimitiveTransferRepresentation: TransferRepresentation where Body == Never {
    func _entries() -> [_TransferEntry<Item>]
}

extension _PrimitiveTransferRepresentation {
    public var body: Never { fatalError("primitive transfer representation") }
}

extension Never: TransferRepresentation, Transferable {
    public typealias Item = Never
    public typealias Body = Never
    public var body: Never { fatalError() }
    public static var transferRepresentation: Never { fatalError() }
}

/// One way to move an item: a content type and an exporter and/or importer.
public struct _TransferEntry<Item>: @unchecked Sendable {
    public var contentType: UTType
    public var exportData: ((Item) async throws -> Data)?
    public var exportFile: ((Item) async throws -> SentTransferredFile)?
    public var importData: ((Data) async throws -> Item)?
    public var importFile: ((ReceivedTransferredFile) async throws -> Item)?
    public var suggestedFileName: ((Item) -> String?)?
    public var visibility = TransferRepresentationVisibility.all
    public var isExportable: (Item) -> Bool = { _ in true }

    func mapped<Other>(export: @escaping (Other) async throws -> Item, import convert: @escaping (Item) async throws -> Other) -> _TransferEntry<Other> {
        var entry = _TransferEntry<Other>(contentType: contentType)
        if let exportData { entry.exportData = { try await exportData(try await export($0)) } }
        if let exportFile { entry.exportFile = { try await exportFile(try await export($0)) } }
        if let importData { entry.importData = { try await convert(try await importData($0)) } }
        if let importFile { entry.importFile = { try await convert(try await importFile($0)) } }
        entry.visibility = visibility
        return entry
    }
}

extension TransferRepresentation {
    /// The flattened entries of the representation (in declaration order).
    public func _resolvedEntries() -> [_TransferEntry<Item>] {
        if let primitive = self as? any _PrimitiveTransferRepresentation {
            func open<P: _PrimitiveTransferRepresentation>(_ p: P) -> [Any] { p._entries() }
            return open(primitive).compactMap { $0 as? _TransferEntry<Item> }
        }
        return body._resolvedEntries().compactMap { $0 as Any as? _TransferEntry<Item> }
    }
}

extension Transferable {
    /// All transfer entries of the type.
    public static var _transferEntries: [_TransferEntry<Self>] {
        transferRepresentation._resolvedEntries().compactMap { $0 as Any as? _TransferEntry<Self> }
    }

    public static var _exportedContentTypes: [UTType] { _transferEntries.filter { $0.exportData != nil || $0.exportFile != nil }.map(\.contentType) }
    public static var _importedContentTypes: [UTType] { _transferEntries.filter { $0.importData != nil || $0.importFile != nil }.map(\.contentType) }

    /// The item's data in the first exportable representation (files are read).
    public func _exportedData() async throws -> (UTType, Data)? {
        for entry in Self._transferEntries where entry.isExportable(self) {
            if let exportData = entry.exportData { return (entry.contentType, try await exportData(self)) }
            if let exportFile = entry.exportFile { return (entry.contentType, try Data(contentsOf: try await exportFile(self).file)) }
        }
        return nil
    }

    /// An item from data of a content type.
    public static func _imported(from data: Data, contentType: UTType?) async throws -> Self? {
        for entry in _transferEntries where contentType.map({ $0.conforms(to: entry.contentType) || entry.contentType.conforms(to: $0) }) ?? true {
            if let importData = entry.importData { return try await importData(data) }
            if let importFile = entry.importFile {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try data.write(to: url)
                return try await importFile(ReceivedTransferredFile(file: url, isOriginalFile: false))
            }
        }
        return nil
    }
}

public enum TransferRepresentationVisibility: Sendable { case all, team, group, ownProcess }

// MARK: - Builder

@resultBuilder
public struct TransferRepresentationBuilder<Item: Transferable> {
    public static func buildExpression<R: TransferRepresentation>(_ content: R) -> R where R.Item == Item { content }
    public static func buildBlock<R: TransferRepresentation>(_ content: R) -> R where R.Item == Item { content }
    public static func buildBlock<each R: TransferRepresentation>(_ content: repeat each R) -> _TupleTransferRepresentation<Item> {
        var entries: [_TransferEntry<Item>] = []
        for representation in repeat each content {
            entries += representation._resolvedEntries().compactMap { $0 as Any as? _TransferEntry<Item> }
        }
        return _TupleTransferRepresentation(entries: entries)
    }
}

public struct _TupleTransferRepresentation<Item: Transferable>: _PrimitiveTransferRepresentation, @unchecked Sendable {
    let entries: [_TransferEntry<Item>]
    public func _entries() -> [_TransferEntry<Item>] { entries }
}

// MARK: - Representations

public struct SentTransferredFile: Sendable {
    public let file: URL
    public let allowAccessingOriginalFile: Bool
    public init(_ file: URL, allowAccessingOriginalFile: Bool = false) {
        self.file = file
        self.allowAccessingOriginalFile = allowAccessingOriginalFile
    }
}

public struct ReceivedTransferredFile: Sendable {
    public let file: URL
    public let isOriginalFile: Bool
    public init(file: URL, isOriginalFile: Bool) {
        self.file = file
        self.isOriginalFile = isOriginalFile
    }
}

public struct DataRepresentation<Item: Transferable>: _PrimitiveTransferRepresentation, @unchecked Sendable {
    var entry: _TransferEntry<Item>

    public init(contentType: UTType, exporting: @escaping @Sendable (Item) async throws -> Data, importing: @escaping @Sendable (Data) async throws -> Item) {
        entry = _TransferEntry(contentType: contentType, exportData: exporting, importData: importing)
    }
    public init(exportedContentType contentType: UTType, exporting: @escaping @Sendable (Item) async throws -> Data) {
        entry = _TransferEntry(contentType: contentType, exportData: exporting)
    }
    public init(importedContentType contentType: UTType, importing: @escaping @Sendable (Data) async throws -> Item) {
        entry = _TransferEntry(contentType: contentType, importData: importing)
    }
    public func _entries() -> [_TransferEntry<Item>] { [entry] }
}

public struct FileRepresentation<Item: Transferable>: _PrimitiveTransferRepresentation, @unchecked Sendable {
    var entry: _TransferEntry<Item>

    public init(contentType: UTType, shouldAttemptToOpenInPlace: Bool = false, exporting: @escaping @Sendable (Item) async throws -> SentTransferredFile, importing: @escaping @Sendable (ReceivedTransferredFile) async throws -> Item) {
        entry = _TransferEntry(contentType: contentType, exportFile: exporting, importFile: importing)
    }
    public init(exportedContentType contentType: UTType, shouldAllowToOpenInPlace: Bool = false, exporting: @escaping @Sendable (Item) async throws -> SentTransferredFile) {
        entry = _TransferEntry(contentType: contentType, exportFile: exporting)
    }
    public init(importedContentType contentType: UTType, shouldAttemptToOpenInPlace: Bool = false, importing: @escaping @Sendable (ReceivedTransferredFile) async throws -> Item) {
        entry = _TransferEntry(contentType: contentType, importFile: importing)
    }
    public func _entries() -> [_TransferEntry<Item>] { [entry] }
}

public struct CodableRepresentation<Item: Transferable & Codable, Encoder: TopLevelEncoderCompat, Decoder: TopLevelDecoderCompat>: _PrimitiveTransferRepresentation, @unchecked Sendable {
    var entry: _TransferEntry<Item>

    public init(for itemType: Item.Type = Item.self, contentType: UTType, encoder: Encoder, decoder: Decoder) {
        let encoder = UncheckedBox(encoder), decoder = UncheckedBox(decoder)
        entry = _TransferEntry(contentType: contentType, exportData: { try encoder.value.encode($0) }, importData: { try decoder.value.decode(Item.self, from: $0) })
    }
    public func _entries() -> [_TransferEntry<Item>] { [entry] }
}

extension CodableRepresentation where Encoder == JSONEncoder, Decoder == JSONDecoder {
    public init(for itemType: Item.Type = Item.self, contentType: UTType) {
        self.init(for: itemType, contentType: contentType, encoder: JSONEncoder(), decoder: JSONDecoder())
    }
}

/// Encoders/decoders producing Data (Combine's TopLevelEncoder isn't available here).
public protocol TopLevelEncoderCompat { func encode<T: Encodable>(_ value: T) throws -> Data }
public protocol TopLevelDecoderCompat { func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T }
extension JSONEncoder: TopLevelEncoderCompat {}
extension JSONDecoder: TopLevelDecoderCompat {}
extension PropertyListEncoder: TopLevelEncoderCompat {}
extension PropertyListDecoder: TopLevelDecoderCompat {}

struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }

public struct ProxyRepresentation<Item: Transferable, ProxyRepresentation: Transferable>: _PrimitiveTransferRepresentation, @unchecked Sendable {
    let export: ((Item) async throws -> ProxyRepresentation)?
    let importer: ((ProxyRepresentation) async throws -> Item)?

    public init(exporting: @escaping @Sendable (Item) throws -> ProxyRepresentation, importing: @escaping @Sendable (ProxyRepresentation) throws -> Item) {
        export = { try exporting($0) }
        importer = { try importing($0) }
    }
    public init(exporting: @escaping @Sendable (Item) throws -> ProxyRepresentation) {
        export = { try exporting($0) }
        importer = nil
    }
    public init(importing: @escaping @Sendable (ProxyRepresentation) throws -> Item) {
        export = nil
        importer = { try importing($0) }
    }

    public func _entries() -> [_TransferEntry<Item>] {
        ProxyRepresentation._transferEntries.map { proxyEntry in
            var entry = proxyEntry.mapped(export: { (item: Item) in
                guard let export else { throw CocoaError(.featureUnsupported) }
                return try await export(item)
            }, import: { (proxy: ProxyRepresentation) in
                guard let importer else { throw CocoaError(.featureUnsupported) }
                return try await importer(proxy)
            })
            if export == nil { entry.exportData = nil; entry.exportFile = nil }
            if importer == nil { entry.importData = nil; entry.importFile = nil }
            return entry
        }
    }
}

// MARK: - Modifiers

public struct _ModifiedTransferRepresentation<Base: TransferRepresentation>: _PrimitiveTransferRepresentation, @unchecked Sendable {
    let base: Base
    let modify: (inout _TransferEntry<Base.Item>) -> Void
    public typealias Item = Base.Item
    public func _entries() -> [_TransferEntry<Base.Item>] {
        base._resolvedEntries().map { entry in
            var entry = entry
            modify(&entry)
            return entry
        }
    }
}

extension TransferRepresentation {
    public func suggestedFileName(_ fileName: String) -> _ModifiedTransferRepresentation<Self> {
        _ModifiedTransferRepresentation(base: self) { $0.suggestedFileName = { _ in fileName } }
    }
    public func suggestedFileName(_ fileName: @escaping (Item) -> String?) -> _ModifiedTransferRepresentation<Self> {
        _ModifiedTransferRepresentation(base: self) { $0.suggestedFileName = fileName }
    }
    public func visibility(_ visibility: TransferRepresentationVisibility) -> _ModifiedTransferRepresentation<Self> {
        _ModifiedTransferRepresentation(base: self) { $0.visibility = visibility }
    }
    public func exportingCondition(_ condition: @escaping (Item) -> Bool) -> _ModifiedTransferRepresentation<Self> {
        _ModifiedTransferRepresentation(base: self) { $0.isExportable = condition }
    }
}

// MARK: - Standard types

extension String: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<String>(contentType: .utf8PlainText, exporting: { Data($0.utf8) }, importing: { String(decoding: $0, as: UTF8.self) })
    }
}

extension Data: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<Data>(contentType: .data, exporting: { $0 }, importing: { $0 })
    }
}

extension URL: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<URL>(contentType: .url, exporting: { $0.dataRepresentation }, importing: { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil) else { throw CocoaError(.fileReadCorruptFile) }
            return url
        })
    }
}

extension AttributedString: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<AttributedString>(contentType: .utf8PlainText, exporting: { Data(String($0.characters).utf8) }, importing: { AttributedString(String(decoding: $0, as: UTF8.self)) })
    }
}
