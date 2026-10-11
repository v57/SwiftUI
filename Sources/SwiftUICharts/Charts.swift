import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import _SwiftUICore

// A Swift Charts subset for SwiftUI: line / area / bar / point / rule marks with numeric, date or
// categorical values, explicit scales and simple axes, drawn with Canvas.

// MARK: - Values

public protocol Plottable {
    /// The value on a continuous axis (categorical values return nil).
    var _chartNumber: Double? { get }
    var _chartCategory: String { get }
}

extension Plottable {
    public var _chartCategory: String { "\(self)" }
}

extension Int: Plottable { public var _chartNumber: Double? { Double(self) } }
extension Double: Plottable { public var _chartNumber: Double? { self } }
extension Float: Plottable { public var _chartNumber: Double? { Double(self) } }
extension CGFloat: Plottable { public var _chartNumber: Double? { Double(self) } }
extension Date: Plottable { public var _chartNumber: Double? { timeIntervalSinceReferenceDate } }
extension String: Plottable { public var _chartNumber: Double? { nil } }

public struct PlottableValue<Value: Plottable> {
    let label: String
    let value: Value

    public static func value(_ label: String, _ value: Value) -> PlottableValue { PlottableValue(label: label, value: value) }
    public static func value(_ label: LocalizedStringKey, _ value: Value) -> PlottableValue { PlottableValue(label: Text(label).plainString, value: value) }
}

/// A plotted coordinate: a number on a continuous axis, or a category.
enum ChartCoordinate: Hashable {
    case number(Double)
    case category(String)

    init<V: Plottable>(_ value: V) {
        if let number = value._chartNumber { self = .number(number) } else { self = .category(value._chartCategory) }
    }
}

// MARK: - Marks

public enum InterpolationMethod: Sendable {
    case linear, catmullRom, cardinal, monotone, stepStart, stepCenter, stepEnd
    public static func cardinal(tension: Double) -> InterpolationMethod { .cardinal }
    public static func catmullRom(alpha: Double) -> InterpolationMethod { .catmullRom }
}

/// One mark (opaque outside the module).
@MainActor
public struct ChartMark {
    enum Kind { case line, area, bar, point, rule }
    var kind: Kind
    var x: ChartCoordinate?
    var y: ChartCoordinate?
    var yStart: ChartCoordinate?
    var series: String = ""
    var style: AnyShapeStyle?
    var interpolation: InterpolationMethod = .linear
    var lineWidth: CGFloat = 2
    var opacity: Double = 1
}

@MainActor @preconcurrency
public protocol ChartContent {
    func _marks(into marks: inout [ChartMark])
}

/// Shared mark modifiers.
@MainActor
public protocol _ChartMarkContent: ChartContent {
    var mark: ChartMark { get set }
}

extension _ChartMarkContent {
    public func _marks(into marks: inout [ChartMark]) { marks.append(mark) }

    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> Self {
        var copy = self
        copy.mark.style = AnyShapeStyle(style)
        return copy
    }

    public func foregroundStyle<V: Plottable>(by value: PlottableValue<V>) -> Self {
        var copy = self
        copy.mark.series = value.value._chartCategory
        return copy
    }

    public func interpolationMethod(_ method: InterpolationMethod) -> Self {
        var copy = self
        copy.mark.interpolation = method
        return copy
    }

    public func lineStyle(_ style: StrokeStyle) -> Self {
        var copy = self
        copy.mark.lineWidth = style.lineWidth
        return copy
    }

    public func opacity(_ value: Double) -> Self {
        var copy = self
        copy.mark.opacity = value
        return copy
    }

    public func symbol<S>(_ symbol: S) -> Self { self }
    public func symbolSize(_ size: CGFloat) -> Self { self }
    public func annotation<C: View>(position: AnnotationPosition = .automatic, alignment: Alignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> C) -> Self { self }
    public func cornerRadius(_ radius: CGFloat) -> Self { self }
}

