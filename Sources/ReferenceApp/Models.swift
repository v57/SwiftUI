import SwiftUI
import Observation

// MARK: - Update counters (shown in the app, mirrors Parity/Scenarios Probe)

@MainActor @Observable
final class UpdateLog {
    static let shared = UpdateLog()
    private(set) var counts: [String: Int] = [:]
    @ObservationIgnored private var pending: [String: Int] = [:]
    @ObservationIgnored private var flushScheduled = false

    /// Called from `body`; publishing is deferred so counting never invalidates views itself.
    func hit(_ name: String) {
        pending[name, default: 0] += 1
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [self] in
            for (key, value) in pending { counts[key, default: 0] += value }
            pending.removeAll()
            flushScheduled = false
        }
    }

    func reset() { counts.removeAll() }
}

struct UpdateCounterPanel: View {
    private let log = UpdateLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("body evaluations").font(.caption).bold()
                Spacer()
                Button("Reset") { log.reset() }.controlSize(.small)
            }
            ForEach(log.counts.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                HStack {
                    Text(entry.key).font(.caption.monospaced())
                    Spacer()
                    Text("\(entry.value)").font(.caption.monospacedDigit())
                }
            }
        }
        .padding(10)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
    }
}

// MARK: - Library (Observable)

@Observable
final class Library {
    var books: [Book]
    var favorites: Set<Book.ID> = []
    var searchText = ""

    init(books: [Book]) { self.books = books }

    var filtered: [Book] {
        guard !searchText.isEmpty else { return books }
        return books.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.author.localizedCaseInsensitiveContains(searchText) }
    }

    func toggleFavorite(_ book: Book) {
        if favorites.contains(book.id) { favorites.remove(book.id) } else { favorites.insert(book.id) }
    }

    static func sample() -> Library {
        Library(books: [
            Book(title: "The Swift Programming Language", author: "Apple", year: 2014, genre: .reference, rating: 5),
            Book(title: "Structure and Interpretation of Computer Programs", author: "Abelson & Sussman", year: 1985, genre: .reference, rating: 5),
            Book(title: "Dune", author: "Frank Herbert", year: 1965, genre: .fiction, rating: 4),
            Book(title: "Gödel, Escher, Bach", author: "Douglas Hofstadter", year: 1979, genre: .science, rating: 5),
            Book(title: "The Pragmatic Programmer", author: "Hunt & Thomas", year: 1999, genre: .reference, rating: 4),
            Book(title: "Neuromancer", author: "William Gibson", year: 1984, genre: .fiction, rating: 4),
            Book(title: "A Brief History of Time", author: "Stephen Hawking", year: 1988, genre: .science, rating: 4),
            Book(title: "Design Patterns", author: "Gang of Four", year: 1994, genre: .reference, rating: 3),
        ])
    }
}

struct Book: Identifiable, Hashable {
    enum Genre: String, CaseIterable, Identifiable {
        case fiction, science, reference
        var id: String { rawValue }
    }

    let id = UUID()
    var title: String
    var author: String
    var year: Int
    var genre: Genre
    var rating: Int
    var notes = ""
}

// MARK: - Settings (ObservableObject)

final class AppSettings: ObservableObject {
    @Published var showUpdateCounters = true
    @Published var appearance: Appearance = .system
    @Published var accent: Color = .blue
    @Published var compactRows = false
    @Published var username = "guest"

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Show update counters", isOn: $settings.showUpdateCounters)
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            ColorPicker("Accent", selection: $settings.accent)
            Toggle("Compact rows", isOn: $settings.compactRows)
            TextField("User name", text: $settings.username)
        }
        .padding()
    }
}

// MARK: - Environment keys

struct CardStyle: Equatable {
    var cornerRadius: CGFloat = 12
    var padding: CGFloat = 12
}

private struct CardStyleKey: EnvironmentKey {
    static let defaultValue = CardStyle()
}

extension EnvironmentValues {
    var cardStyle: CardStyle {
        get { self[CardStyleKey.self] }
        set { self[CardStyleKey.self] = newValue }
    }
}
