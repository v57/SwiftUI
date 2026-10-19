// SwiftData stand-in (Linux, Windows, Android): `@Model` classes, containers, contexts, fetches with predicates
// and sort descriptors, and SwiftUI's `@Query` (SwiftUISwiftData). Models keep their stored properties in rows a
// container writes to a JSON file (the store's URL), loaded whole at open: meant for the small stores apps keep (a
// sidebar's folders, saved repositories), not for large data sets. Relationships aren't supported.
import Foundation
@_exported import Observation

// MARK: - Macros

@attached(member, names: named(_$observationRegistrar), named(access), named(withMutation), named(shouldNotifyObservers),
          named(_$backing), named(_$entityName), named(_$uniqueKeys), named(_$encode), named(init))
@attached(memberAttribute)
@attached(extension, conformances: Observable, PersistentModel)
public macro Model() = #externalMacro(module: "SwiftUIMacros", type: "ModelMacro")

/// A stored property's options (`.unique` makes an insert replace the model with the same value).
@attached(peer)
public macro Attribute(_ options: Schema.Attribute.Option..., originalName: String? = nil, hashModifier: String? = nil) =
    #externalMacro(module: "SwiftUIMacros", type: "ModelMarkerMacro")

/// Not persisted: the value lives as long as the object.
@attached(peer)
public macro Transient() = #externalMacro(module: "SwiftUIMacros", type: "ModelMarkerMacro")

/// Relationships aren't supported by this store; the marker is accepted.
@attached(peer)
public macro Relationship(_ options: Schema.Relationship.Option..., deleteRule: Schema.Relationship.DeleteRule = .nullify, minimumModelCount: Int? = 0,
                          maximumModelCount: Int? = 0, originalName: String? = nil, inverse: AnyKeyPath? = nil, hashModifier: String? = nil) =
    #externalMacro(module: "SwiftUIMacros", type: "ModelMarkerMacro")

// MARK: - Models

/// A model class (`@Model`).
public protocol PersistentModel: AnyObject, Observable, Hashable, Identifiable {
    /// Where the model is stored: its context and identifier.
    var _$backing: _ModelBacking { get }
    static var _$entityName: String { get }
    static var _$uniqueKeys: [String] { get }
    @MainActor func _$encode() -> _ModelRow
    @MainActor init(_$row: _ModelRow)
}

extension PersistentModel {
    public var persistentModelID: PersistentIdentifier { _$backing.identifier(entity: Self._$entityName) }
    public var modelContext: ModelContext? { _$backing.context }
    public var isDeleted: Bool { _$backing.isDeleted }
    public var hasChanges: Bool { _$backing.hasChanges }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension PersistentModel {
    /// A model without an `id` property of its own is identified by its persistent identifier.
    public var id: PersistentIdentifier { persistentModelID }
}

/// A model's identity in its store.
public struct PersistentIdentifier: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let entityName: String
    public let uuid: UUID
    public var storeIdentifier: String? { nil }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.entityName, lhs.uuid.uuidString) < (rhs.entityName, rhs.uuid.uuidString) }
    public var description: String { "\(entityName)/\(uuid.uuidString)" }
}

/// Bookkeeping `@Model` adds to every model.
public final class _ModelBacking: @unchecked Sendable {
    private let lock = NSLock()
    var uuid = UUID()
    weak var context: ModelContext?
    var isDeleted = false
    var hasChanges = false

    public init() {}

    func identifier(entity: String) -> PersistentIdentifier { PersistentIdentifier(entityName: entity, uuid: uuid) }

    /// A stored property is about to change.
    public func didChange() {
        lock.lock()
        hasChanges = true
        let context = context
        lock.unlock()
        context?._modelDidChange()
    }
}

/// A model's stored properties, each as JSON.
public struct _ModelRow: Codable, Sendable {
    var values: [String: String] = [:]

    public init() {}

    public mutating func set<T: Encodable>(_ key: String, _ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(value) { values[key] = String(decoding: data, as: UTF8.self) }
    }

    public func get<T: Decodable>(_ key: String) -> T? {
        guard let text = values[key] else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    public func require<T: Decodable>(_ key: String) -> T {
        guard let value: T = get(key) else { fatalError("SwiftData: the store has no value for \(key)") }
        return value
    }
}

// MARK: - Schema and configuration

public final class Schema: @unchecked Sendable {
    public struct Version: Hashable, Sendable {
        public let major: Int, minor: Int, patch: Int
        public init(_ major: Int, _ minor: Int, _ patch: Int) { (self.major, self.minor, self.patch) = (major, minor, patch) }
    }

    public enum Attribute {
        public struct Option: Hashable, Sendable {
            let name: String
            public static let unique = Option(name: "unique")
            public static let externalStorage = Option(name: "externalStorage")
            public static let preserveValueOnDeletion = Option(name: "preserveValueOnDeletion")
            public static let spotlight = Option(name: "spotlight")
            public static let allowsCloudEncryption = Option(name: "allowsCloudEncryption")
            public static let ephemeral = Option(name: "ephemeral")
            public static func transformable(by name: String) -> Option { Option(name: "transformable") }
        }
    }

