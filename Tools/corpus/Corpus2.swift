// API usage corpus, part 2: navigation, presentation, animation, gestures, toolbars, scenes.

import Foundation
import Observation
import UniformTypeIdentifiers
import SwiftUI

struct Recipe: Identifiable, Hashable, Codable { var id = UUID(); var name: String }

@Observable final class Router { var path = NavigationPath(); var recipes: [Recipe] = [] }

struct CorpusNavigation: View {
    @State private var router = Router()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selected: Recipe?
    @State private var showSheet = false
    @State private var showInspector = false
    @State private var alertItem: Recipe?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(router.recipes, selection: $selected) { recipe in
                NavigationLink(value: recipe) { Label(recipe.name, systemImage: "fork.knife") }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            .navigationTitle("Recipes")
        } content: {
            Text("Content")
        } detail: {
            NavigationStack(path: $router.path) {
                VStack {
                    NavigationLink("Next", value: 1)
                    NavigationLink { Text("Pushed") } label: { Text("Push") }
                }
                .navigationDestination(for: Int.self) { Text("Number \($0)") }
                .navigationDestination(for: Recipe.self) { Text($0.name) }
                .navigationDestination(isPresented: $showSheet) { Text("Destination") }
                .navigationTitle(selected?.name ?? "None")
                .navigationSubtitle("Subtitle")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { Button("Add", systemImage: "plus") {} }
                    ToolbarItemGroup(placement: .navigation) { Button("Back") {}; Button("Forward") {} }
                    ToolbarItem(placement: .principal) { Text("Center") }
                    ToolbarSpacer(.flexible)
                }
                .toolbarBackground(.visible, for: .windowToolbar)
                .toolbar(removing: .sidebarToggle)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSheet, onDismiss: {}) {
            Text("Sheet").presentationSizing(.form).interactiveDismissDisabled()
        }
        .sheet(item: $alertItem) { Text($0.name) }
        .popover(isPresented: $showInspector, arrowEdge: .bottom) { Text("Popover").padding() }
        .inspector(isPresented: $showInspector) { Text("Inspector").inspectorColumnWidth(min: 200, ideal: 250, max: 400) }
        .alert("Delete?", isPresented: $showSheet) {
            Button("Delete", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .confirmationDialog("Choose", isPresented: $showSheet, titleVisibility: .visible) { Button("A") {} }
        .fileImporter(isPresented: $showSheet, allowedContentTypes: [.plainText], allowsMultipleSelection: true) { result in _ = result }
        .onOpenURL { _ in }
    }
}

struct CorpusAnimation: View {
    @State private var expanded = false
    @State private var angle = 0.0
    @State private var offset = CGSize.zero
    @State private var trigger = 0
    @Namespace private var namespace
    @GestureState private var isPressing = false

    var body: some View {
        VStack {
            if expanded {
                RoundedRectangle(cornerRadius: 12).fill(.blue)
                    .matchedGeometryEffect(id: "card", in: namespace)
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .move(edge: .leading)))
            } else {
                Circle().fill(.blue).matchedGeometryEffect(id: "card", in: namespace).transition(.push(from: .bottom))
            }
            Button("Toggle") {
                withAnimation(.spring(duration: 0.4, bounce: 0.3)) { expanded.toggle() }
                withAnimation(.smooth) { angle += 90 } completion: { trigger += 1 }
                withAnimation(.snappy(extraBounce: 0.1).delay(0.1)) {}
                withAnimation(.bouncy.speed(2).repeatCount(2, autoreverses: true)) {}
            }
            Image(systemName: "arrow.right")
                .rotationEffect(.degrees(angle))
                .animation(.easeInOut(duration: 0.3), value: angle)
                .animation(.linear) { $0.opacity(expanded ? 1 : 0.5) }
            Text("Drag")
                .offset(offset)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { offset = $0.translation }
                        .onEnded { _ in withAnimation(.interpolatingSpring(stiffness: 120, damping: 12)) { offset = .zero } }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded {})
                .gesture(LongPressGesture(minimumDuration: 0.5).updating($isPressing) { value, state, _ in state = value })
                .gesture(MagnifyGesture().onChanged { _ in }.simultaneously(with: RotateGesture()))
                .gesture(TapGesture().exclusively(before: LongPressGesture()))
                .gesture(SpatialTapGesture().onEnded { _ in })
            PhaseAnimator([0.0, 1.0], trigger: trigger) { phase in Circle().scaleEffect(1 + phase * 0.2) } animation: { _ in .easeOut }
            Text("Keyframes").keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, value in view.scaleEffect(value) } keyframes: { _ in
                KeyframeTrack { SpringKeyframe(1.2, duration: 0.2); CubicKeyframe(1, duration: 0.3) }
            }
            TimelineView(.animation) { context in Text(context.date, style: .time) }
            TimelineView(.periodic(from: .now, by: 1)) { _ in EmptyView() }
            Canvas { context, size in
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(.red))
                context.stroke(Path(CGRect(x: 0, y: 0, width: 10, height: 10)), with: .color(.blue), lineWidth: 2)
                context.draw(Text("Hi"), at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
            .frame(width: 50, height: 50)
            Text("Hover").onHover { _ in }.onContinuousHover { phase in if case .active(let p) = phase { _ = p } }
            Text("Keys").focusable().onKeyPress(.space) { .handled }.onKeyPress(characters: .letters) { _ in .ignored }
            Text("Transaction").transaction { $0.animation = nil }.contentTransition(.numericText())
        }
        .sensoryFeedback(.success, trigger: trigger)
    }
}

