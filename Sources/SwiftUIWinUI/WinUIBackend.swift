#if os(Windows)
import Foundation
import CSwiftUIWinUI
@_exported import _SwiftUICore

/// The Swift side of one host node (the backend's view handle). The XAML element lives in the
/// C# `HostView.nodes[id]`; releasing the handle destroys it.
@MainActor
final class WinUIView {
    let id: Int32
    let kind: ViewKind
    weak var node: RenderNode?
    /// Last children sent (skips unchanged `setChildren`).
    var children: [Int32] = []
    let releaseQueue: ReleaseQueue

    init(id: Int32, kind: ViewKind, releaseQueue: ReleaseQueue) {
        self.id = id
        self.kind = kind
        self.releaseQueue = releaseQueue
    }

    nonisolated deinit {
        releaseQueue.append(id)
    }
}

/// View ids whose handles were released (deinit isn't main-actor isolated); destroyed with the
/// next batch.
final class ReleaseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int32] = []

    func append(_ id: Int32) {
        lock.lock(); ids.append(id); lock.unlock()
    }

    func take() -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        let taken = ids
        ids.removeAll()
        return taken
    }
}

/// An image decoded by the host (`decodeImage`), referenced by id; released with the handle.
final class WinUIBitmap {
    let id: Int32
    init(id: Int32) { self.id = id }

    /// Bitmaps made from `CGImage`s (the CoreGraphics stand-in's), by image.
    private nonisolated(unsafe) static var converted: [ObjectIdentifier: (image: Weak, bitmap: WinUIBitmap)] = [:]
    final class Weak { weak var object: AnyObject?; init(_ object: AnyObject) { self.object = object } }

    /// The host bitmap of a platform image's object: a decoded bitmap, or a `CGImage` sent to the host the first
    /// time it is drawn: its pixels as they are when they're BGRA already (video frames, many a second), otherwise
    /// as PNG.
    static func bitmap(for object: AnyObject) -> WinUIBitmap? {
        if let bitmap = object as? WinUIBitmap { return bitmap }
        guard let image = object as? CGImage else { return nil }
        let key = ObjectIdentifier(image)
        if let entry = converted[key], entry.image.object === image { return entry.bitmap }
        converted = converted.filter { $0.value.image.object != nil }
        if let id = image._withBGRABytes({ bytes, bytesPerRow, opaque in
            sui_pixel_image(bytes.baseAddress, Int32(image.width), Int32(image.height), Int32(bytesPerRow), opaque)
        }), id >= 0 {
            let bitmap = WinUIBitmap(id: id)
            converted[key] = (Weak(image), bitmap)
            return bitmap
        }
        let png = image._pngData()
        var size: (Int32, Int32) = (0, 0)
        let id = png.withUnsafeBytes { buffer in
            withUnsafeMutablePointer(to: &size) { pointer in
                pointer.withMemoryRebound(to: Int32.self, capacity: 2) { sui_decode_image(buffer.baseAddress, Int32(buffer.count), $0) }
            }
        }
        guard id >= 0 else { return nil }
        let bitmap = WinUIBitmap(id: id)
        converted[key] = (Weak(image), bitmap)
        return bitmap
    }
    deinit {
        let id = self.id
        DispatchQueue.main.async { sui_release_image(id) }
    }
}

/// A native XAML element embedded with a representable, referenced by id.
final class WinUIPlatformView {
    let id: Int32
    init(id: Int32) { self.id = id }
}

/// WinUI 3 render backend: one XAML element per platform render node, positioned absolutely
/// (`Canvas`) by SwiftUI's layout (1 pt = 1 effective pixel). Changes are encoded into a command
/// buffer (the Android backend's format) and applied by the C# host once per commit; text is
/// measured with a `TextBlock` (the element that draws it).
@MainActor
public final class WinUIBackend: RenderBackend {
    let hostView: sui_ref
    let fileDialogs = WinUIFileDialogs()
    /// Physical pixels per effective pixel (XamlRoot.RasterizationScale), for pixel rounding.
    var scale: CGFloat
    private var commands = ByteWriter(capacity: 16 * 1024)
    private let releaseQueue = ReleaseQueue()
    private var nextID: Int32 = 1
    private let root: WinUIView
    /// Views by id, for routing events back to their nodes.
    private var views: [Int32: WeakView] = [:]

    struct WeakView { weak var view: WinUIView? }

    public var rootHandle: AnyObject { root }

    init(hostView: sui_ref, scale: CGFloat) {
        self.hostView = hostView
        self.scale = scale
        root = WinUIView(id: 0, kind: .container, releaseQueue: releaseQueue)
        views[0] = WeakView(view: root)
        WinUIText.install()
        
    }

    func node(for id: Int32) -> RenderNode? { views[id]?.view?.node }

    // MARK: Rendering