public enum AnnotationPosition: Sendable { case automatic, top, bottom, leading, trailing, overlay }

public struct LineMark: _ChartMarkContent {
    public var mark: ChartMark
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>) {
        mark = ChartMark(kind: .line, x: ChartCoordinate(x.value), y: ChartCoordinate(y.value))
    }
    public init<X: Plottable, Y: Plottable, S: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, series: PlottableValue<S>) {
        mark = ChartMark(kind: .line, x: ChartCoordinate(x.value), y: ChartCoordinate(y.value), series: series.value._chartCategory)
    }
}

public struct AreaMark: _ChartMarkContent {
    public var mark: ChartMark
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>) {
        mark = ChartMark(kind: .area, x: ChartCoordinate(x.value), y: ChartCoordinate(y.value))
    }
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, yStart: PlottableValue<Y>, yEnd: PlottableValue<Y>) {
        mark = ChartMark(kind: .area, x: ChartCoordinate(x.value), y: ChartCoordinate(yEnd.value), yStart: ChartCoordinate(yStart.value))
    }
}

public struct BarMark: _ChartMarkContent {
    public var mark: ChartMark
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>) {
        mark = ChartMark(kind: .bar, x: ChartCoordinate(x.value), y: ChartCoordinate(y.value))
    }
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, width: MarkDimension) {
        mark = ChartMark(kind: .bar, x: ChartCoordinate(x.value), y: ChartCoordinate(y.value))
    }
}

public struct PointMark: _ChartMarkContent {
    public var mark: ChartMark
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>) {
        mark = ChartMark(kind: .point, x: ChartCoordinate(x.value), y: ChartCoordinate(y.value))
    }
}

public struct RuleMark: _ChartMarkContent {
    public var mark: ChartMark
    public init<Y: Plottable>(y: PlottableValue<Y>) {
        mark = ChartMark(kind: .rule, x: nil, y: ChartCoordinate(y.value))
    }
    public init<X: Plottable>(x: PlottableValue<X>) {
        mark = ChartMark(kind: .rule, x: ChartCoordinate(x.value), y: nil)
    }
}

public struct MarkDimension: Sendable {
    public static func fixed(_ value: CGFloat) -> MarkDimension { MarkDimension() }
    public static func ratio(_ value: CGFloat) -> MarkDimension { MarkDimension() }
    public static var automatic: MarkDimension { MarkDimension() }
}

public struct _TupleChartContent: ChartContent {
    let parts: [@MainActor (inout [ChartMark]) -> Void]
    public func _marks(into marks: inout [ChartMark]) { for part in parts { part(&marks) } }
}

public struct _EmptyChartContent: ChartContent {
    public func _marks(into marks: inout [ChartMark]) {}
}

extension Optional: ChartContent where Wrapped: ChartContent {
    public func _marks(into marks: inout [ChartMark]) { self?._marks(into: &marks) }
}

extension _ConditionalContent: ChartContent where TrueContent: ChartContent, FalseContent: ChartContent {
    public func _marks(into marks: inout [ChartMark]) {
        switch storage {
        case .trueContent(let content): content._marks(into: &marks)
        case .falseContent(let content): content._marks(into: &marks)
        }
    }
}

extension ForEach: ChartContent where Content: ChartContent {
    public func _marks(into marks: inout [ChartMark]) {
        for element in data { content(element)._marks(into: &marks) }
    }
}