struct CorpusDragDrop: View {
    @State private var items: [String] = []
    var body: some View {
        VStack {
            Text("Drag me").draggable("payload") { Text("Preview") }
            Color.gray.dropDestination(for: String.self) { dropped, _ in items += dropped; return true } isTargeted: { _ in }
            Text("Old").onDrag { NSItemProvider(object: "x" as NSString) }
            Color.red.onDrop(of: [.text], isTargeted: nil) { _ in true }
            Text("Copy").copyable(["x"]).onCopyCommand { [] }
            PasteButton(payloadType: String.self) { _ in }
        }
    }
}

struct CorpusToolbarAndCommands: View {
    @FocusState private var field: Int?
    var body: some View {
        Text("Toolbar")
            .toolbar(id: "main") {
                ToolbarItem(id: "share", placement: .automatic) { ShareLink(item: "text") }
            }
            .toolbarRole(.editor)
            .focusedSceneValue(\.corpusValue, 3)
            .focused($field, equals: 1)
            .defaultFocus($field, 1)
            .help("Help text")
            .accessibilityLabel("Label")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
    }
}

struct CorpusValueKey: FocusedValueKey { typealias Value = Int }
extension FocusedValues {
    var corpusValue: Int? {
        get { self[CorpusValueKey.self] }
        set { self[CorpusValueKey.self] = newValue }
    }
}

struct CorpusEntryKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var corpusEntry: Int {
        get { self[CorpusEntryKey.self] }
        set { self[CorpusEntryKey.self] = newValue }
    }
    @Entry var corpusMacroEntry: String = "default"
}

struct CorpusPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct CorpusCustomStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(6).background(configuration.isPressed ? Color.gray : Color.blue, in: .capsule)
    }
}

struct CorpusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack { configuration.icon; configuration.title } }
}

struct CorpusModifier: ViewModifier {
    func body(content: Content) -> some View { content.padding().preference(key: CorpusPreference.self, value: 1) }
}

struct CorpusApp: App {
    @NSApplicationDelegateAdaptor private var delegate: CorpusDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("Main", id: "main") {
            CorpusNavigation()
                .environment(\.corpusEntry, 1)
                .modifier(CorpusModifier())
                .buttonStyle(CorpusCustomStyle())
                .labelStyle(CorpusLabelStyle())
                .onPreferenceChange(CorpusPreference.self) { _ in }
        }
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { Button("New") {}.keyboardShortcut("n") }
            CommandMenu("Tools") { Button("Run") { openWindow(id: "aux") } }
            SidebarCommands()
        }
        Window("Aux", id: "aux") { Text("Aux") }
        Settings { Form { Text("Settings") } }
        MenuBarExtra("Extra", systemImage: "star") { Button("Quit") {} }
    }
}

final class CorpusDelegate: NSObject, NSApplicationDelegate {}
