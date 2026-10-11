// API usage corpus: idiomatic SwiftUI that must compile unchanged against SwiftUI.
// Typecheck against Apple: Tools/corpus/check.sh

import Foundation
import Observation
import SwiftUI

@Observable final class CorpusModel {
    var name = "Ada"
    var count = 0
    var items = ["One", "Two", "Three"]
    var selection: String?
    var isOn = false
    var value = 0.5
    var date = Date()
    var color = Color.blue
}

struct CorpusShapes: View {
    var body: some View {
        VStack {
            Circle().fill(.red).stroke(.blue, lineWidth: 2)
            Capsule().strokeBorder(.green, lineWidth: 3).background(Capsule().fill(.yellow))
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.blue.gradient)
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomTrailingRadius: 12).fill(.orange)
            Rectangle().trim(from: 0, to: 0.5).stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 2]))
            Ellipse().inset(by: 4).stroke(.purple)
            Circle().rotation(.degrees(45)).offset(x: 2).scale(0.5).fill(.pink)
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 10, y: 10))
                path.addArc(center: .zero, radius: 5, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
                path.closeSubpath()
            }
            .stroke(.black, lineWidth: 1)
            Circle().fill(LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom))
            Circle().fill(RadialGradient(colors: [.white, .black], center: .center, startRadius: 0, endRadius: 20))
            Circle().fill(AngularGradient(gradient: Gradient(colors: [.red, .green]), center: .center))
            Circle().fill(EllipticalGradient(colors: [.red, .clear]))
            Rectangle().fill(.ultraThinMaterial)
            Circle().fill(.shadow(.drop(radius: 2)))
            ContainerRelativeShape().fill(.tint)
            Rectangle().union(Circle()).fill(.blue)
            Circle().intersection(Rectangle()).stroke()
            AnyShape(Circle()).fill(.red)
        }
        .foregroundStyle(.secondary)
        .tint(.orange)
    }
}

struct CorpusLayout: View {
    var body: some View {
        VStack {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("A")
                    Text("B").gridCellColumns(2)
                }
                GridRow(alignment: .bottom) {
                    Text("C").gridColumnAlignment(.trailing)
                    Color.red.gridCellUnsizedAxes(.horizontal)
                }
            }
            ViewThatFits(in: .horizontal) {
                Text("A long version of the text")
                Text("Short")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80)), GridItem(.fixed(40)), GridItem(.flexible(minimum: 10, maximum: 100))], spacing: 8, pinnedViews: [.sectionHeaders]) {
                Section { ForEach(0..<10) { Text("\($0)") } } header: { Text("Header") }
            }
            LazyHStack(alignment: .top, spacing: 4) { ForEach(0..<3, id: \.self) { Text("\($0)") } }
            HStack { Spacer(minLength: 0); Text("x").layoutPriority(1).fixedSize(horizontal: true, vertical: false) }
            Text("frame").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(EdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4))
            Text("relative").containerRelativeFrame(.horizontal, count: 3, span: 2, spacing: 8)
            Text("aspect").aspectRatio(16 / 9, contentMode: .fit).aspectRatio(contentMode: .fill)
            ZStack(alignment: .topLeading) { Color.red; Text("over").alignmentGuide(.leading) { $0[.trailing] } }
            Text("inset").safeAreaInset(edge: .bottom, spacing: 0) { Text("bar") }.safeAreaPadding(.horizontal, 10)
            AnyLayout(HStackLayout(spacing: 4)) { Text("a"); Text("b") }
            GeometryReader { proxy in Text("\(proxy.size.width)").position(x: proxy.size.width / 2, y: 10) }
            Text("offset").offset(y: -2).zIndex(1)
            Divider()
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.map(\.width).reduce(0, +), height: sizes.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}

struct CorpusControls: View {
    @Bindable var model: CorpusModel
    @State private var text = ""
    @State private var number = 3
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @AppStorage("corpus.flag") private var flag = false
    @SceneStorage("corpus.tab") private var tab = 0