@resultBuilder @MainActor
public enum ChartContentBuilder {
    public static func buildExpression<C: ChartContent>(_ content: C) -> C { content }
    public static func buildBlock() -> _EmptyChartContent { _EmptyChartContent() }
    public static func buildBlock<C: ChartContent>(_ content: C) -> C { content }
    public static func buildBlock<each C: ChartContent>(_ content: repeat each C) -> _TupleChartContent {
        var parts: [@MainActor (inout [ChartMark]) -> Void] = []
        repeat parts.append({ marks in (each content)._marks(into: &marks) })
        return _TupleChartContent(parts: parts)
    }
    public static func buildOptional<C: ChartContent>(_ content: C?) -> C? { content }
    public static func buildEither<T: ChartContent, F: ChartContent>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .trueContent(first)) }
    public static func buildEither<T: ChartContent, F: ChartContent>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .falseContent(second)) }
    public static func buildArray<C: ChartContent>(_ content: [C]) -> _TupleChartContent {
        _TupleChartContent(parts: content.map { item in { marks in item._marks(into: &marks) } })
    }
}

// MARK: - Axes and scales

public enum AxisMarkPosition: Sendable { case automatic, leading, trailing, top, bottom }

public struct AxisMarkValues {
    let explicit: [Double]?
    public static var automatic: AxisMarkValues { AxisMarkValues(explicit: nil) }
    public static func automatic(desiredCount: Int) -> AxisMarkValues { AxisMarkValues(explicit: nil) }
    public static func stride(by step: Double) -> AxisMarkValues { AxisMarkValues(explicit: nil) }
}

public struct AxisMarks: @unchecked Sendable {
    let position: AxisMarkPosition
    let values: [Double]?

    public init(position: AxisMarkPosition = .automatic, values: AxisMarkValues = .automatic) {
        self.position = position
        self.values = values.explicit
    }

    public init<V: Plottable>(position: AxisMarkPosition = .automatic, values: [V]) {
        self.position = position
        self.values = values.compactMap(\._chartNumber)
    }

    public init<C>(position: AxisMarkPosition = .automatic, values: AxisMarkValues = .automatic, @AxisContentBuilder content: (AxisValue) -> C) {
        self.init(position: position, values: values)
    }

    public init<V: Plottable, C>(position: AxisMarkPosition = .automatic, values: [V], @AxisContentBuilder content: (AxisValue) -> C) {
        self.init(position: position, values: values)
    }
}

public struct AxisValue {
    public let index: Int
    public let count: Int
    let number: Double
    public func `as`<V>(_ type: V.Type) -> V? {
        if V.self == Double.self { return number as? V }
        if V.self == Int.self { return Int(number) as? V }
        return nil
    }
}

public struct AxisGridLine { public init(centered: Bool? = nil, stroke: StrokeStyle? = nil) {} }
public struct AxisTick { public init(centered: Bool? = nil, length: CGFloat = 4, stroke: StrokeStyle? = nil) {} }
public struct AxisValueLabel {
    public init() {}
    public init<S: StringProtocol>(_ text: S) {}
    public init<C: View>(@ViewBuilder content: () -> C) {}
    public init<F>(format: F) {}
}

@resultBuilder
public enum AxisContentBuilder {
    public static func buildExpression<T>(_ value: T) -> [AxisMarks] { (value as? AxisMarks).map { [$0] } ?? [] }
    public static func buildBlock(_ parts: [AxisMarks]...) -> [AxisMarks] { parts.flatMap { $0 } }
    public static func buildBlock() -> [AxisMarks] { [] }
    public static func buildOptional(_ parts: [AxisMarks]?) -> [AxisMarks] { parts ?? [] }
    public static func buildEither(first: [AxisMarks]) -> [AxisMarks] { first }
    public static func buildEither(second: [AxisMarks]) -> [AxisMarks] { second }
}

struct ChartAxisConfig: @unchecked Sendable {
    var x: [AxisMarks]? = nil
    var y: [AxisMarks]? = nil
    var xDomain: ClosedRange<Double>? = nil
    var yDomain: ClosedRange<Double>? = nil
}

struct ChartAxisKey: EnvironmentKey { static let defaultValue = ChartAxisConfig() }

extension EnvironmentValues {
    var chartAxis: ChartAxisConfig {
        get { self[ChartAxisKey.self] }
        set { self[ChartAxisKey.self] = newValue }
    }
}

