import SwiftUI

// MARK: - Forms & controls

struct FormsScreen: View {
    @State private var name = ""
    @State private var password = ""
    @State private var notifications = true
    @State private var volume = 0.4
    @State private var quantity = 1
    @State private var flavor = "Vanilla"
    @State private var date = Date()
    @State private var color = Color.orange
    @State private var mode = 0

    var body: some View {
        Form {
            Section("Account") {
                TextField("Name", text: $name)
                SecureField("Password", text: $password)
                LabeledContent("Characters", value: "\(name.count + password.count)")
            }
            Section("Preferences") {
                Toggle("Notifications", isOn: $notifications)
                Toggle("Switch style", isOn: $notifications).toggleStyle(.switch)
                Slider(value: $volume) { Text("Volume") } minimumValueLabel: { Image(systemName: "speaker") } maximumValueLabel: { Image(systemName: "speaker.wave.3") }
                Stepper("Quantity: \(quantity)", value: $quantity, in: 1...10)
                Picker("Flavor", selection: $flavor) {
                    ForEach(["Vanilla", "Chocolate", "Strawberry"], id: \.self) { Text($0) }
                }
                Picker("Mode", selection: $mode) {
                    Text("One").tag(0)
                    Text("Two").tag(1)
                }
                .pickerStyle(.radioGroup)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                ColorPicker("Color", selection: $color)
            }
            Section("Progress") {
                ProgressView(value: volume)
                ProgressView().controlSize(.small)
                Gauge(value: volume) { Text("Gauge") }
            }
            Section {
                HStack {
                    Button("Default") {}
                    Button("Bordered") {}.buttonStyle(.bordered)
                    Button("Prominent") {}.buttonStyle(.borderedProminent)
                    Button("Plain") {}.buttonStyle(.plain)
                    Button("Destructive", role: .destructive) {}
                    Link("Link", destination: URL(string: "https://swift.org")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Animation

struct AnimationScreen: View {
    @State private var expanded = false
    @State private var angle = 0.0
    @State private var showBox = true
    @Namespace private var namespace

    var body: some View {
        DemoPage(title: "Animation", summary: "Implicit and explicit animations, transitions, matchedGeometryEffect.") {
            animationSections
        }
        .task {
            // REFAPP_AUTOPLAY=1 runs slow animations after launch (screenshot comparisons).
            guard ProcessInfo.processInfo.environment["REFAPP_AUTOPLAY"] != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.linear(duration: 2)) {
                expanded.toggle()
                showBox.toggle()
            }
            angle += 90
        }
    }

    @ViewBuilder private var animationSections: some View {
        Group {
            DemoSection(title: "Explicit (withAnimation)") {
                RoundedRectangle(cornerRadius: expanded ? 40 : 8)
                    .fill(expanded ? .purple : .blue)
                    .frame(width: expanded ? 240 : 100, height: 80)
                Button("Toggle") { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { expanded.toggle() } }
            }
            DemoSection(title: "Implicit (.animation(_:value:))") {
                Image(systemName: "arrow.up")
                    .font(.largeTitle)
                    .rotationEffect(.degrees(angle))
                    .animation(.easeInOut(duration: 0.5), value: angle)
                Button("Rotate") { angle += 90 }
            }
            DemoSection(title: "Transitions") {
                Button(showBox ? "Hide" : "Show") { withAnimation { showBox.toggle() } }
                if showBox {
                    Color.green.frame(width: 120, height: 60)
                        .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .move(edge: .leading)))
                }
            }
            DemoSection(title: "matchedGeometryEffect") {
                HStack {
                    if expanded {
                        Circle().fill(.orange).matchedGeometryEffect(id: "dot", in: namespace).frame(width: 60, height: 60)
                        Spacer()
                    } else {
                        Spacer()
                        Circle().fill(.orange).matchedGeometryEffect(id: "dot", in: namespace).frame(width: 30, height: 30)
                    }
                }
                .frame(width: 300)
            }
        }
    }
}

// MARK: - Preferences & geometry

struct WidthPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PreferencesScreen: View {
    @State private var maxLabelWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        DemoPage(title: "Preferences & Geometry", summary: "Preferences flow up; GeometryReader reads proposed size and frames.") {
            DemoSection(title: "Equal-width labels via PreferenceKey") {
                VStack(alignment: .leading) {
                    ForEach(["Name", "Email address", "Phone"], id: \.self) { label in
                        HStack {
                            Text(label)
                                .background(GeometryReader { proxy in
                                    Color.clear.preference(key: WidthPreference.self, value: proxy.size.width)
                                })
                                .frame(width: maxLabelWidth > 0 ? maxLabelWidth : nil, alignment: .trailing)
                            TextField(label, text: .constant("")).frame(width: 180)
                        }
                    }
                }
                .onPreferenceChange(WidthPreference.self) { maxLabelWidth = $0 }
                Text("measured max width: \(Int(maxLabelWidth))").font(.caption)
            }
            DemoSection(title: "GeometryReader") {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Color.red.frame(width: proxy.size.width * 0.25)
                        Color.green.frame(width: proxy.size.width * 0.5)
                        Color.blue
                    }
                    .overlay(Text("\(Int(proxy.size.width)) × \(Int(proxy.size.height))").foregroundStyle(.white))
                }
                .frame(height: 50)
            }
            DemoSection(title: "onGeometryChange") {
                Text("Resize the window")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.quaternary)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { scrollOffset = $0 }
                Text("width: \(Int(scrollOffset))").font(.caption)
            }
        }
    }
}

