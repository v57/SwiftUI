import Foundation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

struct BracketGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack { Text("["); configuration.label; configuration.content; Text("]") }
    }
}

struct ColonLabeledContentStyle: LabeledContentStyle {
    let separator: String
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) { configuration.label; Text(separator); configuration.content }
    }
}

struct ToggleDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack {
            Button(configuration.isExpanded ? "Hide" : "Show") { configuration.isExpanded.toggle() }
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct PercentProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        Text("\(Int((configuration.fractionCompleted ?? 0) * 100))%")
    }
}

struct ValueGaugeStyle: GaugeStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack { configuration.label; Text("\(Int(configuration.value * 10))/10") }
    }
}

struct PrefixedMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack { Text(">"); Menu(configuration) }
    }
}

@MainActor
@Suite(.serialized)
struct StyleTests {
    @Test func customMenuStyleWrapsNativeMenu() {
        let host = TestHost(Menu("Actions") { Button("A") {} }.menuStyle(PrefixedMenuStyle()))
        #expect(host.texts.first == ">")
        #expect(host.texts.contains("Actions"))
    }

    @Test func sidebarAdaptableTabViewListsTabsVertically() throws {
        let host = TestHost(
            TabView {
                Text("one").tabItem { Text("First") }.tag(1)
                Text("two").tabItem { Text("Second") }.tag(2)
            }.tabViewStyle(.sidebarAdaptable),
            size: CGSize(width: 400, height: 300)
        )
        let first = try #require(host.view(withText: "First")).absoluteFrame
        let second = try #require(host.view(withText: "Second")).absoluteFrame
        #expect(second.minY > first.maxY && abs(second.minX - first.minX) < 1)
        #expect(try #require(host.view(withText: "one")).absoluteFrame.minX > 180)
    }

    @Test func datePickerStyleReachesRenderModel() {
        let host = TestHost(DatePicker("When", selection: .constant(Date(timeIntervalSince1970: 0))).datePickerStyle(.graphical))
        let pickers = host.allViews.compactMap { view -> DatePickerStyleKind? in
            if case .datePicker(let picker) = view.content { return picker.style } else { return nil }
        }
        #expect(pickers == [.graphical])
    }

    @Test func customStylesRenderConfigurations() {
        let host = TestHost(VStack {
            GroupBox("Title") { Text("body") }.groupBoxStyle(BracketGroupBoxStyle())
            LabeledContent("Name", value: "Ann").labeledContentStyle(ColonLabeledContentStyle(separator: ": "))
            ProgressView(value: 0.25).progressViewStyle(PercentProgressStyle())
            Gauge(value: 3, in: 0...10) { Text("Level") }.gaugeStyle(ValueGaugeStyle())
        })
        #expect(host.texts == ["[", "Title", "body", "]", "Name", ": ", "Ann", "25%", "Level", "3/10"])
    }

    @Test func disclosureStyleDrivesExpansion() {
        let host = TestHost(DisclosureGroup("Details") { Text("hidden") }.disclosureGroupStyle(ToggleDisclosureStyle()))
        #expect(!host.texts.contains("hidden"))
        host.tap("Show")
        #expect(host.texts.contains("hidden"))
    }

    @Test func styleParametersUpdateViews() {
        struct Screen: View {
            @State var separator = ": "
            var body: some View {
                VStack {
                    LabeledContent("A", value: "1").labeledContentStyle(ColonLabeledContentStyle(separator: separator))
                    Button("change") { separator = " = " }
                }
            }
        }
        let host = TestHost(Screen())
        #expect(host.texts.contains(": "))
        host.tap("change")
        #expect(host.texts.contains(" = "))
    }
}