    var body: some View {
        Form {
            Section("Text") {
                TextField("Name", text: $model.name, prompt: Text("Your name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { focused = false }
                TextField("Number", value: $number, format: .number)
                SecureField("Password", text: $text)
                TextEditor(text: $text).frame(height: 60)
                LabeledContent("Value", value: model.value, format: .percent)
                LabeledContent("Custom") { Text("x") }
            }
            Section {
                Toggle("Enabled", isOn: $model.isOn).toggleStyle(.switch)
                Toggle(isOn: $flag) { Label("Flag", systemImage: "flag") }.toggleStyle(.checkbox)
                Slider(value: $model.value, in: 0...1, step: 0.1) { Text("Slider") } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("1") } onEditingChanged: { _ in }
                Stepper("Count \(model.count)", value: $model.count, in: 0...10)
                Stepper { Text("Step") } onIncrement: { model.count += 1 } onDecrement: { model.count -= 1 }
                Picker("Pick", selection: $model.selection) {
                    Text("None").tag(String?.none)
                    ForEach(model.items, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
                Picker("Segment", selection: $tab) { Text("A").tag(0); Text("B").tag(1) }.pickerStyle(.segmented).labelsHidden()
                DatePicker("Date", selection: $model.date, displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.compact)
                ColorPicker("Color", selection: $model.color, supportsOpacity: false)
                Gauge(value: model.value) { Text("Gauge") } currentValueLabel: { Text("50%") }.gaugeStyle(.accessoryCircularCapacity)
                ProgressView(value: model.value, total: 1) { Text("Progress") }.progressViewStyle(.linear)
                ProgressView().controlSize(.small)
            } header: {
                Text("Controls")
            } footer: {
                Text("Footer").font(.footnote)
            }
            Section {
                Button("Plain") {}.buttonStyle(.plain)
                Button(role: .destructive) { dismiss() } label: { Label("Delete", systemImage: "trash") }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Bordered", systemImage: "star") {}.buttonStyle(.bordered).buttonBorderShape(.capsule).keyboardShortcut(.defaultAction)
                Link("Website", destination: URL(string: "https://example.com")!)
                Menu("Menu") {
                    Button("One") {}
                    Divider()
                    Section("More") { Button("Two") {} }
                    Menu("Sub") { Button("Three") {} }
                } primaryAction: { }
                .menuStyle(.borderlessButton)
                ControlGroup { Button("A") {}; Button("B") {} } label: { Text("Group") }
                ShareLink(item: URL(string: "https://example.com")!) { Label("Share", systemImage: "square.and.arrow.up") }
                Toggle("Mixed", sources: [$model.isOn], isOn: \.self)
            }
        }
        .formStyle(.grouped)
        .disabled(false)
        .onChange(of: model.count) { old, new in _ = (old, new) }
        .onChange(of: text, initial: true) { }
        .task { await Task.yield() }
        .task(id: model.count) { }
        .onAppear { }
        .onDisappear { }
        .onReceive(NotificationCenter.default.publisher(for: .init("x"))) { _ in }
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(.dark)
    }
}

struct CorpusLists: View {
    @State private var model = CorpusModel()
    @State private var multi = Set<String>()
    @State private var expanded = true
    struct Node: Identifiable, Hashable { let id = UUID(); var name: String; var children: [Node]? }
    let tree = [Node(name: "Root", children: [Node(name: "Leaf", children: nil)])]

    var body: some View {
        VStack {
            List(selection: $multi) {
                Section("Items") {
                    ForEach(model.items, id: \.self) { item in
                        Text(item)
                            .swipeActions(edge: .trailing) { Button("Delete", role: .destructive) {} }
                            .contextMenu { Button("Copy") {} }
                            .badge(2)
                            .listRowSeparator(.hidden)
                    }
                    .onDelete { model.items.remove(atOffsets: $0) }
                    .onMove { model.items.move(fromOffsets: $0, toOffset: $1) }
                }
                DisclosureGroup("More", isExpanded: $expanded) { Text("Hidden") }
                OutlineGroup(tree, children: \.children) { Text($0.name) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            List(tree, children: \.children) { Text($0.name) }.listStyle(.inset(alternatesRowBackgrounds: true))
            Table(of: Node.self) {
                TableColumn("Name") { Text($0.name) }
                TableColumn("Count") { _ in Text("0") }.width(min: 40, ideal: 60)
            } rows: {
                ForEach(tree) { TableRow($0) }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(pinnedViews: .sectionHeaders) { ForEach(0..<20) { Text("\($0)").id($0) } }
                    .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $model.selection)
            ScrollViewReader { proxy in Button("Top") { withAnimation { proxy.scrollTo(0, anchor: .top) } } }
        }
        .searchable(text: $model.name, placement: .sidebar, prompt: "Search")
        .refreshable { }
    }
}
