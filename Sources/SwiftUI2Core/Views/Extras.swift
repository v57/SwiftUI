import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - TimelineView

public struct TimelineViewDefaultContext {
    public let date: Date
    public let cadence: Cadence
    public enum Cadence: Comparable, Sendable { case live, seconds, minutes }
}

@MainActor @preconcurrency
public protocol TimelineSchedule {
    /// Seconds between updates (nil: no periodic updates).
    var _interval: Double? { get }
}

public struct PeriodicTimelineSchedule: TimelineSchedule {
    let interval: Double
    public var _interval: Double? { interval }
}

public struct EveryMinuteTimelineSchedule: TimelineSchedule {
    public var _interval: Double? { 60 }
}

public struct AnimationTimelineSchedule: TimelineSchedule {
    let minimumInterval: Double?
    let paused: Bool
    public var _interval: Double? { paused ? nil : max(minimumInterval ?? 1.0 / 60, 1.0 / 120) }
}

public struct ExplicitTimelineSchedule: TimelineSchedule {
    public var _interval: Double? { nil }
}

extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    public static func periodic(from startDate: Date, by interval: Double) -> PeriodicTimelineSchedule { PeriodicTimelineSchedule(interval: interval) }
}

extension TimelineSchedule where Self == EveryMinuteTimelineSchedule {
    public static var everyMinute: EveryMinuteTimelineSchedule { EveryMinuteTimelineSchedule() }
}

extension TimelineSchedule where Self == AnimationTimelineSchedule {
    public static var animation: AnimationTimelineSchedule { AnimationTimelineSchedule(minimumInterval: nil, paused: false) }
    public static func animation(minimumInterval: Double? = nil, paused: Bool = false) -> AnimationTimelineSchedule {
        AnimationTimelineSchedule(minimumInterval: minimumInterval, paused: paused)
    }
}

extension TimelineSchedule where Self == ExplicitTimelineSchedule {
    public static func explicit<S: Sequence>(_ dates: S) -> ExplicitTimelineSchedule where S.Element == Date { ExplicitTimelineSchedule() }
}

/// Re-evaluates its content on a schedule (a timer drives a date source attribute).
public struct TimelineView<Schedule: TimelineSchedule, Content: View>: View {
    let schedule: Schedule
    let content: (TimelineViewDefaultContext) -> Content

    public init(_ schedule: Schedule, @ViewBuilder content: @escaping (TimelineViewDefaultContext) -> Content) {
        self.schedule = schedule
        self.content = content
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "TimelineView")
        let date = Attribute<Date>(inputs.subgraph, value: Date(), isEqual: { $0 == $1 })
        let interval = AnyAttribute.withoutDependencies { view.attribute.value.schedule._interval }
        if let interval {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak date] _ in
                MainActor.assumeIsolated { date?.setValue(Date()) }
            }
            RunLoop.main.add(timer, forMode: .common)
            inputs.subgraph.onDestroy { timer.invalidate() }
        }
        let content = makeObservedAttribute(inputs.subgraph, of: Content.self) {
            let timeline = view.attribute.value
            let cadence: TimelineViewDefaultContext.Cadence = (interval ?? 60) < 1 ? .live : (interval ?? 60) < 60 ? .seconds : .minutes
            return timeline.content(TimelineViewDefaultContext(date: date.value, cadence: cadence))
        }
        return Content._makeView(view: _GraphValue(content), inputs: inputs)
    }
}

// MARK: - Canvas

/// Immediate-mode drawing recorded as commands and replayed by the backend.
@MainActor
public struct GraphicsContext {
    public enum Shading {
        case color(Color)
        case style(AnyShapeStyle)

