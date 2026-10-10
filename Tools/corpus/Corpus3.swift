// API usage corpus, part 3: text, images, data flow, tabs, scroll geometry, colors.

import Foundation
import Combine
import Observation
#if canImport(SwiftUI2) && !APPLE_SWIFTUI
import SwiftUI2
#else
import SwiftUI
#endif

final class LegacyModel: ObservableObject {
    @Published var title = "Legacy"
    @Published var progress = 0.3
}

struct CorpusText: View {
    let date = Date()
    let price = 9.99
    var body: some View {
        VStack(alignment: .leading) {
            Text(date, format: .dateTime.year().month().day())
            Text(date, style: .relative)
            Text(timerInterval: date...date.addingTimeInterval(60), countsDown: true)
            Text(price, format: .currency(code: "EUR"))
            Text(0.25, format: .percent.precision(.fractionLength(1)))
            Text(42, format: .number)
            Text("Hello ") + Text("World").bold().foregroundStyle(.red) + Text(Image(systemName: "star"))
            Text("Gradient").foregroundStyle(.linearGradient(colors: [.red, .blue], startPoint: .leading, endPoint: .trailing))
            Text(verbatim: "100%").monospacedDigit().monospaced()
            Text("Selectable").textSelection(.enabled)
            Text("Underlined").underline(true, pattern: .dash, color: .red).strikethrough(color: .blue)
            Text(AttributedString("Attributed"))
            Text("Long text").lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
            Text("Styled").font(.system(.title, design: .rounded, weight: .bold)).fontWeight(.heavy).fontDesign(.serif).italic()
            Text("Kerned").kerning(1.5).tracking(0.5).baselineOffset(2)
            TextField("Multiline", text: .constant(""), axis: .vertical).lineLimit(3...6)
            Label("Inbox", systemImage: "tray").labelStyle(.iconOnly)
            Label { Text("Custom") } icon: { Circle().frame(width: 8, height: 8) }.labelStyle(.titleAndIcon)
            ContentUnavailableView("No Items", systemImage: "tray", description: Text("Add an item"))
            ContentUnavailableView.search(text: "query")
            ContentUnavailableView { Label("Empty", systemImage: "xmark") } description: { Text("Nothing") } actions: { Button("Add") {} }
        }
    }
}

struct CorpusImages: View {
    var body: some View {
        VStack {
            Image(systemName: "heart.fill").imageScale(.large).symbolVariant(.circle).font(.title)
            Image(systemName: "star").resizable().scaledToFit().frame(width: 20)
            Image(systemName: "bolt").resizable().aspectRatio(contentMode: .fill).clipped()
            Image(decorative: "photo")
            Image("photo", bundle: .main).renderingMode(.template).interpolation(.high).antialiased(true)
            #if canImport(AppKit)
            Image(nsImage: NSImage(size: NSSize(width: 4, height: 4)))
            #endif
            Image(systemName: "wifi", variableValue: 0.5)
            AsyncImage(url: URL(string: "https://example.com/a.png")) { phase in
                switch phase {
                case .empty: ProgressView()
                case .success(let image): image.resizable()
                case .failure: Image(systemName: "xmark")
                @unknown default: EmptyView()
                }
            }
            AsyncImage(url: nil, scale: 2) { image in image } placeholder: { Color.gray }
        }
    }
}

struct CorpusDataFlow: View {
    @StateObject private var legacy = LegacyModel()
    @ObservedObject var observed: LegacyModel
    @EnvironmentObject var shared: LegacyModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale
    @State private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: "home") { Text(legacy.title) }
            Tab("Search", systemImage: "magnifyingglass", value: "search", role: .search) { Text("Search") }
            TabSection("More") {
                Tab("Settings", systemImage: "gear", value: "settings") { Text("Settings") }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: scenePhase) { _, phase in _ = phase == .active }
        .onReceive(legacy.$progress) { _ in }
        .environmentObject(legacy)
    }
}

struct CorpusLegacyTabs: View {
    @State private var selection = 0
    var body: some View {
        TabView(selection: $selection) {
            Text("One").tabItem { Label("One", systemImage: "1.circle") }.tag(0)
            Text("Two").tabItem { Text("Two") }.tag(1)
        }
        .tabViewStyle(.automatic)
    }
}

struct CorpusScrollGeometry: View {
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    var body: some View {
        ScrollView {
            LazyVStack { ForEach(0..<50) { Text("Row \($0)").id($0) } }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in geometry.contentOffset.y } action: { _, new in offset = new }
        .scrollClipDisabled()
        .contentMargins(.vertical, 8, for: .scrollContent)
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { position.scrollTo(edge: .bottom); position.scrollTo(id: 3, anchor: .center) }
    }
}

struct CorpusColorsAndMisc: View {
    var body: some View {
        VStack {
            Color(red: 0.1, green: 0.2, blue: 0.3)
            Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 0.5)
            Color(hue: 0.5, saturation: 0.8, brightness: 0.9)
            Color(white: 0.4)
            #if canImport(AppKit)
            Color(nsColor: .windowBackgroundColor)
            #endif
            Color.accentColor.opacity(0.3)
            Color.red.mix(with: .blue, by: 0.5)
            Rectangle().fill(Color.primary.secondary)
            GroupBox("Group") { Text("Content") }
            GroupBox { Text("Body") } label: { Label("Box", systemImage: "shippingbox") }
            Text("Masked").mask { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom) }
            Text("Clipped").clipShape(.rect(cornerRadius: 8)).shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            Text("Bordered").border(.red, width: 2).cornerRadius(4)
            Text("Overlay").overlay(alignment: .topTrailing) { Circle().frame(width: 6) }
            Text("Equatable").equatable()
            Text("Container").containerBackground(.thinMaterial, for: .window)
            Text("Background").background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            ProgressView(timerInterval: Date()...Date().addingTimeInterval(10))
            Stepper(value: .constant(1.0), in: 0...10, step: 0.5, format: .number) { Text("Step") }
            Picker("Radio", selection: .constant(1)) { Text("A").tag(1); Text("B").tag(2) }.pickerStyle(.radioGroup).horizontalRadioGroupLayout()
            Picker("Inline", selection: .constant(1)) { Text("A").tag(1) }.pickerStyle(.inline)
            DatePicker("Graphical", selection: .constant(Date())).datePickerStyle(.graphical)
            Toggle("Button", isOn: .constant(true)).toggleStyle(.button)
        }
        .onSubmit(of: .text) {}
    }
}

#if canImport(AppKit)
@MainActor func corpusRender() -> NSImage? {
    let renderer = ImageRenderer(content: Text("Render"))
    renderer.scale = 2
    return renderer.nsImage
}
#endif
