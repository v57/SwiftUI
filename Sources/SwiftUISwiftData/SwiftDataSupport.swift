#if canImport(SwiftData)
import Foundation
import Observation
import SwiftData
import _SwiftUICore

// SwiftData's SwiftUI integration (`@Query`, `.modelContainer`, `\.modelContext`) for SwiftUI.
// SwiftData itself (models, containers, contexts) is used as is.

private struct ModelContextKey: EnvironmentKey {
    /// Without `.modelContainer`, SwiftUI uses an empty in-memory store too.
    nonisolated(unsafe) static let defaultValue: ModelContext = {
        do {
            return ModelContext(try ModelContainer(for: Schema([]), configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        } catch {
            fatalError("Failed to create the default model container: \(error)")
        }
    }()
}

extension EnvironmentValues {
    public var modelContext: ModelContext {
        get { self[ModelContextKey.self] }
        set { self[ModelContextKey.self] = newValue }
    }
}

extension View {
    public func modelContainer(_ container: ModelContainer) -> some View {
        environment(\.modelContext, container.mainContext)
    }

    public func modelContainer(for modelTypes: [any PersistentModel.Type], inMemory: Bool = false, isAutosaveEnabled: Bool = true, isUndoEnabled: Bool = false) -> some View {
        let container = Self.makeContainer(modelTypes, inMemory: inMemory)
        container.mainContext.autosaveEnabled = isAutosaveEnabled
        return modelContainer(container)
    }

    public func modelContainer(for modelType: any PersistentModel.Type, inMemory: Bool = false, isAutosaveEnabled: Bool = true, isUndoEnabled: Bool = false) -> some View {
        modelContainer(for: [modelType], inMemory: inMemory, isAutosaveEnabled: isAutosaveEnabled, isUndoEnabled: isUndoEnabled)
    }

    public func modelContext(_ context: ModelContext) -> some View {
        environment(\.modelContext, context)
    }

    fileprivate static func makeContainer(_ types: [any PersistentModel.Type], inMemory: Bool) -> ModelContainer {
        do {
            return try ModelContainer(for: Schema(types), configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}

/// Bumps `revision` whenever a context changes, so views reading a `@Query` re-render.
@Observable @MainActor
final class QueryChangeObserver {
    var revision = 0
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private weak var context: ModelContext?

    func observe(_ context: ModelContext) {
        guard context !== self.context else { return }
        self.context = context
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = [ModelContext.didSave, ModelContext.willSave].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.revision += 1 }
            }
        }
    }

    isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

/// Mirrors SwiftData's `@Query`: fetches models matching a descriptor from the environment's
/// model context and re-fetches when the context changes.
@MainActor @propertyWrapper
public struct Query<Element: PersistentModel, Result>: DynamicProperty {
    @Environment(\.modelContext) private var modelContext
    @State private var observer = QueryChangeObserver()
    private let descriptor: FetchDescriptor<Element>

    public init(_ descriptor: FetchDescriptor<Element>) {
        self.descriptor = descriptor
    }

    public init(filter: Predicate<Element>? = nil, sort: [SortDescriptor<Element>] = []) {
        self.descriptor = FetchDescriptor(predicate: filter, sortBy: sort)
    }

    public init<Value: Comparable>(filter: Predicate<Element>? = nil, sort keyPath: KeyPath<Element, Value> & Sendable, order: SortOrder = .forward) {
        self.descriptor = FetchDescriptor(predicate: filter, sortBy: [SortDescriptor(keyPath, order: order)])
    }

    public init<Value: Comparable>(filter: Predicate<Element>? = nil, sort keyPath: KeyPath<Element, Value?> & Sendable, order: SortOrder = .forward) {
        self.descriptor = FetchDescriptor(predicate: filter, sortBy: [SortDescriptor(keyPath, order: order)])
    }

    /// `Result` is `[Element]` (SwiftData's only result type).
    public var wrappedValue: Result {
        observer.observe(modelContext)
        _ = observer.revision
        let models = (try? modelContext.fetch(descriptor)) ?? []
        return models as! Result
    }
}
#endif