        public static func linearGradient(_ gradient: Gradient, startPoint: CGPoint, endPoint: CGPoint) -> Shading {
            .style(AnyShapeStyle(LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom)))
        }
    }

    let recorder: DrawingRecorder
    var transform = CGAffineTransform.identity
    public var opacity: Double = 1
    let environment: EnvironmentValues

    public mutating func translateBy(x: CGFloat, y: CGFloat) { transform = transform.translatedBy(x: x, y: y) }
    public mutating func scaleBy(x: CGFloat, y: CGFloat) { transform = transform.scaledBy(x: x, y: y) }
    public mutating func rotate(by angle: Angle) { transform = transform.rotated(by: CGFloat(angle.radians)) }

    private func paint(_ shading: Shading) -> ResolvedPaint {
        switch shading {
        case .color(let color):
            var resolved = color.resolve(in: environment)
            resolved.opacity *= Float(opacity)
            return .color(resolved)
        case .style(let style):
            return style._resolvePaint(in: environment)
        }
    }

    public func fill(_ path: Path, with shading: Shading, style: FillStyle = FillStyle()) {
        recorder.commands.append(.fill(path.applying(transform), paint(shading)))
    }

    public func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {
        recorder.commands.append(.stroke(path.applying(transform), paint(shading), StrokeStyle(lineWidth: lineWidth)))
    }

    public func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        recorder.commands.append(.stroke(path.applying(transform), paint(shading), style))
    }

    public func draw(_ text: Text, at point: CGPoint, anchor: UnitPoint = .center) {
        recorder.commands.append(.text(text.resolve(in: environment), point.applying(transform), anchor))
    }
}

@MainActor
final class DrawingRecorder {
    var commands: [DrawCommand] = []
}

public enum DrawCommand: Equatable, Sendable {
    case fill(Path, ResolvedPaint)
    case stroke(Path, ResolvedPaint, StrokeStyle)
    case text(ResolvedText, CGPoint, UnitPoint)
}

public struct Canvas<Symbols: View>: View {
    let renderer: (inout GraphicsContext, CGSize) -> Void

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "Canvas")
        let geometry = inputs.geometry
        let environment = inputs.environment
        let content = makeObservedAttribute(inputs.subgraph, of: RenderContent.self, isEqual: { $0 == $1 }) {
            let recorder = DrawingRecorder()
            var context = GraphicsContext(recorder: recorder, environment: environment.value)
            view.attribute.value.renderer(&context, geometry.value.size)
            return .drawing(recorder.commands)
        }
        inputs.makePlatformNode(content: content)
        let tracer = inputs.tracer
        let path = inputs.path
        return _ViewOutputs(layout: inputs.makeLayoutAttribute { FlexibleLayoutComputer(path: path, tracer: tracer) })
    }
}

extension Canvas where Symbols == EmptyView {
    public init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear, rendersAsynchronously: Bool = false, renderer: @escaping (inout GraphicsContext, CGSize) -> Void) {
        self.renderer = renderer
    }
}

public enum ColorRenderingMode: Sendable { case nonLinear, linear, extendedLinear }

// MARK: - Misc containers

public struct ControlGroup<Content: View>: View {
    let content: Content
    let label: AnyView
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.label = AnyView(EmptyView())
    }
    public init<L: View>(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> L) {
        self.content = content()
        self.label = AnyView(label())
    }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.label = AnyView(Label(title, systemImage: systemImage))
    }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.label = AnyView(Text(title))
    }
    init(_content: Content, label: some View) {
        self.content = _content
        self.label = AnyView(label)
    }
    public var body: some View {
        _StyledView(configuration: ControlGroupStyleConfiguration(content: _StyleContent(content), label: _StyleContent(label))) {
            AnyView(AutomaticControlGroupStyle().makeBody(configuration: $0))
        }
    }
}

public struct OutlineGroup<Data: RandomAccessCollection, ID: Hashable, Leaf: View>: View where Data.Element: Identifiable, Data.Element.ID == ID {
    let data: Data
    let children: KeyPath<Data.Element, Data?>
    let content: (Data.Element) -> Leaf

    public init(_ data: Data, children: KeyPath<Data.Element, Data?>, @ViewBuilder content: @escaping (Data.Element) -> Leaf) {
        self.data = data
        self.children = children
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(data) { element in
                if let nested = element[keyPath: children] {
                    DisclosureGroup {
                        OutlineGroup(nested, children: children, content: content)
                    } label: {
                        content(element)
                    }
                } else {
                    content(element)
                }
            }
        }
    }
}

/// Compares the wrapped view with `==` to decide whether its body must run again.
public struct EquatableView<Content: View & Equatable>: View {
    public var content: Content
    public init(content: Content) { self.content = content }
    public var body: some View { content }
}

