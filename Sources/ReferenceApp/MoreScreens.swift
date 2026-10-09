#if SWIFTUI2
import SwiftUI2
#else
import SwiftUI
#endif

// MARK: - Gestures & drawing

struct GesturesScreen: View {
    @State private var offset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @State private var taps = 0
    @State private var longPressed = false
    @State private var hovering = false

    var body: some View {
        DemoPage(title: "Gestures & Canvas", summary: "Drag, tap, long press, hover; immediate-mode drawing with Canvas; TimelineView.") {
            DemoSection(title: "DragGesture + @GestureState") {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 140)
                    Circle()
                        .fill(dragOffset == .zero ? Color.blue : Color.orange)
                        .frame(width: 44, height: 44)
                        .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                        .gesture(
                            DragGesture()
                                .updating($dragOffset) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    offset.width += value.translation.width
                                    offset.height += value.translation.height
                                }
                        )
                }
                Button("Reset position") { withAnimation(.spring) { offset = .zero } }
            }
            DemoSection(title: "Tap, long press, hover") {
                HStack(spacing: 16) {
                    Text("Tapped \(taps)×")
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.blue.opacity(0.2)))
                        .onTapGesture(count: 2) { taps += 2 }
                        .onTapGesture { taps += 1 }
                    Text(longPressed ? "Long pressed!" : "Long press me")
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.green.opacity(0.2)))
                        .onLongPressGesture { longPressed.toggle() }
                    Text(hovering ? "Hovering" : "Hover me")
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? .pink.opacity(0.4) : .pink.opacity(0.15)))
                        .onHover { hovering = $0 }
                }
            }
            DemoSection(title: "Canvas") {
                Canvas { context, size in
                    for index in 0..<12 {
                        let x = CGFloat(index) / 12 * size.width
                        let rect = CGRect(x: x + 2, y: size.height * 0.2, width: size.width / 12 - 4, height: size.height * 0.6)
                        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(hue: Double(index) / 12, saturation: 0.6, brightness: 0.9)))
                    }
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: size.height / 2))
                    line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(line, with: .color(.white), lineWidth: 2)
                }
                .frame(height: 80)
            }
            DemoSection(title: "TimelineView") {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, style: .time).font(.title2.monospacedDigit())
                }
            }
        }
    }
}

// MARK: - Tables, grids, scrolling

struct Planet: Identifiable {
    let id: Int
    let name: String
    let moons: Int
    let distance: Double
}

struct DataScreen: View {
    @State private var selection: Planet.ID?
    private let planets = [
        Planet(id: 1, name: "Mercury", moons: 0, distance: 0.39),
        Planet(id: 2, name: "Venus", moons: 0, distance: 0.72),
        Planet(id: 3, name: "Earth", moons: 1, distance: 1.0),
        Planet(id: 4, name: "Mars", moons: 2, distance: 1.52),
        Planet(id: 5, name: "Jupiter", moons: 95, distance: 5.2),
        Planet(id: 6, name: "Saturn", moons: 146, distance: 9.54),
    ]

    var body: some View {
        DemoPage(title: "Tables & Grids", summary: "Table with selection, LazyVGrid, ScrollViewReader.") {
            DemoSection(title: "Table") {
                Table(planets, selection: $selection) {
                    TableColumn("Planet", value: \.name)
                    TableColumn("Moons") { Text("\($0.moons)") }
                    TableColumn("Distance (AU)") { Text($0.distance, format: .number.precision(.fractionLength(2))) }
                }
                .frame(height: 220)
                Text("Selected: \(planets.first { $0.id == selection }?.name ?? "none")").font(.caption)
            }
            DemoSection(title: "LazyVGrid (adaptive)") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 8) {
                    ForEach(0..<24, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hue: Double(index) / 24, saturation: 0.5, brightness: 0.85))
                            .frame(height: 44)
                            .overlay(Text("\(index)").foregroundStyle(.white))
                    }
                }
            }
            DemoSection(title: "ScrollViewReader") {
                ScrollViewReader { proxy in
                    HStack {
                        Button("Top") { withAnimation { proxy.scrollTo(0, anchor: .top) } }
                        Button("Row 50") { withAnimation { proxy.scrollTo(50, anchor: .top) } }
                        Button("Bottom") { withAnimation { proxy.scrollTo(99, anchor: .bottom) } }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<100, id: \.self) { index in
                                Text("Scroll row \(index)").id(index)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(height: 160)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            }
        }
    }
}
