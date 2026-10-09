import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct ResolvedImage: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case system(String)
        case named(String)
    }

    public var source: Source
    public var isResizable: Bool
    /// Symbol point size (from the font) for SF Symbols.
    public var pointSize: CGFloat
    public var weight: Font.Weight
    public var tint: Color.Resolved?
}

public struct Image: Equatable {
    public enum Scale: Hashable, Sendable { case small, medium, large }

    var source: ResolvedImage.Source
    var isResizable = false
    var isTemplate: Bool

    public init(systemName: String) {
        source = .system(systemName)
        isTemplate = true
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
        var font = (environment.font ?? .defaultFont).resolve()
        switch environment.imageScale {
        case .small: font.size *= 0.8
        case .large: font.size *= 1.3
        case .medium: break
        }
        let tint: Color.Resolved? = isTemplate ? ForegroundStyle()._resolveColor(in: environment) : nil
        return ResolvedImage(source: source, isResizable: isResizable, pointSize: font.size, weight: font.weight, tint: tint)
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