    public enum Relationship {
        public struct Option: Hashable, Sendable {
            public static let unique = Option()
        }
        public enum DeleteRule: Hashable, Sendable { case noAction, nullify, cascade, deny }
    }

    public let types: [any PersistentModel.Type]
    public let version: Version

    public init(_ types: [any PersistentModel.Type], version: Version = Version(1, 0, 0)) {
        self.types = types
        self.version = version
    }

    public convenience init(_ types: any PersistentModel.Type..., version: Version = Version(1, 0, 0)) {
        self.init(types, version: version)
    }
}

public struct ModelConfiguration: Hashable, Sendable {
    public enum CloudKitDatabase: Hashable, Sendable {
        case automatic, none
        case `private`(String)
    }

    public enum GroupContainer: Hashable, Sendable {
        case automatic, none
        case identifier(String)
    }

    public let name: String
    public let url: URL
    public let isStoredInMemoryOnly: Bool
    public let allowsSave: Bool
    public let cloudKitDatabase: CloudKitDatabase

    public init(
        _ name: String? = nil, schema: Schema? = nil, isStoredInMemoryOnly: Bool = false, allowsSave: Bool = true,
        groupContainer: GroupContainer = .automatic, cloudKitDatabase: CloudKitDatabase = .automatic
    ) {
        self.name = name ?? "default"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
        url = folder.appendingPathComponent("\(self.name).store")
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
        self.cloudKitDatabase = cloudKitDatabase
    }

    public init(_ name: String? = nil, schema: Schema? = nil, url: URL, allowsSave: Bool = true, cloudKitDatabase: CloudKitDatabase = .automatic) {
        self.name = name ?? url.deletingPathExtension().lastPathComponent
        self.url = url
        isStoredInMemoryOnly = false
        self.allowsSave = allowsSave
        self.cloudKitDatabase = cloudKitDatabase
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url && lhs.isStoredInMemoryOnly == rhs.isStoredInMemoryOnly }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

// MARK: - Container

/// The store: every model's row by entity and id, saved as one JSON file.
final class ModelStore: @unchecked Sendable {
    struct File: Codable {
        var version = 1
        var entities: [String: [String: _ModelRow]] = [:]
    }

    let configuration: ModelConfiguration
    var file = File()

    init(configuration: ModelConfiguration) throws {
        self.configuration = configuration
        guard !configuration.isStoredInMemoryOnly, FileManager.default.fileExists(atPath: configuration.url.path) else { return }
        file = try JSONDecoder().decode(File.self, from: Data(contentsOf: configuration.url))
    }

    func write() throws {
        guard !configuration.isStoredInMemoryOnly, configuration.allowsSave else { return }
        try FileManager.default.createDirectory(at: configuration.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(file).write(to: configuration.url, options: .atomic)
    }
}

public final class ModelContainer: @unchecked Sendable {
    public let schema: Schema
    public let configurations: [ModelConfiguration]
    let store: ModelStore
    private var _mainContext: ModelContext?

    public init(for schema: Schema, configurations: [ModelConfiguration]) throws {
        self.schema = schema
        self.configurations = configurations.isEmpty ? [ModelConfiguration()] : configurations
        store = try ModelStore(configuration: self.configurations[0])
    }

    public convenience init(for schema: Schema, configurations: ModelConfiguration...) throws {
        try self.init(for: schema, configurations: configurations)
    }

    public convenience init(for forTypes: any PersistentModel.Type..., configurations: ModelConfiguration...) throws {
        try self.init(for: Schema(forTypes), configurations: configurations)
    }

    @MainActor public var mainContext: ModelContext {
        if let context = _mainContext { return context }
        let context = ModelContext(self)
        _mainContext = context
        return context
    }

    @MainActor public func deleteAllData() {
        store.file.entities = [:]
        try? store.write()
    }
}

// MARK: - Context

public struct FetchDescriptor<T: PersistentModel>: @unchecked Sendable {
    public var predicate: Predicate<T>?
    public var sortBy: [SortDescriptor<T>]
    public var fetchLimit: Int?
    public var fetchOffset: Int?
    public var includePendingChanges = true
    public var propertiesToFetch: [PartialKeyPath<T>] = []
    public var relationshipKeyPathsForPrefetching: [PartialKeyPath<T>] = []

    public init(predicate: Predicate<T>? = nil, sortBy: [SortDescriptor<T>] = []) {
        self.predicate = predicate
        self.sortBy = sortBy
    }
}

/// Inserts, deletes, fetches and saves models of a container.
@MainActor
public final class ModelContext {
    public static let willSave = Notification.Name("SwiftData.ModelContext.willSave")
    public static let didSave = Notification.Name("SwiftData.ModelContext.didSave")

