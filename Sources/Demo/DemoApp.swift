import SwiftUI2

@Observable
final class TodoStore {
    struct Item: Identifiable, Equatable {
        let id: Int
        var title: String
        var done = false
    }

    var items: [Item] = [
        Item(id: 1, title: "Build the attribute graph", done: true),
        Item(id: 2, title: "Write the AppKit backend", done: true),
        Item(id: 3, title: "Port the reference app"),
    ]
    var draft = ""
    private var nextID = 4

    func add() {
        guard !draft.isEmpty else { return }
        items.append(Item(id: nextID, title: draft))
        nextID += 1
        draft = ""
    }
}

final class Preferences: ObservableObject {
    @Published var showCompleted = true
    @Published var accent = Color.blue
}

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup("SwiftUI2 Demo") {
            DemoRoot()
        }
        .defaultSize(width: 520, height: 560)
    }
}

struct DemoRoot: View {
    @State private var store = TodoStore()
    @StateObject private var preferences = Preferences()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(count: store.items.filter { !$0.done }.count)
            CounterCard()
            TodoList(store: store)
            Spacer()
        }
        .padding(20)
        .environmentObject(preferences)
    }
}

struct Header: View {
    let count: Int
    var body: some View {
        HStack {
            Text("SwiftUI2").font(.largeTitle).bold()
            Spacer()
            Text("\(count) open")
                .padding(6)
                .background(Color.blue.opacity(0.15))
                .cornerRadius(6)
        }
    }
}

struct CounterCard: View {
    @State private var count = 0
    @State private var slider = 0.5

    var body: some View {
        HStack(spacing: 12) {
            Button("−") { count -= 1 }
            Text("\(count)").font(.title2).monospacedDigit()
                .frame(width: 60)
            Button("+") { count += 1 }
            Slider(value: $slider)
            Text("\(Int(slider * 100))%").frame(width: 44, alignment: .trailing)
        }
        .padding(12)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(10)
        .overlay(alignment: .topTrailing) {
            if count != 0 {
                Text("\(count)")
                    .font(.caption)
                    .padding(4)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .offset(x: 6, y: -6)
            }
        }
    }
}

struct TodoList: View {
    @Bindable var store: TodoStore
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("New item", text: $store.draft)
                Button("Add") { store.add() }
                    .buttonStyle(.borderedProminent)
            }
            Toggle("Show completed", isOn: $preferences.showCompleted)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.items) { item in
                        if preferences.showCompleted || !item.done {
                            TodoRow(item: item) {
                                if let index = store.items.firstIndex(where: { $0.id == item.id }) {
                                    store.items[index].done.toggle()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct TodoRow: View {
    let item: TodoStore.Item
    let toggle: () -> Void

    var body: some View {
        HStack {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(item.done ? .green : .secondary)
            Text(item.title)
                .strikethrough(item.done)
                .foregroundColor(item.done ? .secondary : .primary)
            Spacer()
        }
        .padding(.vertical, 4)
        .onTapGesture(perform: toggle)
    }
}