extension View {
    public func chartXAxis(@AxisContentBuilder content: () -> [AxisMarks]) -> some View {
        let marks = content()
        return transformEnvironment(\.chartAxis) { $0.x = marks }
    }

    public func chartYAxis(@AxisContentBuilder content: () -> [AxisMarks]) -> some View {
        let marks = content()
        return transformEnvironment(\.chartAxis) { $0.y = marks }
    }

    public func chartXAxis(_ visibility: Visibility) -> some View {
        transformEnvironment(\.chartAxis) { if visibility == .hidden { $0.x = [] } }
    }

    public func chartYAxis(_ visibility: Visibility) -> some View {
        transformEnvironment(\.chartAxis) { if visibility == .hidden { $0.y = [] } }
    }

    public func chartXScale(domain: ClosedRange<Double>) -> some View {
        transformEnvironment(\.chartAxis) { $0.xDomain = domain }
    }

    public func chartYScale(domain: ClosedRange<Double>) -> some View {
        transformEnvironment(\.chartAxis) { $0.yDomain = domain }
    }

    public func chartXScale(domain: ClosedRange<Int>) -> some View {
        chartXScale(domain: Double(domain.lowerBound)...Double(domain.upperBound))
    }

    public func chartYScale(domain: ClosedRange<Int>) -> some View {
        chartYScale(domain: Double(domain.lowerBound)...Double(domain.upperBound))
    }

    public func chartLegend(_ visibility: Visibility) -> some View { self }
    public func chartPlotStyle<C: View>(content: @escaping (ChartPlotContent) -> C) -> some View { self }
}

public struct ChartPlotContent: View {
    public var body: some View { EmptyView() }
}

// MARK: - Chart

public struct Chart<Content: ChartContent>: View {
    let content: Content
    @Environment(\.chartAxis) private var axis

    public init(@ChartContentBuilder content: () -> Content) {
        self.content = content()
    }

    public init<Data: RandomAccessCollection, C: ChartContent>(_ data: Data, @ChartContentBuilder content: @escaping (Data.Element) -> C) where Content == ForEach<Data, Data.Element.ID, C>, Data.Element: Identifiable {
        self.content = ForEach(_chartData: data, id: \.id, content: content)
    }

    public init<Data: RandomAccessCollection, ID: Hashable, C: ChartContent>(_ data: Data, id: KeyPath<Data.Element, ID>, @ChartContentBuilder content: @escaping (Data.Element) -> C) where Content == ForEach<Data, ID, C> {
        self.content = ForEach(_chartData: data, id: id, content: content)
    }

    public var body: some View {
        var marks: [ChartMark] = []
        content._marks(into: &marks)
        let layout = ChartLayout(marks: marks, axis: axis)
        return Canvas { context, size in
            layout.draw(in: &context, size: size)
        }
        .frame(minHeight: 40)
    }
}

extension ForEach where Content: ChartContent {
    init(_chartData data: Data, id: KeyPath<Data.Element, ID>, content: @escaping (Data.Element) -> Content) {
        self.init(_unchecked: data, id: id, content: content)
    }

    public init(_ data: Data, @ChartContentBuilder content: @escaping (Data.Element) -> Content) where Data.Element: Identifiable, ID == Data.Element.ID {
        self.init(_unchecked: data, id: \.id, content: content)
    }

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ChartContentBuilder content: @escaping (Data.Element) -> Content) {
        self.init(_unchecked: data, id: id, content: content)
    }
}

/// Domains, scales and drawing.
@MainActor
struct ChartLayout {
    let marks: [ChartMark]
    let axis: ChartAxisConfig
    let categories: [String]
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>

