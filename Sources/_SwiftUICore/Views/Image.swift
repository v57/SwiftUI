import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct ResolvedImage: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case system(String)
        case named(String)
        /// A platform image object (NSImage, CGImage, ...) created by a backend initializer.
        case platform(PlatformImage)
    }

    public var source: Source
    public var isResizable: Bool
    /// Symbol point size (from the font) for SF Symbols.
    public var pointSize: CGFloat
    public var weight: Font.Weight
    public var tint: Color.Resolved?
    /// Symbol scale (`imageScale`); the point size stays the font's.
    public var scale: Image.Scale = .medium
    /// Variable-value symbols: layers above the value are drawn dimmed (0...1).
    public var variableValue: Double?
    /// Drawn as a placeholder shape (`redacted(reason:)`), in this color.
    public var redactedColor: Color.Resolved? = nil
    /// Symbol rendering (`symbolRenderingMode`); nil is monochrome in the tint.
    public var renderingMode: SymbolRenderingMode? = nil
    /// Hierarchical/palette colors (from `foregroundStyle(_:_:)` levels).
    public var paletteColors: [Color.Resolved] = []
    /// Symbol effects to run (`symbolEffect`).
    public var symbolEffects: [_SymbolEffectRequest] = []
    public var contentTransition = ContentTransition.interpolate
}

/// An opaque platform image with its intrinsic size (compared by identity).
public struct PlatformImage: Hashable, @unchecked Sendable {
    public let object: AnyObject
    public let size: CGSize

    public init(object: AnyObject, size: CGSize) {
        self.object = object
        self.size = size
    }

    public static func == (lhs: PlatformImage, rhs: PlatformImage) -> Bool { lhs.object === rhs.object }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(object)) }
}

public struct Image: Equatable {
    public enum Scale: Hashable, Sendable { case small, medium, large }
    public enum Interpolation: Hashable, Sendable { case none, low, medium, high }
    public enum Orientation: UInt8, Hashable, Sendable { case up, upMirrored, down, downMirrored, left, leftMirrored, right, rightMirrored }

    /// An image from a platform image object (backends provide typed initializers).
    public init(_platformImage image: PlatformImage) {
        source = .platform(image)
        isTemplate = false
    }

    public func interpolation(_ interpolation: Interpolation) -> Image { self }
    public func antialiased(_ isAntialiased: Bool) -> Image { self }

    var source: ResolvedImage.Source
    var isResizable = false
    var isTemplate: Bool
    var variableValue: Double?

    public init(systemName: String) {
        source = .system(systemName)
        isTemplate = true
    }

    public init(systemName: String, variableValue: Double?) {
        self.init(systemName: systemName)
        self.variableValue = variableValue
    }

    public init(_ name: String, variableValue: Double?, bundle: Bundle? = nil) {
        self.init(name)
        self.variableValue = variableValue
    }

    public init(_ name: String) {
        source = .named(name)
        isTemplate = false
    }

    /// An image from the asset catalog / bundle resources (looked up by name).
    public init(_ name: String, bundle: Bundle?) {
        self.init(name)
    }

    public init(_ name: String, bundle: Bundle? = nil, label: Text) {
        self.init(name)
    }

    /// An image ignored by accessibility.
    public init(decorative name: String, bundle: Bundle? = nil) {
        self.init(name)
    }

    public func resizable() -> Image {
        var copy = self
        copy.isResizable = true
        return copy
    }

    public enum TemplateRenderingMode: Hashable, Sendable { case template, original }

    public func renderingMode(_ mode: TemplateRenderingMode?) -> Image {
        var copy = self
        copy.isTemplate = mode == .template
        return copy
    }

    func resolve(in environment: EnvironmentValues) -> ResolvedImage {
        let font = (environment.font ?? .defaultFont).resolve(environment.dynamicTypeSize)
        let tint: Color.Resolved? = isTemplate ? ForegroundStyle()._resolveColor(in: environment) : nil
        var source = self.source
        if case .system(let name) = source, !environment.symbolVariants.names.isEmpty {
            // "wifi" + .slash → "wifi.slash" (backends fall back to the base name if missing).
            let missing = environment.symbolVariants.names.filter { !name.split(separator: ".").contains(Substring($0)) }
            if !missing.isEmpty { source = .system(([name] + missing).joined(separator: ".")) }
        }
        var resolved = ResolvedImage(source: source, isResizable: isResizable, pointSize: font.size, weight: font.weight, tint: tint, scale: environment.imageScale, variableValue: variableValue)
        if environment._isRedacted { resolved.redactedColor = ForegroundStyle()._resolveColor(in: environment) }
        if case .system = source {
            let levels = environment.foregroundStyleLevels
            resolved.renderingMode = environment.symbolRenderingMode ?? (levels.count > 1 ? .palette : nil)
            if resolved.renderingMode == .palette || resolved.renderingMode == .hierarchical {
                resolved.paletteColors = levels.isEmpty ? (tint.map { [$0] } ?? []) : levels.compactMap { $0._resolveColor(in: environment) }
            }
            if !environment._symbolEffectsRemoved { resolved.symbolEffects = environment._symbolEffects }
            resolved.contentTransition = environment.contentTransition
        }
        return resolved
    }
}

