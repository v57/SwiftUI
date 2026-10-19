import Foundation
import SwiftData
import Testing

@Model final class TestRepository {
    @Attribute(.unique) var path: String = ""
    var name: String = ""
    var addedAt: Date = Date()
    var lastOpenedAt: Date?
    var sortIndex: Int = 0
    var bookmark: Data?
    @Transient var scratch: Int = 0

    init(path: String, name: String, sortIndex: Int = 0) {
        self.path = path
        self.name = name
        self.sortIndex = sortIndex
    }
}

/// The SwiftData stand-in: models through a container's file, fetched with predicates and sorts.
@MainActor
struct SwiftDataTests {
    @Test func modelsSaveFetchAndReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftdata-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema([TestRepository.self])
        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = container.mainContext
            context.insert(TestRepository(path: "/b", name: "b", sortIndex: 2))
            context.insert(TestRepository(path: "/a", name: "a", sortIndex: 1))
            let c = TestRepository(path: "/c", name: "c", sortIndex: 3)
            c.lastOpenedAt = Date(timeIntervalSince1970: 100)
            c.bookmark = Data([1, 2, 3])
            c.scratch = 9
            context.insert(c)
            // The same unique path replaces the earlier model.
            context.insert(TestRepository(path: "/b", name: "b2", sortIndex: 2))
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<TestRepository>()) == 3)
        }
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = container.mainContext
        let sorted = try context.fetch(FetchDescriptor<TestRepository>(sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]))
        #expect(sorted.map(\.name) == ["c", "b2", "a"])
        #expect(sorted[0].lastOpenedAt == Date(timeIntervalSince1970: 100))
        #expect(sorted[0].bookmark == Data([1, 2, 3]))
        #expect(sorted[0].scratch == 0)
        let path = "/a"
        let found = try context.fetch(FetchDescriptor<TestRepository>(predicate: #Predicate { $0.path == path }))
        #expect(found.count == 1 && found[0].modelContext === context)
        context.delete(found[0])
        #expect(found[0].isDeleted)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<TestRepository>()).map(\.path).sorted() == ["/b", "/c"])
    }

    @Test func modelsAreObservable() throws {
        let model = TestRepository(path: "/x", name: "x")
        final class Flag: @unchecked Sendable { var value = false }
        let changed = Flag()
        withObservationTracking { _ = model.name } onChange: { changed.value = true }
        model.name = "y"
        #expect(changed.value)
    }
}
