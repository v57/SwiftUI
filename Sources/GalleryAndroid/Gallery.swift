// A smoke-test app for the Android backend: animations, gestures, presentations, navigation,
// timers, async work and text input. Plain SwiftUI; built with
// Android/scripts/build-app --product GalleryAndroid.
import SwiftUI2

@main
struct GalleryApp: App {
    var body: some Scene {
        WindowGroup("Gallery") { GalleryRoot() }
    }
}

struct GalleryRoot: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Animation", value: "animation")
                NavigationLink("Gestures", value: "gestures")
                NavigationLink("Presentations", value: "presentations")
                NavigationLink("Timers & tasks", value: "timers")
                NavigationLink("Text input", value: "text")
            }
            .navigationTitle("Gallery")
            .navigationDestination(for: String.self) { page in
                switch page {
                case "animation": AnimationPage()
                case "gestures": GesturesPage()
                case "presentations": PresentationsPage()
                case "timers": TimersPage()
                default: TextInputPage()
                }
            }
        }
    }
}

struct AnimationPage: View {
    @State private var expanded = false
    @State private var shown = true
    var body: some View {
        VStack(spacing: 24) {
            RoundedRectangle(cornerRadius: expanded ? 40 : 8)
                .fill(expanded ? Color.orange : Color.blue)
                .frame(width: expanded ? 240 : 120, height: 120)
                .rotationEffect(.degrees(expanded ? 45 : 0))
            if shown {
                Text("Fades and slides").padding().background(.yellow, in: Capsule())
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            HStack {
                Button("Spring") { withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { expanded.toggle() } }
                Button("Toggle") { withAnimation(.easeInOut(duration: 0.6)) { shown.toggle() } }
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Animation")
    }
}

struct GesturesPage: View {
    @State private var offset = CGSize.zero
    @State private var dragging = false
    @State private var taps = 0
    @State private var longPressed = false
    var body: some View {
        VStack(spacing: 30) {
            Circle().fill(dragging ? Color.red : Color.green)
                .frame(width: 80, height: 80)
                .offset(offset)
                .gesture(DragGesture()
                    .onChanged { value in offset = value.translation; dragging = true }
                    .onEnded { _ in withAnimation(.spring) { offset = .zero }; dragging = false })
            Text("Taps: \(taps)").padding().background(.thinMaterial).onTapGesture { taps += 1 }
            Text(longPressed ? "Long pressed" : "Long press me").padding().background(.thinMaterial)
                .onLongPressGesture { longPressed.toggle() }
        }
        .navigationTitle("Gestures")
    }
}

struct PresentationsPage: View {
    @State private var sheet = false
    @State private var alert = false
    @State private var dialog = false
    @State private var choice = "none"
    var body: some View {
        VStack(spacing: 16) {
            Text("Last choice: \(choice)")
            Button("Show sheet") { sheet = true }
            Button("Show alert") { alert = true }
            Button("Confirmation dialog") { dialog = true }
            Menu("Menu") {
                Button("First") { choice = "first" }
                Button("Second") { choice = "second" }
            }
        }
        .buttonStyle(.bordered)
        .sheet(isPresented: $sheet) {
            VStack(spacing: 20) {
                Text("A sheet").font(.title)
                Button("Close") { sheet = false }
            }
            .padding(40)
        }
        .alert("Delete everything?", isPresented: $alert) {
            Button("Delete", role: .destructive) { choice = "deleted" }
            Button("Cancel", role: .cancel) { choice = "cancelled" }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Pick one", isPresented: $dialog) {
            Button("Apples") { choice = "apples" }
            Button("Oranges") { choice = "oranges" }
        }
        .navigationTitle("Presentations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Share", systemImage: "square.and.arrow.up") { choice = "toolbar" }
            }
        }
    }
}

struct TimersPage: View {
    @State private var ticks = 0
    @State private var taskResult = "waiting"
    @State private var date = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 16) {
            Text("Timer ticks: \(ticks)").onReceive(timer) { _ in ticks += 1 }
            Text("Task: \(taskResult)")
            Text(date, style: .timer)
            ProgressView()
        }
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            taskResult = "finished on the main actor"
        }
        .navigationTitle("Timers")
    }
}

struct TextInputPage: View {
    @State private var name = ""
    @State private var url = ""
    @State private var number = ""
    @State private var secret = ""
    @State private var notes = "Multiline\ntext"
    @FocusState private var focused: Bool
    var body: some View {
        Form {
            TextField("Name", text: $name).textInputAutocapitalization(.words)
            TextField("URL", text: $url).keyboardType(.URL).textContentType(.URL).autocorrectionDisabled()
            TextField("Number", text: $number).keyboardType(.numberPad).focused($focused)
            SecureField("Password", text: $secret)
            TextEditor(text: $notes).frame(height: 100)
            Text("Hello, \(name.isEmpty ? "nobody" : name)")
            Button("Focus number") { focused = true }
        }
        .navigationTitle("Text input")
    }
}