extension Image: View {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Image>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "Image")
        let environment = inputs.environment
        let resolved = Attribute<ResolvedImage>(inputs.subgraph, isEqual: { $0 == $1 }) {
            view.attribute.value.resolve(in: environment.value)
        }
        inputs.makeLeafPlatformNode { .image(resolved.value) }
        let services = inputs.services
        let tracer = inputs.tracer
        let path = inputs.path
        let layout = inputs.makeLayoutAttribute {
            ImageLayoutComputer(image: resolved.value, services: services, path: path, tracer: tracer)
        }
        return _ViewOutputs(layout: layout)
    }
}

final class ImageLayoutComputer: LayoutComputer {
    let image: ResolvedImage
    let intrinsic: CGSize
    let textSpacing: TextSpacing?

    init(image: ResolvedImage, services: any PlatformServices, path: ViewPath, tracer: UpdateTracer) {
        self.image = image
        self.intrinsic = services.imageSize(image)
        // Symbol images space like text (no gap to adjacent text), but sit much closer to other
        // views than text does: measured ≈ 0.28 × (height − ¾ point size) above, 1pt more below.
        if case .system = image.source, !image.isResizable {
            let above = max(0.5, ((intrinsic.height - 0.75 * image.pointSize) * 0.28 * 2).rounded() / 2)
            textSpacing = TextSpacing(above: above, below: above + 1, leading: 0)
        } else {
            textSpacing = nil
        }
        super.init(path: path, tracer: tracer)
    }

    override var computedSpacing: ViewSpacing { textSpacing.map(ViewSpacing.text) ?? .default }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        image.isResizable ? proposal.replacingUnspecifiedDimensions(by: intrinsic) : intrinsic
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? ImageLayoutComputer else { return false }
        return other.intrinsic == intrinsic && other.image.isResizable == image.isResizable && other.textSpacing == textSpacing
    }
}

#if !canImport(ObjectiveC) && canImport(CoreGraphics)
// Off Apple platforms a `CGImage` is the CoreGraphics stand-in's bitmap; backends turn it into their own image
// the first time they draw it.
extension Image {
    public init(_ cgImage: CGImage, scale: CGFloat, orientation: Image.Orientation = .up, label: Text) {
        let size = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        self.init(_platformImage: PlatformImage(object: cgImage, size: size))
    }

    public init(decorative cgImage: CGImage, scale: CGFloat, orientation: Image.Orientation = .up) {
        let size = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        self.init(_platformImage: PlatformImage(object: cgImage, size: size))
    }
}

/// How `ImageRenderer` rasterizes a view off Apple platforms: installed by a backend that can draw offscreen.
public enum _ImageRendering {
    nonisolated(unsafe) public static var rasterize: (@MainActor (AnyView, ProposedViewSize, CGFloat) -> CGImage?)?
}

/// Renders a view into an image (laid out at `proposedSize`, rasterized at `scale`). `cgImage` is nil where the
/// backend can't draw offscreen.
@MainActor
public final class ImageRenderer<Content: View>: ObservableObject {
    public var content: Content
    public var label: String?
    public var proposedSize: ProposedViewSize = .unspecified
    public var scale: CGFloat = 1
    public var isOpaque = false
    public var colorMode: ColorRenderingMode = .nonLinear

    public init(content view: Content) {
        content = view
    }

    public var cgImage: CGImage? {
        _ImageRendering.rasterize?(AnyView(content), proposedSize, scale)
    }

    /// Draws the rendered image into a context the caller provides.
    public func render(rasterizationScale: CGFloat = 1, renderer: (CGSize, (CGContext) -> Void) -> Void) {
        guard let image = cgImage else { return }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        renderer(size) { context in context.draw(image, in: CGRect(origin: .zero, size: size)) }
    }
}
#endif