extension EquatableView: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: EquatableView, _ rhs: EquatableView) -> Bool {
        MainActor.assumeIsolated { lhs.content == rhs.content }
    }
}

extension View where Self: Equatable {
    public func equatable() -> EquatableView<Self> { EquatableView(content: self) }
}

// MARK: - Modifiers

extension View {
    public func safeAreaInset<V: View>(edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> some View {
        let inset = content()
        return VStack(alignment: alignment, spacing: spacing ?? 0) {
            if edge == .top { inset }
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
            if edge == .bottom { inset }
        }
    }

    public func safeAreaInset<V: View>(edge: HorizontalEdge, alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> some View {
        let inset = content()
        return HStack(alignment: alignment, spacing: spacing ?? 0) {
            if edge == .leading { inset }
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
            if edge == .trailing { inset }
        }
    }

    public func safeAreaPadding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View { padding(edges, length) }
    public func safeAreaPadding(_ length: CGFloat) -> some View { padding(.all, length) }
    public func safeAreaPadding(_ insets: EdgeInsets) -> some View { padding(insets) }

    /// Masks with a shape (alpha masks of arbitrary views need compositing support and are ignored).
    public func mask<M: View>(alignment: Alignment = .center, @ViewBuilder _ mask: () -> M) -> some View {
        modifier(_MaskModifier(mask: mask(), alignment: alignment))
    }

    public func mask<M: View>(_ mask: M) -> some View {
        modifier(_MaskModifier(mask: mask, alignment: .center))
    }

    public func onReceive<P: Publisher>(_ publisher: P, perform action: @escaping @MainActor (P.Output) -> Void) -> some View where P.Failure == Never {
        modifier(_ReceiveModifier(publisher: publisher, action: action))
    }

    public func phaseAnimator<Phase: Equatable, V: View>(_ phases: some Sequence<Phase>, @ViewBuilder content: @escaping (PlaceholderContentView<Self>, Phase) -> V, animation: @escaping (Phase) -> Animation? = { _ in .default }) -> some View {
        _PhaseAnimatorView(base: self, phases: Array(phases), trigger: 0, loops: true, content: content, animation: animation)
    }

    public func phaseAnimator<Phase: Equatable, V: View, T: Equatable>(_ phases: some Sequence<Phase>, trigger: T, @ViewBuilder content: @escaping (PlaceholderContentView<Self>, Phase) -> V, animation: @escaping (Phase) -> Animation? = { _ in .default }) -> some View {
        _PhaseAnimatorView(base: self, phases: Array(phases), trigger: trigger, loops: false, content: content, animation: animation)
    }

    // Blur needs a platform blur filter (excluded from this implementation, like shaders).
    public func blur(radius: CGFloat, opaque: Bool = false) -> some View { self }
    public func contentTransition(_ transition: ContentTransition) -> some View { environment(\.contentTransition, transition) }
    public func dynamicTypeSize<T>(_ size: T) -> some View { self }
    public func monospaced(_ isActive: Bool = true) -> some View {
        transformEnvironment(\.font) { font in if isActive { font = (font ?? .body).monospaced() } }
    }
    public func monospacedDigit() -> some View {
        transformEnvironment(\.font) { font in font = (font ?? .body).monospacedDigit() }
    }
}

public enum HorizontalEdge: Int8, Hashable, Sendable { case leading, trailing }
public enum BlendMode: Hashable, Sendable { case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight, difference, exclusion, hue, saturation, color, luminosity, sourceAtop, destinationOver, destinationOut, plusDarker, plusLighter }
/// How a view's content animates when it changes in an animated transaction (text and images).
public struct ContentTransition: Hashable, Sendable {
    public enum _Kind: Hashable, Sendable {
        case identity, opacity, interpolate
        case numericText(countsDown: Bool)
        case symbolEffect(_SymbolEffectValue?)
    }
    public let _kind: _Kind

    public static let identity = ContentTransition(_kind: .identity)
    public static let opacity = ContentTransition(_kind: .opacity)
    public static let interpolate = ContentTransition(_kind: .interpolate)
    public static func numericText(countsDown: Bool = false) -> ContentTransition { ContentTransition(_kind: .numericText(countsDown: countsDown)) }
    public static func numericText(value: Double) -> ContentTransition { ContentTransition(_kind: .numericText(countsDown: false)) }
    public static let symbolEffect = ContentTransition(_kind: .symbolEffect(nil))
    public static func symbolEffect<E: SymbolEffect>(_ effect: E, options: SymbolEffectOptions = .default) -> ContentTransition {
        ContentTransition(_kind: .symbolEffect(effect as? _SymbolEffectValue))
    }
}

struct ContentTransitionKey: EnvironmentKey { static let defaultValue = ContentTransition.interpolate }

extension EnvironmentValues {
    /// Default `.interpolate` (text crossfades; symbols replace).
    public var contentTransition: ContentTransition {
        get { self[ContentTransitionKey.self] }
        set { self[ContentTransitionKey.self] = newValue }
    }
    public var contentTransitionAddsDrawingGroup: Bool {
        get { false }
        set {}
    }
}

public struct RedactionReasons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let placeholder = RedactionReasons(rawValue: 1)
    public static let privacy = RedactionReasons(rawValue: 2)
    public static let invalidated = RedactionReasons(rawValue: 4)
}

/// `.mask { ... }`: the content is shown through the mask's alpha. The mask is laid out like an
/// overlay; shapes become a clip path, other views a platform alpha mask.
public struct _MaskModifier<Mask: View>: ViewModifier {
    let mask: Mask
    let alignment: Alignment
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        if Mask.self is any Shape.Type {
            let clip = modifier.project(inputs) { modifier -> _ClipEffect<AnyShape> in
                let shape = modifier.mask as! any Shape
                return _ClipEffect(shape: AnyShape(shape))
            }
            return _ClipEffect<AnyShape>._makeView(modifier: clip, inputs: inputs, body: body)
        }
        let inputs = inputs.with(path: "mask")
        let content = inputs.constant(RenderContent.effect(.mask))
        let render = inputs.makePlatformNode(content: content, actions: RenderActions())
        var maskedInputs = inputs
        maskedInputs.render = render
        let source = modifier.project(inputs) { ModifiedContent(content: $0.mask, modifier: _MaskSourceEffect()) }
        let alignment = Attribute<Alignment>(inputs.subgraph, isEqual: { $0 == $1 }) { modifier.attribute.value.alignment }
        return makeSecondaryLayer(secondary: source, alignment: alignment, placement: .above, inputs: maskedInputs, body: body)
    }
}