    public func makeView(for node: RenderNode) -> AnyObject {
        let kind = ViewKind(node.content)
        let view = WinUIView(id: nextID, kind: kind, releaseQueue: releaseQueue)
        nextID &+= 1
        view.node = node
        views[view.id] = WeakView(view: view)
        commands.u8(Op.create.rawValue)
        commands.i32(view.id)
        commands.u8(kind.rawValue)
        encodeContent(of: view, node: node)
        encodeFrame(of: view, node: node)
        if !node.presentation.isIdentity { setPresentation(of: view, node: node) }
        return view
    }

    public func updateContent(of view: AnyObject, node: RenderNode) {
        encodeContent(of: view as! WinUIView, node: node)
    }

    private func encodeContent(of view: WinUIView, node: RenderNode) {
        commands.u8(Op.content.rawValue)
        commands.i32(view.id)
        commands.u8(view.kind.rawValue)
        commands.content(node.content, actions: node.actions)
    }

    public func setFrame(of view: AnyObject, node: RenderNode) {
        encodeFrame(of: view as! WinUIView, node: node)
    }

    private func encodeFrame(of view: WinUIView, node: RenderNode) {
        let frame = node.frame
        commands.u8(Op.frame.rawValue)
        commands.i32(view.id)
        commands.f32(frame.minX); commands.f32(frame.minY); commands.f32(frame.width); commands.f32(frame.height)
    }

    public func setChildren(of view: AnyObject, node: RenderNode, to children: [AnyObject]) {
        let view = view as! WinUIView
        let ids = children.map { ($0 as! WinUIView).id }
        guard ids != view.children else { return }
        view.children = ids
        commands.u8(Op.children.rawValue)
        commands.i32(view.id)
        commands.i32(ids.count)
        for id in ids { commands.i32(id) }
    }

    public func setPresentation(of view: AnyObject, node: RenderNode) {
        let view = view as! WinUIView
        let p = node.presentation
        commands.u8(Op.presentation.rawValue)
        commands.i32(view.id)
        commands.f32(p.opacity)
        commands.f32(p.scale.width); commands.f32(p.scale.height)
        commands.f32(p.anchor.x); commands.f32(p.anchor.y)
        commands.f32(p.offset.width); commands.f32(p.offset.height)
        commands.f32(p.rotationDegrees)
    }

    public func updateAccessibility(of view: AnyObject, node: RenderNode) {
        guard let properties = node.accessibility else { return }
        let view = view as! WinUIView
        commands.u8(Op.accessibility.rawValue)
        commands.i32(view.id)
        commands.bool(properties.isHidden)
        commands.string(properties.label)
        commands.string(properties.value)
        commands.string(properties.hint)
        commands.string(properties.identifier)
    }

    public func didCommit() { flush() }

    /// Sends the pending commands to the host (one call).
    func flush() {
        let released = releaseQueue.take()
        for id in released {
            views[id] = nil
            commands.u8(Op.destroy.rawValue)
            commands.i32(id)
        }
        guard !commands.isEmpty else { return }
        WinUIPerf.measure(.apply) {
            commands.withBytes { buffer in
                sui_host_apply(hostView, buffer.baseAddress, Int32(buffer.count))
            }
        }
        commands.reset()
    }

    // MARK: Metrics

    private var textCache: [TextCacheKey: SIMD4<Float>] = [:]

    struct TextCacheKey: Hashable {
        let text: ResolvedText
        let width: Float
    }

    /// width, height, first baseline, line height (epx).
    private func textMetrics(_ text: ResolvedText, width: CGFloat?) -> SIMD4<Float> {
        let maxWidth = width.flatMap { $0.isFinite ? Float($0) : nil } ?? -1
        var key = text
        // Colors don't change the layout.
        key.color = Color.Resolved(red: 0, green: 0, blue: 0)
        key.contentTransition = .interpolate
        let cacheKey = TextCacheKey(text: key, width: maxWidth)
        if let cached = textCache[cacheKey] { return cached }
        if textCache.count > 4096 { textCache.removeAll(keepingCapacity: true) }
        var spec = ByteWriter(capacity: 256)
        spec.text(text)
        var out: (Float, Float, Float, Float) = (0, 0, 0, 0)
        WinUIPerf.measure(.measureText) {
            spec.withBytes { buffer in
                withUnsafeMutablePointer(to: &out) { pointer in
                    pointer.withMemoryRebound(to: Float.self, capacity: 4) { floats in
                        sui_measure_text(buffer.baseAddress, Int32(buffer.count), maxWidth, floats)
                    }
                }
            }
        }
        let result = SIMD4<Float>(out.0, out.1, out.2, out.3)
        textCache[cacheKey] = result
        return result
    }

