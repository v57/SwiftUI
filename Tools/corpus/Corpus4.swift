// API usage corpus, part 4: extension points (custom layouts, styles, transitions, animations).

import Foundation
import Observation
#if canImport(SwiftUI2)
import SwiftUI2
#else
import SwiftUI
#endif

struct Rank: LayoutValueKey { static let defaultValue = 0 }

struct RankedStack: Layout {
    struct Cache { var sizes: [CGSize] = [] }
    static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .vertical
        return properties
    }
    func makeCache(subviews: Subviews) -> Cache { Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) } }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let spacing = subviews.indices.dropFirst().map { subviews[$0 - 1].spacing.distance(to: subviews[$0].spacing, along: .vertical) }.reduce(0, +)
        return CGSize(width: cache.sizes.map(\.width).max() ?? 0, height: cache.sizes.map(\.height).reduce(0, +) + spacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for (index, subview) in subviews.sorted(by: { $0[Rank.self] < $1[Rank.self] }).enumerated() {
            subview.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: .unspecified)
            y += cache.sizes[index].height + (subview.priority > 0 ? 4 : 0)
        }
    }
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
}

extension VerticalAlignment {
    private struct Midline: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let midline = VerticalAlignment(Midline.self)
}

struct Wobble: CustomAnimation {
    let duration: TimeInterval
    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < duration else { return nil }
        return value.scaled(by: time / duration)
    }
}

struct Blur2: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.opacity(phase.isIdentity ? 1 : 0).scaleEffect(phase == .willAppear ? 0.8 : 1)
    }
}

struct Pressable: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onTapGesture { configuration.trigger() }
    }
}

struct FilledToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { HStack { configuration.label; Image(systemName: configuration.isOn ? "checkmark.square" : "square") } }
    }
}

struct CardBox: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading) { configuration.label.font(.headline); configuration.content }.padding().background(.quaternary, in: .rect(cornerRadius: 8))
    }
}

struct RingProgress: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        Circle().trim(from: 0, to: configuration.fractionCompleted ?? 0).stroke(lineWidth: 3)
    }
}

struct Stacked: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View { VStack(alignment: .leading) { configuration.label; configuration.content } }
}

struct Arrow: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack { Button { configuration.isExpanded.toggle() } label: { configuration.label }; if configuration.isExpanded { configuration.content } }
    }
}

struct Pulse: Shape {
    var phase: Double
    var animatableData: Double { get { phase } set { phase = newValue } }
    func path(in rect: CGRect) -> Path { Path(ellipseIn: rect.insetBy(dx: phase, dy: phase)) }
}

struct Ring: InsettableShape {
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path { Circle().path(in: rect.insetBy(dx: inset, dy: inset)) }
    func inset(by amount: CGFloat) -> Ring { Ring(inset: inset + amount) }
}

struct Stripe: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.colorScheme == .dark ? Color.white : Color.black
    }
}

struct Counter: View, Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text("\(Int(value))") }
}

struct Clock: DynamicProperty {
    @State private var start = Date()
    var elapsed: TimeInterval { Date().timeIntervalSince(start) }
    mutating func update() {}
}

struct HighlightKey: TransactionKey { static let defaultValue = false }
extension Transaction {
    var highlight: Bool {
        get { self[HighlightKey.self] }
        set { self[HighlightKey.self] = newValue }
    }
}

struct BoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

@Observable final class Todo: Identifiable {
    var title: String
    var done = false
    @ObservationIgnored var cache = 0
    init(title: String) { self.title = title }
}

struct CorpusExtensionPoints: View {
    @State private var todos = [Todo(title: "One"), Todo(title: "Two")]
    @State private var names = ["a", "b"]
    @State private var optional: String? = "x"
    @State private var shown = true
    @State private var phase = 0.0
    private var clock = Clock()
    @Environment(\.self) private var environment

    var body: some View {
        VStack {
            RankedStack {
                Text("Second").layoutValue(key: Rank.self, value: 2)
                Text("First").layoutValue(key: Rank.self, value: 1).layoutPriority(1)
            }
            HStack(alignment: .midline) {
                Text("A").alignmentGuide(.midline) { $0[.bottom] }
                Text("B")
            }
            ForEach($names, id: \.self) { $name in TextField("Name", text: $name) }
            ForEach(todos) { todo in
                @Bindable var todo = todo
                Toggle(todo.title, isOn: $todo.done).toggleStyle(FilledToggle())
            }
            if let binding = Binding($optional) { TextField("Optional", text: binding) }
            if shown {
                Text("Transition").transition(Blur2())
                Text("Modifier").transition(.modifier(active: _OpacityTransitionModifier(opacity: 0), identity: _OpacityTransitionModifier(opacity: 1)))
            }
            Button("Animate") {
                withAnimation(Animation(Wobble(duration: 0.3))) { shown.toggle() }
                var transaction = Transaction(animation: .easeIn)
                transaction.highlight = true
                withTransaction(transaction) { phase += 1 }
                withTransaction(\.highlight, true) { phase += 1 }
            }
            .buttonStyle(Pressable())
            Counter(value: phase).animation(.default, value: phase)
            Pulse(phase: phase).stroke(Stripe(), lineWidth: 2)
            Ring().strokeBorder(.blue, lineWidth: 2)
            GroupBox("Box") { Text("Inside") }.groupBoxStyle(CardBox())
            ProgressView(value: 0.4).progressViewStyle(RingProgress())
            LabeledContent("Key", value: "Value").labeledContentStyle(Stacked())
            DisclosureGroup("More") { Text("Hidden") }.disclosureGroupStyle(Arrow())
            Text("Anchor").anchorPreference(key: BoundsKey.self, value: .bounds) { $0 }
            Text("\(clock.elapsed)")
            AnyView(erasing: Text("Erased"))
        }
        .overlayPreferenceValue(BoundsKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor { Rectangle().stroke().frame(width: proxy[anchor].width, height: proxy[anchor].height).offset(x: proxy[anchor].minX, y: proxy[anchor].minY) }
            }
        }
        .transaction(value: phase) { $0.animation = .linear }
        .transformEnvironment(\.font) { $0 = $0 ?? .body }
        .id(shown)
    }
}

struct _OpacityTransitionModifier: ViewModifier {
    let opacity: Double
    func body(content: Content) -> some View { content.opacity(opacity) }
}