struct _MaskSourceEffect: PlatformEffectModifier {
    static var pathComponent: String { "maskSource" }
    func effect(size: CGSize) -> DisplayEffect { .maskSource }
}

public struct _ReceiveModifier<P: Publisher>: ViewModifier where P.Failure == Never {
    let publisher: P
    let action: @MainActor (P.Output) -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let source = modifier.attribute
        let host = inputs.host
        let publisher = AnyAttribute.withoutDependencies { source.value.publisher }
        let cancellable = publisher.sink { [weak source] output in
            let deliver: @MainActor () -> Void = {
                guard let source else { return }
                AnyAttribute.withoutDependencies { source.value.action(output) }
                host.onNeedsUpdate?()
            }
            if Thread.isMainThread { MainActor.assumeIsolated(deliver) } else { DispatchQueue.main.async { MainActor.assumeIsolated(deliver) } }
        }
        inputs.subgraph.onDestroy { cancellable.cancel() }
        return body(inputs)
    }
}

/// The view a phase animator's content closure receives.
/// Stand-in for the modified view in `phaseAnimator` / `Transition` bodies.
public struct PlaceholderContentView<Value>: View {
    let content: AnyView
    init(content: some View) { self.content = AnyView(content) }
    public var body: some View { content }
}

struct _PhaseAnimatorView<Base: View, Phase: Equatable, Content: View, Trigger: Equatable>: View {
    let base: Base
    let phases: [Phase]
    let trigger: Trigger
    let loops: Bool
    let content: (PlaceholderContentView<Base>, Phase) -> Content
    let animation: (Phase) -> Animation?
    @State private var index = 0

