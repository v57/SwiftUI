import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - ProposedViewSize

public struct ProposedViewSize: Hashable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?

    public init(width: CGFloat?, height: CGFloat?) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    public static let zero = ProposedViewSize(width: 0, height: 0)
    public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)
    public static let unspecified = ProposedViewSize(width: nil, height: nil)

    public func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10)) -> CGSize {
        CGSize(width: width ?? size.width, height: height ?? size.height)
    }

    subscript(axis: Axis) -> CGFloat? {
        get { axis == .horizontal ? width : height }
        set { if axis == .horizontal { width = newValue } else { height = newValue } }
    }

    init(main: CGFloat?, cross: CGFloat?, axis: Axis) {
        if axis == .horizontal { self.init(width: main, height: cross) } else { self.init(width: cross, height: main) }
    }
}

extension CGSize {
    subscript(axis: Axis) -> CGFloat {
        get { axis == .horizontal ? width : height }
        set { if axis == .horizontal { width = newValue } else { height = newValue } }
    }

    init(main: CGFloat, cross: CGFloat, axis: Axis) {
        if axis == .horizontal { self.init(width: main, height: cross) } else { self.init(width: cross, height: main) }
    }
}

extension CGPoint {
    subscript(axis: Axis) -> CGFloat {
        get { axis == .horizontal ? x : y }
        set { if axis == .horizontal { x = newValue } else { y = newValue } }
    }

    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
}

// MARK: - Axis / Edge

public enum Axis: Int8, CaseIterable, Hashable, Sendable {
    case horizontal, vertical

    public struct Set: OptionSet, Hashable, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1)
        public static let vertical = Set(rawValue: 2)
    }

    var other: Axis { self == .horizontal ? .vertical : .horizontal }
}

public enum Edge: Int8, CaseIterable, Hashable, Sendable {
    case top, leading, bottom, trailing

    public struct Set: OptionSet, Hashable, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public init(_ edge: Edge) { self.init(rawValue: 1 << edge.rawValue) }
        public static let top = Set(.top)
        public static let leading = Set(.leading)
        public static let bottom = Set(.bottom)
        public static let trailing = Set(.trailing)
        public static let all: Set = [.top, .leading, .bottom, .trailing]
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
    }
}

public struct EdgeInsets: Hashable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    init(_ edges: Edge.Set, _ length: CGFloat) {
        self.init(
            top: edges.contains(.top) ? length : 0,
            leading: edges.contains(.leading) ? length : 0,
            bottom: edges.contains(.bottom) ? length : 0,
            trailing: edges.contains(.trailing) ? length : 0
        )
    }

    var horizontal: CGFloat { leading + trailing }
    var vertical: CGFloat { top + bottom }
}

public enum LayoutDirection: Hashable, Sendable { case leftToRight, rightToLeft }
public enum ColorScheme: Hashable, Sendable, CaseIterable { case light, dark }
public enum TextAlignment: Hashable, Sendable { case leading, center, trailing }
public enum ContentMode: Hashable, Sendable { case fit, fill }

// MARK: - UnitPoint

public struct UnitPoint: Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat = 0, y: CGFloat = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}

// MARK: - Alignment

public protocol AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat
}

/// Identifies a guide on one axis; used to look up explicit alignment values.
public struct AlignmentKey: Hashable, @unchecked Sendable {
    let id: any AlignmentID.Type
    let axis: Axis

    init(_ id: any AlignmentID.Type, axis: Axis) {
        self.id = id
        self.axis = axis
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.axis == rhs.axis }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(id))
        hasher.combine(axis)
    }
}

public struct HorizontalAlignment: Equatable, Sendable {
    let id: any AlignmentID.Type
    public init(_ id: any AlignmentID.Type) { self.id = id }
    var key: AlignmentKey { AlignmentKey(id, axis: .horizontal) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    public static let leading = HorizontalAlignment(LeadingAlignment.self)
    public static let center = HorizontalAlignment(HCenterAlignment.self)
    public static let trailing = HorizontalAlignment(TrailingAlignment.self)
    public static let listRowSeparatorLeading = HorizontalAlignment(LeadingAlignment.self)
}

public struct VerticalAlignment: Equatable, Sendable {
    let id: any AlignmentID.Type
    public init(_ id: any AlignmentID.Type) { self.id = id }
    var key: AlignmentKey { AlignmentKey(id, axis: .vertical) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    public static let top = VerticalAlignment(TopAlignment.self)
    public static let center = VerticalAlignment(VCenterAlignment.self)
    public static let bottom = VerticalAlignment(BottomAlignment.self)
    public static let firstTextBaseline = VerticalAlignment(FirstTextBaselineAlignment.self)
    public static let lastTextBaseline = VerticalAlignment(LastTextBaselineAlignment.self)
}

public struct Alignment: Equatable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)
}

enum LeadingAlignment: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { 0 } }
enum HCenterAlignment: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d.width / 2 } }
enum TrailingAlignment: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d.width } }
enum TopAlignment: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { 0 } }
enum VCenterAlignment: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d.height / 2 } }
enum BottomAlignment: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d.height } }
enum FirstTextBaselineAlignment: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d.height } }
enum LastTextBaselineAlignment: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d.height } }

public struct ViewDimensions: Equatable {
    public let width: CGFloat
    public let height: CGFloat
    let explicit: @MainActor (AlignmentKey) -> CGFloat?

    @MainActor
    init(size: CGSize, explicit: @escaping @MainActor (AlignmentKey) -> CGFloat? = { _ in nil }) {
        self.width = size.width
        self.height = size.height
        self.explicit = explicit
    }

    @MainActor
    public subscript(guide: HorizontalAlignment) -> CGFloat {
        explicit(guide.key) ?? guide.id.defaultValue(in: self)
    }

