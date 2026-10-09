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
        let font = (environment.font ?? .defaultFont).resolve()
        let tint: Color.Resolved? = isTemplate ? ForegroundStyle()._resolveColor(in: environment) : nil
        var source = self.source
        if case .system(let name) = source, !environment.symbolVariants.names.isEmpty {
            // "wifi" + .slash → "wifi.slash" (backends fall back to the base name if missing).
            let missing = environment.symbolVariants.names.filter { !name.split(separator: ".").contains(Substring($0)) }
            if !missing.isEmpty { source = .system(([name] + missing).joined(separator: ".")) }
        }
        return ResolvedImage(source: source, isResizable: isResizable, pointSize: font.size, weight: font.weight, tint: tint, scale: environment.imageScale, variableValue: variableValue)
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
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) { .image(resolved.value) }
        inputs.makePlatformNode(content: content)
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
        // Symbol images space like text of their point size (no gap to adjacent text).
        if case .system = image.source, !image.isResizable {
            textSpacing = services.textSpacing(Font.Resolved(size: image.pointSize, weight: image.weight))
        } else {
            textSpacing = nil
        }
        super.init(path: path, tracer: tracer)
    }

    override var spacing: ViewSpacing { textSpacing.map(ViewSpacing.text) ?? .default }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        image.isResizable ? proposal.replacingUnspecifiedDimensions(by: intrinsic) : intrinsic
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? ImageLayoutComputer else { return false }
        return other.intrinsic == intrinsic && other.image.isResizable == image.isResizable && other.textSpacing == textSpacing
    }
}