    init(marks: [ChartMark], axis: ChartAxisConfig) {
        self.marks = marks
        self.axis = axis
        var categories: [String] = []
        for mark in marks {
            if case .category(let name)? = mark.x, !categories.contains(name) { categories.append(name) }
        }
        self.categories = categories
        func number(_ coordinate: ChartCoordinate?, categories: [String]) -> Double? {
            switch coordinate {
            case .number(let value)?: return value
            case .category(let name)?: return categories.firstIndex(of: name).map(Double.init)
            case nil: return nil
            }
        }
        let xs = marks.compactMap { number($0.x, categories: categories) }
        var ys = marks.compactMap { number($0.y, categories: []) }
        ys += marks.compactMap { number($0.yStart, categories: []) }
        if marks.contains(where: { $0.kind == .bar || $0.kind == .area }) { ys.append(0) }
        let xLow = xs.min() ?? 0, xHigh = xs.max() ?? 1
        let yLow = ys.min() ?? 0, yHigh = ys.max() ?? 1
        xDomain = axis.xDomain ?? (categories.isEmpty ? xLow...(xHigh > xLow ? xHigh : xLow + 1) : -0.5...(Double(categories.count) - 0.5))
        yDomain = axis.yDomain ?? Self.niceDomain(min(yLow, 0)...max(yHigh, yLow + 1))
    }

    static func niceDomain(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        let step = niceStep(range.upperBound - range.lowerBound)
        return (range.lowerBound / step).rounded(.down) * step...(range.upperBound / step).rounded(.up) * step
    }

    static func niceStep(_ span: Double) -> Double {
        guard span > 0 else { return 1 }
        let raw = span / 4
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let nice: Double = normalized < 1.5 ? 1 : normalized < 3 ? 2 : normalized < 7 ? 5 : 10
        return nice * magnitude
    }