    @MainActor
    public subscript(guide: VerticalAlignment) -> CGFloat {
        explicit(guide.key) ?? guide.id.defaultValue(in: self)
    }

    @MainActor
    public subscript(explicit guide: HorizontalAlignment) -> CGFloat? { explicit(guide.key) }
    @MainActor
    public subscript(explicit guide: VerticalAlignment) -> CGFloat? { explicit(guide.key) }

    @MainActor
    subscript(key: AlignmentKey, id: any AlignmentID.Type) -> CGFloat {
        explicit(key) ?? id.defaultValue(in: self)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.width == rhs.width && lhs.height == rhs.height }
}

// MARK: - Spacing

public struct ViewSpacing: Equatable, Sendable {
    /// Spacing preferences of one edge. Mirrors SwiftUI's category-based spacing closely enough
    /// for its observable behaviour: text meets text with (almost) no gap, text meets other views
    /// at font-dependent distances, and other views use the larger of both preferences.
    struct EdgeSpacing: Equatable, Sendable {
        /// Preference towards other views for non-text content on this edge (nil: text only).
        var value: CGFloat?
        /// Preference towards non-text neighbours for text on this edge (nil: no text).
        var text: CGFloat?
        /// Gap when text on this edge meets text (the lower text's leading on its top edge).
        var textToText: CGFloat = 0

        static func plain(_ value: CGFloat) -> EdgeSpacing { EdgeSpacing(value: value, text: nil) }

        mutating func formUnion(_ other: EdgeSpacing) {
            value = Self.maxOptional(value, other.value)
            text = Self.maxOptional(text, other.text)
            textToText = max(textToText, other.textToText)
        }

        private static func maxOptional(_ a: CGFloat?, _ b: CGFloat?) -> CGFloat? {
            switch (a, b) {
            case let (a?, b?): return max(a, b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }

        /// Distance between this (leading/top) edge and the following view's facing edge.
        func distance(to next: EdgeSpacing) -> CGFloat {
            var result: CGFloat?
            func consider(_ candidate: CGFloat) { result = max(result ?? candidate, candidate) }
            if let a = value, let b = next.value { consider(max(a, b)) }
            if let a = text, next.value != nil { consider(a) }
            if value != nil, let b = next.text { consider(b) }
            if text != nil, next.text != nil { consider(next.textToText) }
            return result ?? 0
        }
    }

    var topEdge: EdgeSpacing
    var leadingEdge: EdgeSpacing
    var bottomEdge: EdgeSpacing
    var trailingEdge: EdgeSpacing
    var isSpacer = false

    public static let zero = ViewSpacing(top: 0, leading: 0, bottom: 0, trailing: 0)
    static let `default` = ViewSpacing(top: 8, leading: 8, bottom: 8, trailing: 8)
    static let spacer = ViewSpacing(top: 0, leading: 0, bottom: 0, trailing: 0, isSpacer: true)

    public init() { self = .default }

    init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat, isSpacer: Bool = false) {
        self.topEdge = .plain(top)
        self.leadingEdge = .plain(leading)
        self.bottomEdge = .plain(bottom)
        self.trailingEdge = .plain(trailing)
        self.isSpacer = isSpacer
    }

    /// Spacing of text (and symbol images) with the given metrics.
    static func text(_ metrics: TextSpacing) -> ViewSpacing {
        var spacing = ViewSpacing.default
        spacing.topEdge = EdgeSpacing(value: nil, text: metrics.above, textToText: metrics.leading)
        spacing.bottomEdge = EdgeSpacing(value: nil, text: metrics.below, textToText: 0)
        return spacing
    }

    public func distance(to next: ViewSpacing, along axis: Axis) -> CGFloat {
        if isSpacer || next.isSpacer { return 0 }
        return axis == .horizontal ? trailingEdge.distance(to: next.leadingEdge) : bottomEdge.distance(to: next.topEdge)
    }

    public mutating func formUnion(_ other: ViewSpacing, edges: Edge.Set = .all) {
        if edges.contains(.top) { topEdge.formUnion(other.topEdge) }
        if edges.contains(.leading) { leadingEdge.formUnion(other.leadingEdge) }
        if edges.contains(.bottom) { bottomEdge.formUnion(other.bottomEdge) }
        if edges.contains(.trailing) { trailingEdge.formUnion(other.trailingEdge) }
        isSpacer = isSpacer && other.isSpacer
    }

    public func union(_ other: ViewSpacing, edges: Edge.Set = .all) -> ViewSpacing {
        var copy = self
        copy.formUnion(other, edges: edges)
        return copy
    }
}

/// Font-dependent spacing of text, reported by the backend (`PlatformServices.textSpacing`).
public struct TextSpacing: Equatable, Sendable {
    /// Gap between a non-text view above and the text's frame.
    public var above: CGFloat
    /// Gap between the text's frame and a non-text view below.
    public var below: CGFloat
    /// Gap between a text above and this text (the font's leading).
    public var leading: CGFloat

    public init(above: CGFloat, below: CGFloat, leading: CGFloat) {
        self.above = above
        self.below = below
        self.leading = leading
    }
}

// MARK: - Geometry assigned by a parent

/// Placement of a view: origin in the host's coordinate space (or the enclosing scroll content
/// space), its size, and the proposal it was placed with.
public struct ViewGeometry: Equatable, Sendable {
    public var origin: CGPoint
    public var size: CGSize
    public var proposal: ProposedViewSize

    public init(origin: CGPoint, size: CGSize, proposal: ProposedViewSize) {
        self.origin = origin
        self.size = size
        self.proposal = proposal
    }

    public static let zero = ViewGeometry(origin: .zero, size: .zero, proposal: .zero)

    public var frame: CGRect { CGRect(origin: origin, size: size) }
}