// MARK: - Text & images

struct TextScreen: View {
    @State private var lineLimit = 2

    var body: some View {
        DemoPage(title: "Text & Images", summary: "Fonts, styles, concatenation, truncation, SF Symbols.") {
            DemoSection(title: "Font styles") {
                ForEach([Font.largeTitle, .title, .title2, .title3, .headline, .body, .callout, .subheadline, .footnote, .caption, .caption2], id: \.self) { font in
                    Text("The quick brown fox").font(font)
                }
            }
            DemoSection(title: "Modifiers & concatenation") {
                Text("bold ").bold() + Text("italic ").italic() + Text("strikethrough ").strikethrough() + Text("underline").underline()
                Text("monospaced 0123456789").font(.body.monospaced())
                Text("Custom weight").fontWeight(.black)
                Text(Date(), style: .time)
                Text(1234.5, format: .currency(code: "EUR"))
            }
            DemoSection(title: "Wrapping and truncation") {
                Stepper("lineLimit: \(lineLimit)", value: $lineLimit, in: 1...5)
                Text(String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 6))
                    .lineLimit(lineLimit)
                    .multilineTextAlignment(.leading)
                    .frame(width: 360, alignment: .leading)
            }
            DemoSection(title: "SF Symbols") {
                HStack(spacing: 16) {
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                    Image(systemName: "cloud.sun.rain.fill").symbolRenderingMode(.multicolor)
                    Image(systemName: "folder").imageScale(.large)
                    Image(systemName: "gear").font(.title)
                    Label("Label", systemImage: "tag")
                }
                .font(.title2)
            }
        }
    }
}

// MARK: - Sheets & alerts

struct PresentationScreen: View {
    @State private var showSheet = false
    @State private var showAlert = false
    @State private var showPopover = false
    @State private var showDialog = false
    @State private var lastAction = "none"

    var body: some View {
        DemoPage(title: "Sheets & Alerts", summary: "Modal presentation driven by state.") {
            DemoSection(title: "Presentations") {
                HStack {
                    Button("Sheet") { showSheet = true }
                    Button("Alert") { showAlert = true }
                    Button("Popover") { showPopover = true }
                        .popover(isPresented: $showPopover) {
                            Text("Popover content").padding()
                        }
                    Button("Confirmation") { showDialog = true }
                }
                Text("Last action: \(lastAction)")
            }
        }
        .sheet(isPresented: $showSheet) {
            SheetContent { lastAction = "sheet dismissed" }
        }
        .alert("Delete item?", isPresented: $showAlert) {
            Button("Delete", role: .destructive) { lastAction = "deleted" }
            Button("Cancel", role: .cancel) { lastAction = "cancelled" }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog("Choose", isPresented: $showDialog) {
            Button("Option A") { lastAction = "A" }
            Button("Option B") { lastAction = "B" }
        }
    }
}

struct SheetContent: View {
    @Environment(\.dismiss) private var dismiss
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("A sheet").font(.title)
            Button("Close") {
                onDismiss()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}

// MARK: - Async

struct AsyncScreen: View {
    @State private var phase = "idle"
    @State private var seconds = 0
    @State private var query = ""
    @State private var results: [String] = []

    var body: some View {
        DemoPage(title: "Async & Tasks", summary: ".task lifetimes follow view identity; .task(id:) restarts when the id changes.") {
            DemoSection(title: ".task (cancelled on disappear)") {
                Text("Seconds on screen: \(seconds)")
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1))
                            seconds += 1
                        }
                    }
            }
            DemoSection(title: ".task(id:) debounced search") {
                TextField("Search", text: $query).frame(width: 240)
                Text("phase: \(phase)").font(.caption)
                ForEach(results, id: \.self) { Text($0) }
            }
            .task(id: query) {
                phase = "waiting"
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                phase = "done"
                results = query.isEmpty ? [] : (1...3).map { "\(query) result \($0)" }
            }
        }
    }
}