    public let container: ModelContainer
    /// Saves on its own shortly after a change (the main context's default).
    public var autosaveEnabled = true
    /// Models this context made or fetched, by entity and id.
    private var registered: [String: [UUID: any PersistentModel]] = [:]
    private var deleted: [String: Set<UUID>] = [:]
    private var autosaveScheduled = false
    public private(set) var hasChanges = false

    public nonisolated init(_ container: ModelContainer) {
        self.container = container
    }

    public func insert<T: PersistentModel>(_ model: T) {
        let entity = T._$entityName
        // A unique attribute's value already stored replaces the model that has it.
        if !T._$uniqueKeys.isEmpty {
            let row = model._$encode()
            for existing in (try? fetch(FetchDescriptor<T>())) ?? [] where existing !== model {
                let other = existing._$encode()
                if T._$uniqueKeys.contains(where: { row.values[$0] != nil && row.values[$0] == other.values[$0] }) {
                    model._$backing.uuid = existing._$backing.uuid
                    existing._$backing.isDeleted = true
                    existing._$backing.context = nil
                }
            }
        }
        model._$backing.context = self
        model._$backing.isDeleted = false
        registered[entity, default: [:]][model._$backing.uuid] = model
        deleted[entity]?.remove(model._$backing.uuid)
        _modelDidChange()
    }

    public func delete<T: PersistentModel>(_ model: T) {
        let entity = T._$entityName
        model._$backing.isDeleted = true
        registered[entity]?[model._$backing.uuid] = nil
        deleted[entity, default: []].insert(model._$backing.uuid)
        _modelDidChange()
    }

    public func delete<T: PersistentModel>(model: T.Type, where predicate: Predicate<T>? = nil, includeSubclasses: Bool = true) throws {
        for item in try fetch(FetchDescriptor<T>(predicate: predicate)) { delete(item) }
    }

    public func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        let entity = T._$entityName
        var models: [T] = []
        var seen = Set<UUID>()
        for (key, row) in container.store.file.entities[entity] ?? [:] {
            guard let uuid = UUID(uuidString: key), !(deleted[entity]?.contains(uuid) ?? false) else { continue }
            seen.insert(uuid)
            if let model = registered[entity]?[uuid] as? T {
                models.append(model)
            } else {
                let model = T(_$row: row)
                model._$backing.uuid = uuid
                model._$backing.context = self
                registered[entity, default: [:]][uuid] = model
                models.append(model)
            }
        }
        // Inserted and not saved yet.
        for (uuid, model) in registered[entity] ?? [:] where !seen.contains(uuid) {
            if let model = model as? T { models.append(model) }
        }
        if let predicate = descriptor.predicate { models = try models.filter { try predicate.evaluate($0) } }
        if !descriptor.sortBy.isEmpty { models.sort(using: descriptor.sortBy) }
        if let offset = descriptor.fetchOffset { models = Array(models.dropFirst(offset)) }
        if let limit = descriptor.fetchLimit { models = Array(models.prefix(limit)) }
        return models
    }

    public func fetchCount<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> Int {
        try fetch(descriptor).count
    }

    public func fetchIdentifiers<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [PersistentIdentifier] {
        try fetch(descriptor).map(\.persistentModelID)
    }

    public func model(for identifier: PersistentIdentifier) -> any PersistentModel {
        guard let model = registered[identifier.entityName]?[identifier.uuid] else {
            fatalError("SwiftData: no model \(identifier) in this context")
        }
        return model
    }

    public func registeredModel<T: PersistentModel>(for identifier: PersistentIdentifier) -> T? {
        registered[identifier.entityName]?[identifier.uuid] as? T
    }

    /// Writes every model this context has into the store and saves the file.
    public func save() throws {
        NotificationCenter.default.post(name: Self.willSave, object: self)
        var entities = container.store.file.entities
        for (entity, ids) in deleted {
            for uuid in ids { entities[entity]?[uuid.uuidString] = nil }
        }
        for (entity, models) in registered {
            for (uuid, model) in models where !model._$backing.isDeleted {
                entities[entity, default: [:]][uuid.uuidString] = model._$encode()
                model._$backing.hasChanges = false
            }
        }
        container.store.file.entities = entities
        deleted = [:]
        hasChanges = false
        try container.store.write()
        NotificationCenter.default.post(name: Self.didSave, object: self)
    }

    /// Drops changes not saved yet.
    public func rollback() {
        registered = [:]
        deleted = [:]
        hasChanges = false
    }

    public func transaction(block: () throws -> Void) throws {
        try block()
        try save()
    }

    public func processPendingChanges() {}

    nonisolated func _modelDidChange() {
        Task { @MainActor in self.noteChange() }
    }

    private func noteChange() {
        hasChanges = true
        guard autosaveEnabled, !autosaveScheduled else { return }
        autosaveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.autosaveScheduled = false
            if self.hasChanges { try? self.save() }
        }
    }
}
