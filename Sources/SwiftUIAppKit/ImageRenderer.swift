#if canImport(AppKit)
import AppKit
import _SwiftUICore

/// Renders a view into an image (laid out at `proposedSize`, rasterized at `scale`).
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

    /// The rendered image (nil when the view has no size).
    public var cgImage: CGImage? {
        let host = NSHostingView(rootView: content)
        let fitting = host.fittingSize
        let size = CGSize(width: proposedSize.width.flatMap { $0.isFinite ? $0 : nil } ?? fitting.width,
                          height: proposedSize.height.flatMap { $0.isFinite ? $0 : nil } ?? fitting.height)
        guard size.width > 0, size.height > 0 else { return nil }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.graph.update()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)), pixelsHigh: Int((size.height * scale).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    public var nsImage: NSImage? {
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
    }

    /// Draws the rendered image into a context the caller provides (e.g. a PDF context).
    public func render(rasterizationScale: CGFloat = 1, renderer: (CGSize, (CGContext) -> Void) -> Void) {
        guard let image = cgImage else { return }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        renderer(size) { context in context.draw(image, in: CGRect(origin: .zero, size: size)) }
    }
}
#endif
