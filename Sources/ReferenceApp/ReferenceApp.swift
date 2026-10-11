// Reference app: written against Apple's SwiftUI. It is the executable behavioural spec for
// SwiftUI — each screen exercises a feature area, and every screen should eventually compile and
// behave identically when built against SwiftUI (see docs/PARITY.md).
//
//   swift run ReferenceApp
import SwiftUI

@main
struct ReferenceApp: App {
    @State private var library = Library.sample()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup("SwiftUI Reference") {
            RootView()
                .environment(library)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .defaultSize(width: 1100, height: 760)

        Settings {
            SettingsScreen()
                .environmentObject(settings)
                .frame(width: 420)
        }
    }
}

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case state = "State & Bindings"
    case observation = "Observation"
    case layout = "Layout"
    case customLayout = "Custom Layout"
    case overlays = "Overlays & Backgrounds"
    case identity = "Lists & Identity"
    case library = "Library (List/Navigation)"
    case forms = "Forms & Controls"
    case environment = "Environment"
    case animation = "Animation"
    case preferences = "Preferences & Geometry"
    case text = "Text & Images"
    case presentation = "Sheets & Alerts"
    case async = "Async & Tasks"
    case gestures = "Gestures & Canvas"
    case data = "Tables & Grids"
    case performance = "Performance Lab"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .state: return "switch.2"
        case .observation: return "eye"
        case .layout: return "square.grid.3x1.below.line.grid.1x2"
        case .customLayout: return "circle.hexagongrid"
        case .overlays: return "square.on.square"
        case .identity: return "list.number"
        case .library: return "books.vertical"
        case .forms: return "slider.horizontal.3"
        case .environment: return "leaf"
        case .animation: return "wand.and.stars"
        case .preferences: return "ruler"
        case .text: return "textformat"
        case .presentation: return "rectangle.portrait.on.rectangle.portrait"
        case .async: return "clock.arrow.circlepath"
        case .gestures: return "hand.draw"
        case .data: return "tablecells"
        case .performance: return "speedometer"
        }
    }
}

struct RootView: View {
    /// `REFAPP_SCREEN=<case name>` selects the initial screen (used for screenshot comparisons).
    @State private var selection: Screen? = ProcessInfo.processInfo.environment["REFAPP_SCREEN"].flatMap { name in
        Screen.allCases.first { "\($0)" == name }
    } ?? .state
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $selection) { screen in
                Label(screen.rawValue, systemImage: screen.symbol)
                    .tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    switch selection ?? .state {
                    case .state: StateScreen()
                    case .observation: ObservationScreen()
                    case .layout: LayoutScreen()
                    case .customLayout: CustomLayoutScreen()
                    case .overlays: OverlayScreen()
                    case .identity: IdentityScreen()
                    case .library: LibraryScreen()
                    case .forms: FormsScreen()
                    case .environment: EnvironmentScreen()
                    case .animation: AnimationScreen()
                    case .preferences: PreferencesScreen()
                    case .text: TextScreen()
                    case .presentation: PresentationScreen()
                    case .async: AsyncScreen()
                    case .gestures: GesturesScreen()
                    case .data: DataScreen()
                    case .performance: PerformanceScreen()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if settings.showUpdateCounters {
                    UpdateCounterPanel()
                        .padding(12)
                }
            }
            .navigationTitle(selection?.rawValue ?? "")
        }
    }
}

/// Shared chrome for demo screens.
struct DemoPage<Content: View>: View {
    let title: String
    let summary: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle).bold()
                    Text(summary).foregroundStyle(.secondary)
                }
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DemoSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
