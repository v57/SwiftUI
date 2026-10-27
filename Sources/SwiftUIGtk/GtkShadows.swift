#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// Shadows (`.shadow`): the content's alpha, blurred, offset and tinted. Blurring is the costliest thing the canvas
/// draws, so shadows of shapes and colors (cards, buttons, the kits' grounds) are kept as masks keyed by what they
/// show, and redraws (hover, scrolling, other views changing) reuse them; other content is blurred on each draw.
@MainActor
enum GtkShadows {
    /// What a shadow mask was made of: its leaves' content and frames, the size, radius and device scale.
    struct Key: Equatable {
        var leaves: [Leaf]
        var size: CGSize
        var radius: CGFloat
        var scale: Double
    }

    struct Leaf: Equatable {
        var content: RenderContent
        var frame: CGRect
        var opacity: Double
    }

    private static var cache: [(key: Key, surface: OpaquePointer, margin: Int)] = []
    private static let cacheLimit = 96

    /// Draws the shadow of `node`'s children (a `.shadow` effect node), in its coordinates.
    static func draw(_ node: GtkNode, shadow: ResolvedShadow, in cr: Cairo, backend: GtkBackend, drawChildren: (Cairo) -> Void) {
        let radius = max(0, shadow.radius)
        var sx = 1.0, sy = 1.0
        cairo_user_to_device_distance(cr, &sx, &sy)
        let scale = max(1, min(abs(sx), 3))
        let size = node.frame.size
        if let leaves = leaves(of: node) {
            let key = Key(leaves: leaves, size: size, radius: radius, scale: scale)
            if let index = cache.firstIndex(where: { $0.key == key }) {
                let entry = cache.remove(at: index)
                cache.append(entry)
                paint(entry.surface, margin: entry.margin, shadow: shadow, in: cr)
                return
            }
            guard let (surface, margin) = makeMask(size: size, radius: radius, scale: scale, draw: drawChildren) else { return }
            cache.append((key, surface, margin))
            if cache.count > cacheLimit { cairo_surface_destroy(cache.removeFirst().surface) }
            paint(surface, margin: margin, shadow: shadow, in: cr)
            return
        }
        guard let (surface, margin) = makeMask(size: size, radius: radius, scale: scale, draw: drawChildren) else { return }
        paint(surface, margin: margin, shadow: shadow, in: cr)
        cairo_surface_destroy(surface)
    }

    /// The node's descendants when they are only shapes and colors (with plain containers), else nil.
    private static func leaves(of node: GtkNode) -> [Leaf]? {
        var result: [Leaf] = []
        func visit(_ node: GtkNode, origin: CGPoint, depth: Int) -> Bool {
            guard depth < 6, node.presentation.isIdentity else { return false }
            let frame = node.frame.offsetBy(dx: origin.x, dy: origin.y)
            switch node.content {
            case .shape, .color:
                guard node.children.isEmpty else { return false }
                result.append(Leaf(content: node.content, frame: frame, opacity: 1))
                return true
            case .empty, .effect(.group), .effect(.contentShape):
                return node.children.allSatisfy { visit($0, origin: frame.origin, depth: depth + 1) }
            default:
                return false
            }
        }
        for child in node.children where !visit(child, origin: .zero, depth: 0) { return nil }
        return result.count <= 8 ? result : nil
    }

    /// The content's alpha, blurred, with `margin` points of room around it for the blur.
    private static func makeMask(size: CGSize, radius: CGFloat, scale: Double, draw: (Cairo) -> Void) -> (OpaquePointer, Int)? {
        let margin = Int((radius * 2).rounded(.up)) + 2
        let width = Int((Double(size.width) + Double(margin * 2)) * scale), height = Int((Double(size.height) + Double(margin * 2)) * scale)
        guard width > 0, height > 0, width * height < 16_000_000, let surface = cairo_image_surface_create(CAIRO_FORMAT_A8, Int32(width), Int32(height)) else { return nil }
        let context = cairo_create(surface)!
        cairo_scale(context, scale, scale)
        cairo_translate(context, Double(margin), Double(margin))
        draw(context)
        cairo_destroy(context)
        cairo_surface_flush(surface)
        if radius > 0 { blur(surface, radius: Int((Double(radius) * scale / 2).rounded(.up))) }
        cairo_surface_mark_dirty(surface)
        cairo_surface_set_device_scale(surface, scale, scale)
        return (surface, margin)
    }

    private static func paint(_ surface: OpaquePointer, margin: Int, shadow: ResolvedShadow, in cr: Cairo) {
        cairo_save(cr)
        shadow.color.set(cr)
        cairo_mask_surface(cr, surface, Double(shadow.offset.width) - Double(margin), Double(shadow.offset.height) - Double(margin))
        cairo_restore(cr)
    }

    /// Three box-blur passes (≈ gaussian) over an A8 surface, with running sums in integers.
    private static func blur(_ surface: OpaquePointer, radius: Int) {
        guard radius > 0, let data = cairo_image_surface_get_data(surface) else { return }
        let width = Int(cairo_image_surface_get_width(surface)), height = Int(cairo_image_surface_get_height(surface))
        let stride = Int(cairo_image_surface_get_stride(surface))
        let count = width * height
        let a = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        let b = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        defer { a.deallocate(); b.deallocate() }
        // 8-bit alpha scaled by 64 keeps precision through the passes without overflowing UInt16.
        for y in 0..<height {
            let row = data.advanced(by: y * stride)
            for x in 0..<width { a[y * width + x] = UInt16(row[x]) << 6 }
        }
        let window = UInt32(radius * 2 + 1)
        func pass(_ input: UnsafeMutablePointer<UInt16>, _ output: UnsafeMutablePointer<UInt16>, horizontal: Bool) {
            let (outer, inner) = horizontal ? (height, width) : (width, height)
            let step = horizontal ? 1 : width
            for o in 0..<outer {
                let base = horizontal ? o * width : o
                var sum: UInt32 = 0
                for i in -radius...radius { sum += UInt32(input[base + min(max(i, 0), inner - 1) * step]) }
                for i in 0..<inner {
                    output[base + i * step] = UInt16(sum / window)
                    sum += UInt32(input[base + min(i + radius + 1, inner - 1) * step])
                    sum -= UInt32(input[base + max(i - radius, 0) * step])
                }
            }
        }
        for _ in 0..<3 {
            pass(a, b, horizontal: true)
            pass(b, a, horizontal: false)
        }
        for y in 0..<height {
            let row = data.advanced(by: y * stride)
            for x in 0..<width { row[x] = UInt8(min(255, (UInt32(a[y * width + x]) + 32) >> 6)) }
        }
    }
}
#endif