    var body: some View {
        content(PlaceholderContentView(content: base), phases[min(index, phases.count - 1)])
            .task(id: trigger) {
                guard phases.count > 1 else { return }
                var first = true
                repeat {
                    for next in 1...phases.count {
                        if !loops && !first && next == phases.count { break }
                        let target = next % phases.count
                        let animation = animation(phases[target])
                        withAnimation(animation) { index = target }
                        let duration = animation.map { $0.duration / $0.speed + $0.delay } ?? 0.35
                        try? await Task.sleep(for: .seconds(duration))
                        if Task.isCancelled { return }
                        if !loops && target == 0 { return }
                    }
                    first = false
                } while loops && !Task.isCancelled
            }
    }
}

// MARK: - Storage property wrappers

/// `@AppStorage`: a value persisted in `UserDefaults`, observed for external changes.
@propertyWrapper
public struct AppStorage<Value>: DynamicProperty {
    let key: String
    let defaultValue: Value
    /// The explicit `store:`, else the environment's `defaultAppStorage` (standard by default).
    var store: UserDefaults
    let hasExplicitStore: Bool
    let read: (UserDefaults, String) -> Value?
    let write: (UserDefaults, String, Value) -> Void
    var location: StoredLocation<Value>?

    public var wrappedValue: Value {
        get { location?.get() ?? read(store, key) ?? defaultValue }
        nonmutating set {
            write(store, key, newValue)
            location?.set(newValue, transaction: Transaction.current)
        }
    }

    public var projectedValue: Binding<Value> {
        let current = self
        return Binding(get: { current.wrappedValue }, set: { current.wrappedValue = $0 })
    }
}

extension AppStorage {
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Bool { self.init(key, wrappedValue, store) { $0.object(forKey: $1) as? Bool } }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Int { self.init(key, wrappedValue, store) { $0.object(forKey: $1) as? Int } }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Double { self.init(key, wrappedValue, store) { $0.object(forKey: $1) as? Double } }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == String { self.init(key, wrappedValue, store) { $0.string(forKey: $1) } }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == URL { self.init(key, wrappedValue, store) { $0.url(forKey: $1) } }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Data { self.init(key, wrappedValue, store) { $0.data(forKey: $1) } }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value: RawRepresentable, Value.RawValue == String {
        self.init(key: key, defaultValue: wrappedValue, store: store,
                  read: { ($0.string(forKey: $1)).flatMap(Value.init(rawValue:)) },
                  write: { $0.set($2.rawValue, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value: RawRepresentable, Value.RawValue == Int {
        self.init(key: key, defaultValue: wrappedValue, store: store,
                  read: { ($0.object(forKey: $1) as? Int).flatMap(Value.init(rawValue:)) },
                  write: { $0.set($2.rawValue, forKey: $1) })
    }

    init(_ key: String, _ defaultValue: Value, _ store: UserDefaults?, read: @escaping (UserDefaults, String) -> Value?) {
        self.init(key: key, defaultValue: defaultValue, store: store, read: read, write: { $0.set($2, forKey: $1) })
    }

    init(key: String, defaultValue: Value, store: UserDefaults?, read: @escaping (UserDefaults, String) -> Value?, write: @escaping (UserDefaults, String, Value) -> Void) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store ?? .standard
        self.hasExplicitStore = store != nil
        self.read = read
        self.write = write
    }
}

@MainActor
final class AppStorageBox<Value> {
    let location: StoredLocation<Value>
    var store = UserDefaults.standard
    var observer: NSObjectProtocol?
    init(location: StoredLocation<Value>) { self.location = location }
}

struct DefaultAppStorageKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: UserDefaults? = nil }

extension EnvironmentValues {
    var _defaultAppStorage: UserDefaults? {
        get { self[DefaultAppStorageKey.self] }
        set { self[DefaultAppStorageKey.self] = newValue }
    }
}

extension View {
    /// The store `@AppStorage` uses in this view hierarchy when no `store:` is given.
    public func defaultAppStorage(_ store: UserDefaults) -> some View {
        environment(\._defaultAppStorage, store)
    }
}

extension AppStorage: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        if let box = slot as? AppStorageBox<Value> {
            location = box.location
            store = box.store
            return
        }
        if !hasExplicitStore, let environmentStore = AnyAttribute.withoutDependencies({ context.environment.value._defaultAppStorage }) {
            store = environmentStore
        }
        let attribute = Attribute<Value>(context.subgraph, value: read(store, key) ?? defaultValue)
        let box = AppStorageBox(location: StoredLocation(attribute: attribute))
        box.store = store
        let captured = UncheckedSendable((store: store, key: key, read: read, defaultValue: defaultValue))
        box.observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: store, queue: .main) { [weak attribute] _ in
            MainActor.assumeIsolated {
                let c = captured.value
                attribute?.setValue(c.read(c.store, c.key) ?? c.defaultValue)
            }
        }
        let observer = box.observer
        context.subgraph.onDestroy { if let observer { NotificationCenter.default.removeObserver(observer) } }
        slot = box
        location = box.location
    }
}

