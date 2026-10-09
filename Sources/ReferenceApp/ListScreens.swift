#if SWIFTUI2
import SwiftUI2
#else
import SwiftUI
#endif

// MARK: - Lists & identity

struct IdentityItem: Identifiable, Equatable {
    let id: Int
    var title: String
}

struct IdentityScreen: View {
    @State private var items = (1...6).map { IdentityItem(id: $0, title: "Item \($0)") }
    @State private var nextID = 7
    @State private var resetToken = 0
    @State private var useAnyViewText = true

    var body: some View {
        DemoPage(title: "Lists & Identity", summary: "Explicit identity (ForEach ids, .id) and structural identity (if/else, AnyView) decide when state survives.") {
            DemoSection(title: "ForEach with per-row state") {
                HStack {
                    Button("Insert at top") {
                        items.insert(IdentityItem(id: nextID, title: "Item \(nextID)"), at: 0)
                        nextID += 1
                    }
                    Button("Remove first") { if !items.isEmpty { items.removeFirst() } }
                    Button("Shuffle") { items.shuffle() }
                    Button("Rename all") { items = items.map { IdentityItem(id: $0.id, title: $0.title + "′") } }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        IdentityRow(item: item)
                    }
                }
            }
            DemoSection(title: "Structural identity") {
                Toggle("Show text (AnyView)", isOn: $useAnyViewText)
                (useAnyViewText ? AnyView(TapCounter(label: "AnyView text branch")) : AnyView(TapCounter(label: "AnyView other branch").padding(4)))
                if useAnyViewText {
                    TapCounter(label: "if branch")
                } else {
                    TapCounter(label: "else branch")
                }
            }
            DemoSection(title: ".id() resets state") {
                TapCounter(label: "Reset by id").id(resetToken)
                Button("Change id") { resetToken += 1 }
            }
        }
    }
}

struct IdentityRow: View {
    let item: IdentityItem
    @State private var taps = 0

    var body: some View {
        let _ = UpdateLog.shared.hit("IdentityRow")
        HStack {
            Text(item.title)
            Spacer()
            Text("taps: \(taps)").foregroundStyle(.secondary)
            Button("Tap") { taps += 1 }
        }
        .padding(.vertical, 2)
    }
}

struct TapCounter: View {
    let label: String
    @State private var taps = 0
    var body: some View {
        Button("\(label): \(taps)") { taps += 1 }
    }
}

// MARK: - Library: List, navigation, search, swipe

struct LibraryScreen: View {
    @Environment(Library.self) private var library
    @EnvironmentObject private var settings: AppSettings
    @State private var path: [Book] = []
    @State private var genre: Book.Genre?

    var body: some View {
        @Bindable var library = library
        NavigationStack(path: $path) {
            List {
                Section("Genre") {
                    Picker("Genre", selection: $genre) {
                        Text("All").tag(Book.Genre?.none)
                        ForEach(Book.Genre.allCases) { Text($0.rawValue.capitalized).tag(Book.Genre?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Books") {
                    ForEach(library.filtered.filter { genre == nil || $0.genre == genre }) { book in
                        NavigationLink(value: book) {
                            BookRow(book: book, isFavorite: library.favorites.contains(book.id), compact: settings.compactRows)
                        }
                        .contextMenu {
                            Button(library.favorites.contains(book.id) ? "Unfavorite" : "Favorite") { library.toggleFavorite(book) }
                        }
                    }
                    .onDelete { offsets in library.books.remove(atOffsets: offsets) }
                    .onMove { from, to in library.books.move(fromOffsets: from, toOffset: to) }
                }
            }
            .searchable(text: $library.searchText)
            .navigationDestination(for: Book.self) { book in
                BookDetail(bookID: book.id)
            }
        }
    }
}

struct BookRow: View {
    let book: Book
    let isFavorite: Bool
    let compact: Bool

    var body: some View {
        let _ = UpdateLog.shared.hit("BookRow")
        HStack {
            VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                Text(book.title).font(.headline).lineLimit(1)
                if !compact {
                    Text("\(book.author) · \(String(book.year))").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            RatingView(rating: book.rating)
        }
        .padding(.vertical, compact ? 0 : 4)
    }
}

struct RatingView: View {
    let rating: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5) { index in
                Image(systemName: index < rating ? "star.fill" : "star")
                    .foregroundStyle(index < rating ? .yellow : .secondary)
                    .font(.caption)
            }
        }
    }
}

struct BookDetail: View {
    @Environment(Library.self) private var library
    let bookID: Book.ID

    var body: some View {
        if let index = library.books.firstIndex(where: { $0.id == bookID }) {
            @Bindable var library = library
            Form {
                TextField("Title", text: $library.books[index].title)
                TextField("Author", text: $library.books[index].author)
                Stepper("Year: \(String(library.books[index].year))", value: $library.books[index].year)
                Picker("Rating", selection: $library.books[index].rating) {
                    ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
                }
                TextEditor(text: $library.books[index].notes).frame(minHeight: 100)
                Button(library.favorites.contains(bookID) ? "Remove from favorites" : "Add to favorites") {
                    library.toggleFavorite(library.books[index])
                }
            }
            .padding()
            .navigationTitle(library.books[index].title)
        } else {
            ContentUnavailableView("Book removed", systemImage: "book.closed")
        }
    }
}

// MARK: - Performance lab

@Observable
final class PerformanceModel {
    var rows: [PerfRow] = (0..<1000).map { PerfRow(id: $0, value: Double($0)) }
    var tick = 0
    var running = false

    func step() {
        tick += 1
        // Mutate 1% of the rows; only those rows' bodies should re-run.
        for _ in 0..<10 {
            let index = Int.random(in: 0..<rows.count)
            rows[index].value += 1
        }
    }
}

struct PerfRow: Identifiable, Equatable {
    let id: Int
    var value: Double
}

struct PerformanceScreen: View {
    @State private var model = PerformanceModel()
    @State private var lazy = true

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Performance Lab").font(.largeTitle).bold()
                Spacer()
                Toggle("Lazy", isOn: $lazy)
                Button(model.running ? "Stop" : "Start 60 Hz") { model.running.toggle() }
                Text("tick \(model.tick)").monospacedDigit()
            }
            Text("1000 rows; each tick mutates 10 random rows. Expected: ≤ 10 row bodies per tick.")
                .foregroundStyle(.secondary)
            ScrollView {
                if lazy {
                    LazyVStack(alignment: .leading) { rowsContent }
                } else {
                    VStack(alignment: .leading) { rowsContent }
                }
            }
        }
        .padding(24)
        .task(id: model.running) {
            while model.running && !Task.isCancelled {
                model.step()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private var rowsContent: some View {
        ForEach(model.rows) { row in
            PerfRowView(row: row)
        }
    }
}

struct PerfRowView: View {
    let row: PerfRow
    var body: some View {
        let _ = UpdateLog.shared.hit("PerfRowView")
        HStack {
            Text("Row \(row.id)").frame(width: 90, alignment: .leading)
            ProgressView(value: row.value.truncatingRemainder(dividingBy: 100), total: 100)
            Text(row.value, format: .number.precision(.fractionLength(0))).monospacedDigit().frame(width: 60, alignment: .trailing)
        }
    }
}