    public func measureText(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize {
        let metrics = textMetrics(text, width: proposal.width)
        var height = CGFloat(metrics.y)
        if let minimumLines = text.minimumLines, minimumLines > 1 {
            height = max(height, CGFloat(minimumLines) * CGFloat(metrics.w))
        }
        return CGSize(width: ceilToPixel(CGFloat(metrics.x)), height: ceilToPixel(height))
    }

    public func unroundedTextWidth(_ text: ResolvedText) -> CGFloat {
        CGFloat(textMetrics(text, width: nil).x)
    }

    public func firstBaseline(of text: ResolvedText) -> CGFloat {
        CGFloat(textMetrics(text, width: nil).z)
    }

    func ceilToPixel(_ value: CGFloat) -> CGFloat {
        (value * scale - 0.001).rounded(.up) / scale
    }

    public func imageSize(_ image: ResolvedImage) -> CGSize {
        switch image.source {
        case .system:
            // Material Symbols are square glyphs on a 24-unit grid.
            let side = SymbolFont.glyphSize(image).rounded()
            return CGSize(width: side, height: side)
        case .named(let name):
            return WinUIImages.size(named: name, host: hostView) ?? CGSize(width: image.pointSize, height: image.pointSize)
        case .platform(let platform):
            return platform.size
        }
    }

    public func controlMetrics(_ control: ControlKind) -> ControlMetrics {
        WinUIControls.metrics(control, host: hostView)
    }

    // MARK: Platform services

    public func openURL(_ url: URL) {
        _ = WinUIPlatform.call(hostView, .openURL, url.absoluteString)
    }

    public func performHapticFeedback(_ feedback: SensoryFeedback) {
        _ = WinUIPlatform.call(hostView, .haptic, "\(feedback.kind)")
    }

    public func share(_ items: [Any]) {
        let text = items.map { item -> String in
            if let url = item as? URL { return url.absoluteString }
            return "\(item)"
        }.joined(separator: "\n")
        _ = WinUIPlatform.call(hostView, .share, text)
    }

    public func writeToPasteboard(_ items: [Any]) {
        let text = items.compactMap { item -> String? in
            if let string = item as? String { return string }
            if let url = item as? URL { return url.absoluteString }
            return nil
        }.joined(separator: "\n")
        _ = WinUIPlatform.call(hostView, .copy, text)
    }

    public func decodeImage(_ data: Data, scale: CGFloat) -> PlatformImage? {
        var size: (Int32, Int32) = (0, 0)
        let id = data.withUnsafeBytes { buffer in
            withUnsafeMutablePointer(to: &size) { pointer in
                pointer.withMemoryRebound(to: Int32.self, capacity: 2) { sui_decode_image(buffer.baseAddress, Int32(buffer.count), $0) }
            }
        }
        guard id >= 0 else { return nil }
        // Pixel size divided by the requested scale (like SwiftUI's AsyncImage).
        let scale = max(scale, 0.01)
        return PlatformImage(object: WinUIBitmap(id: id), size: CGSize(width: CGFloat(size.0) / scale, height: CGFloat(size.1) / scale))
    }

    public func presentFileDialog(_ request: FileDialogRequest, completion: @escaping @MainActor ([URL]?) -> Void) {
        fileDialogs.present(request, host: hostView, completion: completion)
    }

    public func readPasteboard() -> [NSItemProvider] {
        guard let text = readPasteboardString() else { return [] }
        return [NSItemProvider(object: text)]
    }

    public func readPasteboardString() -> String? {
        WinUIPlatform.call(hostView, .paste, nil)
    }
}

/// Synchronous host calls (`HostView.Platform(op, argument)`; the Android host's numbering).
enum WinUIPlatform {
    enum Op: Int32 {
        case openURL = 1, haptic, share, copy, paste, controlMetrics, imageSize, showKeyboard, hideKeyboard, setTitle, setToolbar
        /// Brings the host's window to the front.
        case activate
        /// The window's menu bar (WinUIMenuBar's encoding; empty hides it).
        case setMenuBar
        /// Shows a file picker (WinUIFileDialogs' encoding); returns nil if it can't.
        case fileDialog
        /// The window's chrome and size from its scene, before it opens (`WinUIHost.configureWindow`).
        case configureWindow
        /// Content in the title bar row ("contentInTitleBar,hidesTitle").
        case setTitleBar
        /// The window's appearance (`preferredColorScheme`): "dark", "light", or empty for the system's.
        case setColorScheme
    }

    @MainActor
    static func call(_ host: sui_ref, _ op: Op, _ argument: String?) -> String? {
        let result: UnsafeMutablePointer<CChar>?
        if let argument {
            result = argument.withCString { sui_host_platform(host, op.rawValue, $0) }
        } else {
            result = sui_host_platform(host, op.rawValue, nil)
        }
        guard let result else { return nil }
        defer { free(result) }
        return String(cString: result)
    }
}

#endif