    func value(_ coordinate: ChartCoordinate?) -> Double? {
        switch coordinate {
        case .number(let value)?: return value
        case .category(let name)?: return categories.firstIndex(of: name).map(Double.init)
        case nil: return nil
        }
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let yAxis = axis.y ?? [AxisMarks(position: .trailing)]
        let xAxis = axis.x ?? [AxisMarks(position: .bottom)]
        let yLabelWidth: CGFloat = yAxis.isEmpty ? 0 : 34
        let xLabelHeight: CGFloat = xAxis.isEmpty ? 0 : 18
        let trailingLabels = yAxis.contains { $0.position == .trailing || $0.position == .automatic }
        let plot = CGRect(
            x: trailingLabels ? 0 : yLabelWidth, y: 4,
            width: max(1, size.width - yLabelWidth), height: max(1, size.height - xLabelHeight - 4)
        )
        func point(_ x: Double, _ y: Double) -> CGPoint {
            let xSpan = xDomain.upperBound - xDomain.lowerBound
            let ySpan = yDomain.upperBound - yDomain.lowerBound
            return CGPoint(
                x: plot.minX + CGFloat((x - xDomain.lowerBound) / (xSpan == 0 ? 1 : xSpan)) * plot.width,
                y: plot.maxY - CGFloat((y - yDomain.lowerBound) / (ySpan == 0 ? 1 : ySpan)) * plot.height
            )
        }

        // Grid and y labels.
        if !yAxis.isEmpty {
            let explicit = yAxis.first?.values
            let step = Self.niceStep(yDomain.upperBound - yDomain.lowerBound)
            let ticks = explicit ?? Array(stride(from: (yDomain.lowerBound / step).rounded(.up) * step, through: yDomain.upperBound + step * 0.001, by: step))
            for tick in ticks {
                let y = point(xDomain.lowerBound, tick).y
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(grid, with: .color(Color.gray.opacity(0.3)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                let label = Text(Self.format(tick)).font(.caption2).foregroundColor(.secondary)
                if trailingLabels {
                    context.draw(label, at: CGPoint(x: plot.maxX + 4, y: y), anchor: .leading)
                } else {
                    context.draw(label, at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
                }
            }
        }
        if !xAxis.isEmpty, !categories.isEmpty {
            for (index, name) in categories.enumerated() {
                let x = point(Double(index), yDomain.lowerBound).x
                context.draw(Text(name).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x, y: plot.maxY + 3), anchor: .top)
            }
        }

        // Series of continuous marks, in data order.
        var seriesOrder: [String] = []
        var groups: [String: [ChartMark]] = [:]
        for mark in marks where mark.kind == .line || mark.kind == .area {
            let key = "\(mark.kind)|\(mark.series)"
            if groups[key] == nil { seriesOrder.append(key) }
            groups[key, default: []].append(mark)
        }
        for key in seriesOrder {
            let group = groups[key]!.sorted { (value($0.x) ?? 0) < (value($1.x) ?? 0) }
            let points = group.compactMap { mark -> CGPoint? in
                guard let x = value(mark.x), let y = value(mark.y) else { return nil }
                return point(x, y)
            }
            guard points.count > 1, let first = group.first else { continue }
            let curve = Self.curve(through: points, method: first.interpolation)
            let shading = GraphicsContext.Shading.style(first.style ?? AnyShapeStyle(Color.accentColor))
            if first.kind == .area {
                var area = curve
                let baseline = point(xDomain.lowerBound, max(yDomain.lowerBound, min(0, yDomain.upperBound))).y
                area.addLine(to: CGPoint(x: points.last!.x, y: baseline))
                area.addLine(to: CGPoint(x: points.first!.x, y: baseline))
                area.closeSubpath()
                context.fill(area, with: shading)
            } else {
                context.stroke(curve, with: shading, style: StrokeStyle(lineWidth: first.lineWidth, lineCap: .round, lineJoin: .round))
            }
        }

        // Discrete marks.
        let barWidth = max(2, plot.width / CGFloat(max(1, categories.isEmpty ? marks.count : categories.count)) * 0.6)
        for mark in marks {
            let shading = GraphicsContext.Shading.style(mark.style ?? AnyShapeStyle(Color.accentColor))
            switch mark.kind {
            case .bar:
                guard let x = value(mark.x), let y = value(mark.y) else { continue }
                let top = point(x, y)
                let base = point(x, value(mark.yStart) ?? 0)
                context.fill(Path(roundedRect: CGRect(x: top.x - barWidth / 2, y: min(top.y, base.y), width: barWidth, height: abs(base.y - top.y)), cornerRadius: 2), with: shading)
            case .point:
                guard let x = value(mark.x), let y = value(mark.y) else { continue }
                let center = point(x, y)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: shading)
            case .rule:
                var rule = Path()
                if let y = value(mark.y) {
                    let at = point(xDomain.lowerBound, y).y
                    rule.move(to: CGPoint(x: plot.minX, y: at))
                    rule.addLine(to: CGPoint(x: plot.maxX, y: at))
                } else if let x = value(mark.x) {
                    let at = point(x, yDomain.lowerBound).x
                    rule.move(to: CGPoint(x: at, y: plot.minY))
                    rule.addLine(to: CGPoint(x: at, y: plot.maxY))
                }
                context.stroke(rule, with: shading, style: StrokeStyle(lineWidth: mark.lineWidth == 2 ? 1 : mark.lineWidth))
            case .line, .area:
                break
            }
        }
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Straight segments, or a Catmull-Rom spline for smooth interpolation methods.
    static func curve(through points: [CGPoint], method: InterpolationMethod) -> Path {
        var path = Path()
        path.move(to: points[0])
        switch method {
        case .catmullRom, .cardinal, .monotone:
            for index in 0..<(points.count - 1) {
                let p0 = points[max(index - 1, 0)], p1 = points[index], p2 = points[index + 1], p3 = points[min(index + 2, points.count - 1)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
        case .stepStart, .stepCenter, .stepEnd:
            for index in 1..<points.count {
                path.addLine(to: CGPoint(x: points[index].x, y: points[index - 1].y))
                path.addLine(to: points[index])
            }
        case .linear:
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }
}
