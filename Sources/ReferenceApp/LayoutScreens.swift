import SwiftUI

// MARK: - Layout

struct LayoutScreen: View {
    @State private var spacing: CGFloat = 8
    @State private var alignment = 0
    @State private var width: CGFloat = 320

    private var horizontalAlignment: HorizontalAlignment {
        [.leading, .center, .trailing][alignment]
    }

    var body: some View {
        DemoPage(title: "Layout", summary: "Stacks, spacers, frames, padding, priorities and alignment guides.") {
            DemoSection(title: "VStack alignment & spacing") {
                Picker("Alignment", selection: $alignment) {
                    Text("Leading").tag(0)
                    Text("Center").tag(1)
                    Text("Trailing").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Slider(value: $spacing, in: 0...40) { Text("Spacing \(Int(spacing))") }
                VStack(alignment: horizontalAlignment, spacing: spacing) {
                    Text("Short")
                    Text("A little longer")
                    Text("The longest line of the three")
                }
                .padding()
                .border(.secondary)
            }
            DemoSection(title: "HStack with Spacer and layoutPriority") {
                Slider(value: $width, in: 120...600) { Text("Width \(Int(width))") }
                HStack {
                    Text("Leading label that can truncate when space runs out").lineLimit(1)
                    Spacer(minLength: 8)
                    Text("Priority").layoutPriority(1)
                }
                .frame(width: width)
                .padding(8)
                .border(.orange)
            }
            DemoSection(title: "Frames") {
                HStack(alignment: .top) {
                    Color.red.frame(width: 60, height: 60)
                    Color.green.frame(minWidth: 40, maxWidth: 120).frame(height: 60)
                    Color.blue.frame(maxWidth: .infinity, maxHeight: 60)
                    Text("fixedSize text that never wraps").fixedSize()
                }
            }
            DemoSection(title: "ZStack & alignment") {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 8).fill(.indigo.gradient).frame(width: 200, height: 100)
                    Text("bottomTrailing").padding(6).foregroundStyle(.white)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Baseline").font(.largeTitle)
                    Text("aligned").font(.body)
                    Text("text").font(.caption)
                }
            }
            DemoSection(title: "Alignment guides") {
                VStack(alignment: .leading) {
                    Text("Guide shifted by 20")
                        .alignmentGuide(.leading) { _ in -20 }
                    Text("Default leading")
                }
                .border(.secondary)
            }
            DemoSection(title: "Grid") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Name").bold()
                        Text("Value").bold()
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("Width")
                        Text("\(Int(width))")
                    }
                    GridRow {
                        Text("Spacing")
                        Text("\(Int(spacing))")
                    }
                }
            }
            DemoSection(title: "ViewThatFits") {
                ViewThatFits {
                    Text("A long label that only fits when the window is wide enough")
                    Text("Shorter label")
                    Image(systemName: "ellipsis")
                }
                .frame(maxWidth: width)
                .border(.secondary)
            }
        }
    }
}

// MARK: - Custom Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows.removeLast()
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows.append(row)
        }
        return rows
    }
}

struct RadialLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 220, height: 220))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let radius = min(bounds.width, bounds.height) / 2 - 20
        for (index, subview) in subviews.enumerated() {
            let angle = Double(index) / Double(subviews.count) * 2 * .pi
            let point = CGPoint(x: bounds.midX + radius * cos(angle), y: bounds.midY + radius * sin(angle))
            subview.place(at: point, anchor: .center, proposal: .unspecified)
        }
    }
}

struct CustomLayoutScreen: View {
    @State private var tags = ["swift", "swiftui", "layout", "attribute-graph", "appkit", "gtk", "winui", "android", "observation", "combine"]
    @State private var radial = false

    var body: some View {
        DemoPage(title: "Custom Layout", summary: "The Layout protocol, AnyLayout switching (identity is preserved).") {
            DemoSection(title: "Flow layout") {
                FlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(.teal.opacity(0.2)))
                    }
                }
                HStack {
                    Button("Add tag") { tags.append("tag\(tags.count)") }
                    Button("Remove last") { _ = tags.popLast() }.disabled(tags.isEmpty)
                }
            }
            DemoSection(title: "AnyLayout") {
                Toggle("Radial", isOn: $radial)
                let layout = radial ? AnyLayout(RadialLayout()) : AnyLayout(HStackLayout())
                layout {
                    ForEach(0..<6) { index in
                        Circle().fill(Color(hue: Double(index) / 6, saturation: 0.7, brightness: 0.9)).frame(width: 30, height: 30)
                    }
                }
                .frame(height: 220)
            }
        }
    }
}

// MARK: - Overlays & backgrounds

@Observable
final class BadgeModel {
    var count = 1
    var label = "New"
}

struct OverlayScreen: View {
    @State private var model = BadgeModel()

    var body: some View {
        let _ = UpdateLog.shared.hit("OverlayScreen")
        DemoPage(title: "Overlays & Backgrounds", summary: "Secondary content is sized by the primary view; changing it must not relayout anything else.") {
            DemoSection(title: "Badge overlay") {
                HStack(spacing: 30) {
                    Image(systemName: "envelope").font(.system(size: 36))
                        .overlay(alignment: .topTrailing) { BadgeView(model: model) }
                    Text("Inbox").font(.title2)
                        .overlay(alignment: .bottom) {
                            Rectangle().frame(height: 2).offset(y: 4)
                        }
                }
                .padding()
                HStack {
                    Button("count += 1") { model.count += 1 }
                    Button("count × 100") { model.count *= 100 }
                    Button("reset") { model.count = 1 }
                }
            }
            DemoSection(title: "Backgrounds") {
                Text(model.label)
                    .padding()
                    .background(alignment: .leading) {
                        Capsule().fill(.yellow.opacity(0.4)).frame(width: CGFloat(model.count % 200) + 20)
                    }
                TextField("Label", text: $model.label).frame(width: 200)
            }
            DemoSection(title: "Stacked overlays, borders and clipping") {
                Color.mint
                    .frame(width: 160, height: 90)
                    .overlay { Text("overlay").font(.headline) }
                    .overlay(alignment: .topLeading) { Image(systemName: "star.fill").padding(6) }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary, lineWidth: 2))
            }
        }
    }
}

struct BadgeView: View {
    let model: BadgeModel
    var body: some View {
        let _ = UpdateLog.shared.hit("BadgeView")
        Text("\(model.count)")
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(.red))
            .foregroundStyle(.white)
            .offset(x: 10, y: -8)
    }
}
