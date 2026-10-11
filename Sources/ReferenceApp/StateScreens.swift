import SwiftUI
import Observation

// MARK: - State & bindings

struct StateScreen: View {
    @State private var count = 0
    @State private var name = "World"
    @State private var isOn = false

    var body: some View {
        let _ = UpdateLog.shared.hit("StateScreen")
        DemoPage(title: "State & Bindings", summary: "@State is owned by a view identity; @Binding passes write access down without copying.") {
            DemoSection(title: "Counter (state read in body)") {
                HStack {
                    Button("−") { count -= 1 }
                    Text("\(count)").font(.title2.monospacedDigit()).frame(minWidth: 50)
                    Button("+") { count += 1 }
                    Button("Reset") { count = 0 }.disabled(count == 0)
                }
                StaticChildView(label: "This child has constant inputs: its body never re-runs")
            }
            DemoSection(title: "Binding to a child") {
                NameEditor(name: $name)
                Text("Hello, \(name)!")
            }
            DemoSection(title: "Write-only state") {
                WriteOnlyCounter()
            }
            DemoSection(title: "State preserved across parent updates") {
                Toggle("Parent toggle (re-renders parent)", isOn: $isOn)
                StatefulChild()
            }
            DemoSection(title: "@StateObject vs @ObservedObject") {
                StateObjectDemo(seed: count)
            }
        }
    }
}

struct StaticChildView: View {
    let label: String
    var body: some View {
        let _ = UpdateLog.shared.hit("StaticChildView")
        Text(label).font(.caption).foregroundStyle(.secondary)
    }
}

struct NameEditor: View {
    @Binding var name: String
    var body: some View {
        let _ = UpdateLog.shared.hit("NameEditor")
        HStack {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
            Button("Uppercase") { name = name.uppercased() }
        }
    }
}

struct WriteOnlyCounter: View {
    @State private var taps = 0
    var body: some View {
        let _ = UpdateLog.shared.hit("WriteOnlyCounter")
        // `taps` is never read in body, so tapping does not re-evaluate it.
        Button("Tap (state written, not read)") { taps += 1 }
    }
}

struct StatefulChild: View {
    @State private var local = 0
    var body: some View {
        let _ = UpdateLog.shared.hit("StatefulChild")
        Stepper("Child-local value: \(local)", value: $local)
    }
}

final class Ticker: ObservableObject {
    @Published var value: Int
    init(seed: Int) { value = seed }
}

struct StateObjectDemo: View {
    let seed: Int
    @StateObject private var owned = Ticker(seed: 0)

    var body: some View {
        let _ = UpdateLog.shared.hit("StateObjectDemo")
        HStack {
            Text("Owned ticker: \(owned.value) (parent seed \(seed))")
            Button("Tick") { owned.value += 1 }
            ObservedTickerView(ticker: owned)
        }
    }
}

struct ObservedTickerView: View {
    @ObservedObject var ticker: Ticker
    var body: some View {
        let _ = UpdateLog.shared.hit("ObservedTickerView")
        Text("observed: \(ticker.value)").foregroundStyle(.secondary)
    }
}

// MARK: - Observation

@Observable
final class Profile {
    var firstName = "Ada"
    var lastName = "Lovelace"
    var visits = 0
}

final class LegacyProfile: ObservableObject {
    @Published var firstName = "Alan"
    @Published var lastName = "Turing"
    @Published var visits = 0
}

struct ObservationScreen: View {
    @State private var profile = Profile()
    @StateObject private var legacy = LegacyProfile()

    var body: some View {
        DemoPage(title: "Observation", summary: "@Observable tracks individual properties; ObservableObject invalidates every observer on any change.") {
            HStack(alignment: .top, spacing: 16) {
                DemoSection(title: "@Observable") {
                    FirstNameView(profile: profile)
                    LastNameView(profile: profile)
                    VisitsView(profile: profile)
                    Button("visits += 1") { profile.visits += 1 }
                    BindableEditor(profile: profile)
                }
                DemoSection(title: "ObservableObject") {
                    LegacyFirstNameView(profile: legacy)
                    LegacyLastNameView(profile: legacy)
                    Button("visits += 1") { legacy.visits += 1 }
                    Text("Every row above re-renders on any change.").font(.caption)
                }
            }
        }
    }
}

struct FirstNameView: View {
    let profile: Profile
    var body: some View {
        let _ = UpdateLog.shared.hit("Observable.FirstName")
        Text("First: \(profile.firstName)")
    }
}

struct LastNameView: View {
    let profile: Profile
    var body: some View {
        let _ = UpdateLog.shared.hit("Observable.LastName")
        Text("Last: \(profile.lastName)")
    }
}

struct VisitsView: View {
    let profile: Profile
    var body: some View {
        let _ = UpdateLog.shared.hit("Observable.Visits")
        Text("Visits: \(profile.visits)")
    }
}

struct BindableEditor: View {
    @Bindable var profile: Profile
    var body: some View {
        TextField("First name", text: $profile.firstName).textFieldStyle(.roundedBorder)
    }
}

struct LegacyFirstNameView: View {
    @ObservedObject var profile: LegacyProfile
    var body: some View {
        let _ = UpdateLog.shared.hit("Legacy.FirstName")
        Text("First: \(profile.firstName)")
    }
}

struct LegacyLastNameView: View {
    @ObservedObject var profile: LegacyProfile
    var body: some View {
        let _ = UpdateLog.shared.hit("Legacy.LastName")
        Text("Last: \(profile.lastName)")
    }
}

// MARK: - Environment

struct EnvironmentScreen: View {
    @Environment(Library.self) private var library
    @EnvironmentObject private var settings: AppSettings
    @State private var radius: CGFloat = 12

    var body: some View {
        DemoPage(title: "Environment", summary: "Values flow down; views only update for the keys they read.") {
            DemoSection(title: "Custom key") {
                Slider(value: $radius, in: 0...30) { Text("Corner radius") }
                HStack {
                    Card(text: "Reads cardStyle")
                    PlainCard(text: "Does not read cardStyle")
                }
                .environment(\.cardStyle, CardStyle(cornerRadius: radius))
            }
            DemoSection(title: "@Environment(Model.self)") {
                Text("\(library.books.count) books, \(library.favorites.count) favorites")
            }
            DemoSection(title: "@EnvironmentObject") {
                Text("Signed in as \(settings.username)")
                Toggle("Compact rows", isOn: $settings.compactRows)
            }
            DemoSection(title: "Built-in keys") {
                VStack(alignment: .leading) {
                    Text("font(.title3) on the stack")
                    Text("…inherited by children")
                    Text("…unless overridden").font(.caption)
                }
                .font(.title3)
                Text("disabled() propagates isEnabled").padding(4)
                Button("Disabled button") {}.disabled(true)
            }
        }
    }
}

struct Card: View {
    let text: String
    @Environment(\.cardStyle) private var style
    var body: some View {
        let _ = UpdateLog.shared.hit("Card")
        Text(text)
            .padding(style.padding)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: style.cornerRadius))
    }
}

struct PlainCard: View {
    let text: String
    var body: some View {
        let _ = UpdateLog.shared.hit("PlainCard")
        Text(text).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