extension AppStorage: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: AppStorage, _ rhs: AppStorage) -> Bool { lhs.key == rhs.key }
}

/// `@SceneStorage`: per-scene state restoration; kept in memory for the process lifetime.
@propertyWrapper
public struct SceneStorage<Value>: DynamicProperty {
    let key: String
    let defaultValue: Value
    var location: StoredLocation<Value>?

    public init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.defaultValue = wrappedValue
    }

    public var wrappedValue: Value {
        get { location?.get() ?? (SceneStorageValues.values[key] as? Value) ?? defaultValue }
        nonmutating set {
            SceneStorageValues.values[key] = newValue
            location?.set(newValue, transaction: Transaction.current)
        }
    }

    public var projectedValue: Binding<Value> {
        let current = self
        return Binding(get: { current.wrappedValue }, set: { current.wrappedValue = $0 })
    }
}

enum SceneStorageValues {
    nonisolated(unsafe) static var values: [String: Any] = [:]
}

extension SceneStorage: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        if let existing = slot as? StoredLocation<Value> {
            location = existing
            return
        }
        let created = StoredLocation(attribute: Attribute(context.subgraph, value: (SceneStorageValues.values[key] as? Value) ?? defaultValue))
        slot = created
        location = created
    }
}

extension SceneStorage: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: SceneStorage, _ rhs: SceneStorage) -> Bool { lhs.key == rhs.key }
}

// MARK: - More environment values

public enum UserInterfaceSizeClass: Hashable, Sendable { case compact, regular }
public enum ScenePhase: Hashable, Sendable { case background, inactive, active }

struct LocaleKey: EnvironmentKey { static let defaultValue = Locale.current }
struct CalendarKey: EnvironmentKey { static let defaultValue = Calendar.current }
struct TimeZoneKey: EnvironmentKey { static let defaultValue = TimeZone.current }
struct HorizontalSizeClassKey: EnvironmentKey { static let defaultValue: UserInterfaceSizeClass? = .regular }
struct VerticalSizeClassKey: EnvironmentKey { static let defaultValue: UserInterfaceSizeClass? = .regular }
struct ScenePhaseKey: EnvironmentKey { static let defaultValue = ScenePhase.active }

extension EnvironmentValues {
    public var locale: Locale {
        get { self[LocaleKey.self] }
        set { self[LocaleKey.self] = newValue }
    }
    public var calendar: Calendar {
        get { self[CalendarKey.self] }
        set { self[CalendarKey.self] = newValue }
    }
    public var timeZone: TimeZone {
        get { self[TimeZoneKey.self] }
        set { self[TimeZoneKey.self] = newValue }
    }
    public var horizontalSizeClass: UserInterfaceSizeClass? {
        get { self[HorizontalSizeClassKey.self] }
        set { self[HorizontalSizeClassKey.self] = newValue }
    }
    public var verticalSizeClass: UserInterfaceSizeClass? {
        get { self[VerticalSizeClassKey.self] }
        set { self[VerticalSizeClassKey.self] = newValue }
    }
    public var scenePhase: ScenePhase {
        get { self[ScenePhaseKey.self] }
        set { self[ScenePhaseKey.self] = newValue }
    }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
