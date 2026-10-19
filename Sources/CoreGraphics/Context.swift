import Foundation

public enum CGBlendMode: Int32, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight, difference,
        exclusion, hue, saturation, color, luminosity, clear, copy, sourceIn, sourceOut, sourceAtop, destinationOver,
        destinationIn, destinationOut, destinationAtop, xor, plusDarker, plusLighter
}

public enum CGTextDrawingMode: Int32, Sendable { case fill, stroke, fillStroke, invisible, fillClip, strokeClip, fillStrokeClip, clip }

/// A bitmap drawing context, drawn in software: paths (filled with anti-aliasing, stroked as outlines),
/// images, gradients, clipping and transparency layers. User space has its origin at the bottom left (y up);
/// the bitmap's first row is the top of the image, as on Apple platforms. Dashes and shadows are not drawn.
public final class CGContext: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bitsPerComponent: Int
    public let colorSpace: CGColorSpace?
    public let bitmapInfo: CGBitmapInfo
    let format: PixelFormat
    private let storage: UnsafeMutablePointer<UInt8>
    private let ownsStorage: Bool

    public var interpolationQuality: CGInterpolationQuality = .default

    struct State {
        var ctm: CGAffineTransform
        var fill: (Double, Double, Double, Double) = (0, 0, 0, 1)
        var stroke: (Double, Double, Double, Double) = (0, 0, 0, 1)
        var lineWidth: CGFloat = 1
        var lineCap: CGLineCap = .butt
        var lineJoin: CGLineJoin = .miter
        var miterLimit: CGFloat = 10
        var alpha: Double = 1
        var blendMode: CGBlendMode = .normal
        var antialias = true
        /// Coverage per pixel (row-major, top row first); nil when nothing is clipped.
        var clip: ClipMask?
    }

    final class ClipMask {
        var values: [Float]
        init(values: [Float]) { self.values = values }
    }

    private var state: State
    private var stack: [State] = []
    /// The current path, in device space (points are transformed as they are added, as on Apple platforms).
    private var devicePath = CGMutablePath()
    private var layers: [(base: [UInt8], state: State)] = []

    public init?(
        data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int,
        space: CGColorSpace, bitmapInfo: UInt32
    ) {
        guard width > 0, height > 0,
            let format = PixelFormat(bitmapInfo: bitmapInfo, colorComponents: space.numberOfComponents, bitsPerComponent: bitsPerComponent)
        else { return nil }
        let rowBytes = bytesPerRow == 0 ? width * format.bytesPerPixel : bytesPerRow
        guard rowBytes >= width * format.bytesPerPixel else { return nil }
        self.width = width; self.height = height; self.bytesPerRow = rowBytes; self.bitsPerComponent = bitsPerComponent
        colorSpace = space; self.bitmapInfo = CGBitmapInfo(rawValue: bitmapInfo); self.format = format
        if let data {
            storage = data.assumingMemoryBound(to: UInt8.self); ownsStorage = false
        } else {
            storage = .allocate(capacity: rowBytes * height)
            storage.initialize(repeating: 0, count: rowBytes * height)
            ownsStorage = true
        }
        state = State(ctm: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
    }

    public convenience init?(
        data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int,
        space: CGColorSpace, bitmapInfo: CGBitmapInfo
    ) {
        self.init(data: data, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo.rawValue)
    }

    deinit { if ownsStorage { storage.deallocate() } }

    public var data: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(storage) }
    public var bitsPerPixel: Int { format.bytesPerPixel * 8 }
    public var alphaInfo: CGImageAlphaInfo { CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none }

    public func makeImage() -> CGImage? {
        CGImage(width: width, height: height, bytesPerRow: bytesPerRow, format: format, space: colorSpace, bitmapInfo: bitmapInfo,
                bytes: Array(UnsafeBufferPointer(start: storage, count: bytesPerRow * height)))
    }

    public func flush() {}
    public func synchronize() {}

    // MARK: - Graphics state

    public func saveGState() { stack.append(state) }
    public func restoreGState() { if let last = stack.popLast() { state = last } }

    /// User space to the bitmap's pixels (y up, as Apple's reports it).
    public var ctm: CGAffineTransform { state.ctm.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))) }
    public var userSpaceToDeviceSpaceTransform: CGAffineTransform { ctm }

    public func translateBy(x: CGFloat, y: CGFloat) { state.ctm = CGAffineTransform(translationX: x, y: y).concatenating(state.ctm) }
    public func scaleBy(x: CGFloat, y: CGFloat) { state.ctm = CGAffineTransform(scaleX: x, y: y).concatenating(state.ctm) }
    public func rotate(by angle: CGFloat) { state.ctm = CGAffineTransform(rotationAngle: angle).concatenating(state.ctm) }
    public func concatenate(_ transform: CGAffineTransform) { state.ctm = transform.concatenating(state.ctm) }

    public func setFillColor(_ color: CGColor) { state.fill = Self.premultiplied(color._rgba) }
    public func setFillColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha)) }
    public func setFillColor(gray: CGFloat, alpha: CGFloat) { setFillColor(CGColor(gray: gray, alpha: alpha)) }
    public func setStrokeColor(_ color: CGColor) { state.stroke = Self.premultiplied(color._rgba) }
    public func setStrokeColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { setStrokeColor(CGColor(red: red, green: green, blue: blue, alpha: alpha)) }
    public func setStrokeColor(gray: CGFloat, alpha: CGFloat) { setStrokeColor(CGColor(gray: gray, alpha: alpha)) }
    public func setLineWidth(_ width: CGFloat) { state.lineWidth = width }
    public func setLineCap(_ cap: CGLineCap) { state.lineCap = cap }
    public func setLineJoin(_ join: CGLineJoin) { state.lineJoin = join }
    public func setMiterLimit(_ limit: CGFloat) { state.miterLimit = limit }
    public func setLineDash(phase: CGFloat, lengths: [CGFloat]) {}
    public func setAlpha(_ alpha: CGFloat) { state.alpha = Double(max(0, min(1, alpha))) }
    public func setBlendMode(_ mode: CGBlendMode) { state.blendMode = mode }
    public func setShouldAntialias(_ value: Bool) { state.antialias = value }
    public func setAllowsAntialiasing(_ value: Bool) {}
    public func setShadow(offset: CGSize, blur: CGFloat) {}
    public func setShadow(offset: CGSize, blur: CGFloat, color: CGColor?) {}
    public func setTextDrawingMode(_ mode: CGTextDrawingMode) {}

    private static func premultiplied(_ c: (r: Double, g: Double, b: Double, a: Double)) -> (Double, Double, Double, Double) {
        (c.r * c.a, c.g * c.a, c.b * c.a, c.a)
    }

    // MARK: - Path construction

    public func beginPath() { devicePath = CGMutablePath() }
    public var isPathEmpty: Bool { devicePath.isEmpty }
    public var path: CGPath? { devicePath.isEmpty ? nil : CGPath(elements: devicePath.transformed(state.ctm.inverted())) }
    public var currentPointOfPath: CGPoint { devicePath.currentPoint.applying(state.ctm.inverted()) }
    public var boundingBoxOfPath: CGRect { path?.boundingBoxOfPath ?? .null }

    public func move(to point: CGPoint) { devicePath.move(to: point, transform: state.ctm) }
    public func addLine(to point: CGPoint) { devicePath.addLine(to: point, transform: state.ctm) }
    public func addLines(between points: [CGPoint]) { devicePath.addLines(between: points, transform: state.ctm) }
    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint) {
        devicePath.addCurve(to: end, control1: control1, control2: control2, transform: state.ctm)
    }
    public func addQuadCurve(to end: CGPoint, control: CGPoint) { devicePath.addQuadCurve(to: end, control: control, transform: state.ctm) }
    public func closePath() { devicePath.closeSubpath() }
    public func addRect(_ rect: CGRect) { devicePath.addRect(rect, transform: state.ctm) }
    public func addRects(_ rects: [CGRect]) { devicePath.addRects(rects, transform: state.ctm) }
    public func addEllipse(in rect: CGRect) { devicePath.addEllipse(in: rect, transform: state.ctm) }
    public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        devicePath.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise, transform: state.ctm)
    }
    public func addPath(_ path: CGPath) { devicePath.addPath(path, transform: state.ctm) }

    // MARK: - Drawing

    public func fillPath(using rule: CGPathFillRule = .winding) {
        let polygons = devicePath._flattened(tolerance: 0.2).map(\.points)
        devicePath = CGMutablePath()
        let color = state.fill
        paint(polygons, rule: rule) { _, _ in color }
    }

    public func strokePath() {
        let user = CGPath(elements: devicePath.transformed(state.ctm.inverted()))
        devicePath = CGMutablePath()
        let polygons = strokePolygons(user).map { $0.map { $0.applying(state.ctm) } }
        let color = state.stroke
        paint(polygons, rule: .winding) { _, _ in color }
    }

    public func drawPath(using mode: CGPathDrawingMode) {
        let saved = devicePath
        switch mode {
        case .fill: fillPath(using: .winding)
        case .eoFill: fillPath(using: .evenOdd)
        case .stroke: strokePath()
        case .fillStroke, .eoFillStroke:
            fillPath(using: mode == .fillStroke ? .winding : .evenOdd)
            devicePath = saved
            strokePath()
        }
    }

    public func fill(_ rect: CGRect) { beginPath(); addRect(rect); fillPath() }
    public func fill(_ rects: [CGRect]) { beginPath(); addRects(rects); fillPath() }
    public func fillEllipse(in rect: CGRect) { beginPath(); addEllipse(in: rect); fillPath() }
    public func stroke(_ rect: CGRect) { beginPath(); addRect(rect); strokePath() }
    public func stroke(_ rect: CGRect, width: CGFloat) { saveGState(); setLineWidth(width); stroke(rect); restoreGState() }
    public func strokeEllipse(in rect: CGRect) { beginPath(); addEllipse(in: rect); strokePath() }
    public func strokeLineSegments(between points: [CGPoint]) {
        beginPath()
        var index = 0
        while index + 1 < points.count { move(to: points[index]); addLine(to: points[index + 1]); index += 2 }
        strokePath()
    }

    public func clear(_ rect: CGRect) {
        let saved = state.blendMode
        state.blendMode = .clear
        fill(rect)
        state.blendMode = saved
    }

    public func clip(using rule: CGPathFillRule = .winding) {
        let polygons = devicePath._flattened(tolerance: 0.2).map(\.points)
        devicePath = CGMutablePath()
        var mask = [Float](repeating: 0, count: width * height)
        rasterize(polygons, rule: rule, antialias: state.antialias) { y, x0, coverage in
            for i in coverage.indices { mask[y * self.width + x0 + i] = Float(coverage[i]) }
        }
        if let existing = state.clip {
            for i in mask.indices { mask[i] *= existing.values[i] }
        }
        state.clip = ClipMask(values: mask)
    }

    public func clip(to rect: CGRect) { beginPath(); addRect(rect); clip() }
    public func clip(to rects: [CGRect]) { beginPath(); addRects(rects); clip() }
    public func resetClip() { state.clip = nil }

    public var boundingBoxOfClipPath: CGRect {
        CGRect(x: 0, y: 0, width: width, height: height).applying(state.ctm.inverted())
    }

    public func draw(_ image: CGImage, in rect: CGRect, byTiling: Bool = false) {
        let r = rect.standardized
        guard r.width > 0, r.height > 0 else { return }
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            .map { $0.applying(state.ctm) }
        let inverse = state.ctm.inverted()
        let smooth = interpolationQuality != .none && image.shouldInterpolate
        let w = Double(image.width), h = Double(image.height)
        let polygons = byTiling ? [[CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height)]] : [corners]
        paint(polygons, rule: .winding) { x, y in
            let user = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(inverse)
            var u = (Double(user.x) - Double(r.minX)) / Double(r.width) * w
            var v = (Double(r.maxY) - Double(user.y)) / Double(r.height) * h
            if byTiling {
                u = u.truncatingRemainder(dividingBy: w); if u < 0 { u += w }
                v = v.truncatingRemainder(dividingBy: h); if v < 0 { v += h }
            }
            return Self.sample(image, u, v, smooth: smooth)
        }
    }

    public func drawLinearGradient(_ gradient: CGGradient, start: CGPoint, end: CGPoint, options: CGGradient.DrawingOptions) {
        let inverse = state.ctm.inverted()
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let length2 = dx * dx + dy * dy
        let whole = [[CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height)]]
        paint(whole, rule: .winding) { x, y in
            let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(inverse)
            var t = length2 > 0 ? ((Double(p.x) - Double(start.x)) * dx + (Double(p.y) - Double(start.y)) * dy) / length2 : 0
            if t < 0 { if !options.contains(.drawsBeforeStartLocation) { return (0, 0, 0, 0) }; t = 0 }
            if t > 1 { if !options.contains(.drawsAfterEndLocation) { return (0, 0, 0, 0) }; t = 1 }
            return gradient.color(at: t)
        }
    }

    public func drawRadialGradient(
        _ gradient: CGGradient, startCenter: CGPoint, startRadius: CGFloat, endCenter: CGPoint, endRadius: CGFloat,
        options: CGGradient.DrawingOptions
    ) {
        let inverse = state.ctm.inverted()
        let whole = [[CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height)]]
        let r0 = Double(startRadius), r1 = Double(endRadius)
        paint(whole, rule: .winding) { x, y in
            let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(inverse)
            // Concentric approximation: the distance from the centre interpolated by the point's own t.
            let distance = hypot(Double(p.x - endCenter.x), Double(p.y - endCenter.y))
            var t = r1 != r0 ? (distance - r0) / (r1 - r0) : 0
            if t < 0 { if !options.contains(.drawsBeforeStartLocation) { return (0, 0, 0, 0) }; t = 0 }
            if t > 1 { if !options.contains(.drawsAfterEndLocation) { return (0, 0, 0, 0) }; t = 1 }
            return gradient.color(at: t)
        }
    }

    public func beginTransparencyLayer(auxiliaryInfo: [String: Any]?) {
        let base = Array(UnsafeBufferPointer(start: storage, count: bytesPerRow * height))
        layers.append((base, state))
        storage.update(repeating: 0, count: bytesPerRow * height)
        state.alpha = 1
        state.blendMode = .normal
    }

    public func beginTransparencyLayer(in rect: CGRect, auxiliaryInfo: [String: Any]?) {
        beginTransparencyLayer(auxiliaryInfo: auxiliaryInfo)
    }

    public func endTransparencyLayer() {
        guard let popped = layers.popLast() else { return }
        let base = popped.base, saved = popped.state
        let layer = Array(UnsafeBufferPointer(start: storage, count: bytesPerRow * height))
        base.withUnsafeBufferPointer { storage.update(from: $0.baseAddress!, count: base.count) }
        let current = state
        state = saved
        let format = self.format, rowBytes = bytesPerRow, bpp = format.bytesPerPixel
        let whole = [[CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height)]]
        layer.withUnsafeBufferPointer { pixels in
            paint(whole, rule: .winding) { x, y in format.load(pixels.baseAddress! + y * rowBytes + x * bpp) }
        }
        state = current
        state.alpha = saved.alpha
        state.blendMode = saved.blendMode
    }

    // MARK: - Painting

    /// Fills the polygons (device space) with `source`'s premultiplied colour per pixel, through the clip, the
    /// global alpha and the blend mode.
    private func paint(_ polygons: [[CGPoint]], rule: CGPathFillRule, source: (Int, Int) -> (Double, Double, Double, Double)) {
        let alpha = state.alpha, mode = state.blendMode, clip = state.clip?.values
        let format = self.format, bpp = format.bytesPerPixel
        rasterize(polygons, rule: rule, antialias: state.antialias) { y, x0, coverage in
            let row = storage + y * bytesPerRow
            for i in coverage.indices {
                let x = x0 + i
                var cov = coverage[i] * alpha
                if let clip { cov *= Double(clip[y * width + x]) }
                guard cov > 0.0005 else { continue }
                let s = source(x, y)
                let pixel = row + x * bpp
                let d = format.load(pixel)
                let out: (Double, Double, Double, Double)
                switch mode {
                case .clear:
                    out = (d.0 * (1 - cov), d.1 * (1 - cov), d.2 * (1 - cov), d.3 * (1 - cov))
                case .copy:
                    out = (s.0 * cov + d.0 * (1 - cov), s.1 * cov + d.1 * (1 - cov), s.2 * cov + d.2 * (1 - cov), s.3 * cov + d.3 * (1 - cov))
                case .destinationOut:
                    let k = 1 - s.3 * cov
                    out = (d.0 * k, d.1 * k, d.2 * k, d.3 * k)
                case .destinationIn:
                    let k = 1 - cov + s.3 * cov
                    out = (d.0 * k, d.1 * k, d.2 * k, d.3 * k)
                case .sourceIn:
                    let k = d.3 * cov
                    out = (s.0 * k + d.0 * (1 - cov), s.1 * k + d.1 * (1 - cov), s.2 * k + d.2 * (1 - cov), s.3 * k + d.3 * (1 - cov))
                case .sourceAtop:
                    let k = d.3 * cov, inv = 1 - s.3 * cov
                    out = (s.0 * k + d.0 * inv, s.1 * k + d.1 * inv, s.2 * k + d.2 * inv, d.3)
                case .destinationOver:
                    let k = (1 - d.3) * cov
                    out = (d.0 + s.0 * k, d.1 + s.1 * k, d.2 + s.2 * k, d.3 + s.3 * k)
                case .multiply:
                    let sa = s.3 * cov
                    func ch(_ sc: Double, _ dc: Double) -> Double { sc * cov * (1 - d.3) + dc * (1 - sa) + sc * cov * dc }
                    out = (ch(s.0, d.0), ch(s.1, d.1), ch(s.2, d.2), sa + d.3 * (1 - sa))
                case .screen:
                    let sa = s.3 * cov
                    func ch(_ sc: Double, _ dc: Double) -> Double { sc * cov + dc - sc * cov * dc }
                    out = (ch(s.0, d.0), ch(s.1, d.1), ch(s.2, d.2), sa + d.3 * (1 - sa))
                case .plusLighter:
                    out = (min(1, d.0 + s.0 * cov), min(1, d.1 + s.1 * cov), min(1, d.2 + s.2 * cov), min(1, d.3 + s.3 * cov))
                default:
                    let inv = 1 - s.3 * cov
                    out = (s.0 * cov + d.0 * inv, s.1 * cov + d.1 * inv, s.2 * cov + d.2 * inv, s.3 * cov + d.3 * inv)
                }
                format.store(pixel, out)
            }
        }
    }

    /// A bilinear (or nearest) sample of the image at pixel coordinates (u, v), premultiplied.
    private static func sample(_ image: CGImage, _ u: Double, _ v: Double, smooth: Bool) -> (Double, Double, Double, Double) {
        let w = image.width, h = image.height
        guard u >= 0, v >= 0, u <= Double(w), v <= Double(h) else { return (0, 0, 0, 0) }
        if !smooth { return image.pixel(min(w - 1, Int(u)), min(h - 1, Int(v))) }
        let fx = max(0, min(Double(w - 1), u - 0.5)), fy = max(0, min(Double(h - 1), v - 0.5))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let a = image.pixel(x0, y0), b = image.pixel(x1, y0), c = image.pixel(x0, y1), d = image.pixel(x1, y1)
        func mix(_ p: Double, _ q: Double, _ r: Double, _ s: Double) -> Double {
            (p * (1 - tx) + q * tx) * (1 - ty) + (r * (1 - tx) + s * tx) * ty
        }
        return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2), mix(a.3, b.3, c.3, d.3))
    }

    // MARK: - Rasterizing

    private struct Edge {
        var x0: Double, y0: Double, x1: Double, y1: Double
        var direction: Int
    }

    /// Calls `row(y, x0, coverage)` for each pixel row the polygons touch, with the coverage (0...1) of the
    /// pixels from x0 on. Four sub-scanlines per row; each one's spans add their exact horizontal overlap.
    private func rasterize(_ polygons: [[CGPoint]], rule: CGPathFillRule, antialias: Bool, row: (Int, Int, [Double]) -> Void) {
        var edges: [Edge] = []
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for polygon in polygons where polygon.count > 2 {
            for index in polygon.indices {
                let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                let ax = Double(a.x), ay = Double(a.y), bx = Double(b.x), by = Double(b.y)
                guard ax.isFinite, ay.isFinite, bx.isFinite, by.isFinite else { continue }
                minX = min(minX, ax, bx); maxX = max(maxX, ax, bx); minY = min(minY, ay, by); maxY = max(maxY, ay, by)
                if ay == by { continue }
                edges.append(ay < by ? Edge(x0: ax, y0: ay, x1: bx, y1: by, direction: 1) : Edge(x0: bx, y0: by, x1: ax, y1: ay, direction: -1))
            }
        }
        guard !edges.isEmpty else { return }
        let firstRow = max(0, Int(minY.rounded(.down))), lastRow = min(height - 1, Int(maxY.rounded(.up)))
        let firstColumn = max(0, Int(minX.rounded(.down))), lastColumn = min(width - 1, Int(maxX.rounded(.up)))
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return }
        edges.sort { $0.y0 < $1.y0 }
        let samples = antialias ? 4 : 1
        let weight = 1 / Double(samples)
        var coverage = [Double](repeating: 0, count: lastColumn - firstColumn + 1)
        var active: [Edge] = []
        var next = 0
        var crossings: [(x: Double, direction: Int)] = []
        for y in firstRow...lastRow {
            for i in coverage.indices { coverage[i] = 0 }
            var touched = false
            for s in 0..<samples {
                let sy = Double(y) + (Double(s) + 0.5) * weight
                while next < edges.count, edges[next].y0 <= sy { active.append(edges[next]); next += 1 }
                active.removeAll { $0.y1 <= sy }
                crossings.removeAll(keepingCapacity: true)
                for edge in active where edge.y0 <= sy {
                    let t = (sy - edge.y0) / (edge.y1 - edge.y0)
                    crossings.append((edge.x0 + (edge.x1 - edge.x0) * t, edge.direction))
                }
                guard crossings.count > 1 else { continue }
                crossings.sort { $0.x < $1.x }
                var winding = 0
                for index in 0..<crossings.count - 1 {
                    winding += crossings[index].direction
                    let inside = rule == .winding ? winding != 0 : winding % 2 != 0
                    guard inside else { continue }
                    var left = max(Double(firstColumn), crossings[index].x), right = min(Double(lastColumn + 1), crossings[index + 1].x)
                    if !antialias { left = left.rounded(); right = right.rounded() }
                    guard right > left else { continue }
                    touched = true
                    let startPixel = Int(left.rounded(.down)), endPixel = min(lastColumn, Int((right - 1e-9).rounded(.down)))
                    if startPixel == endPixel {
                        coverage[startPixel - firstColumn] += (right - left) * weight
                    } else {
                        coverage[startPixel - firstColumn] += (Double(startPixel + 1) - left) * weight
                        if endPixel > startPixel + 1 {
                            for p in (startPixel + 1)..<endPixel { coverage[p - firstColumn] += weight }
                        }
                        coverage[endPixel - firstColumn] += (right - Double(endPixel)) * weight
                    }
                }
            }
            if touched {
                for i in coverage.indices where coverage[i] > 1 { coverage[i] = 1 }
                row(y, firstColumn, coverage)
            }
        }
    }

    // MARK: - Stroking

    /// The outline of the stroke as polygons (user space), all counter-clockwise so their union fills with the
    /// non-zero rule.
    private func strokePolygons(_ path: CGPath) -> [[CGPoint]] {
        let half = max(state.lineWidth, 0.0001) / 2
        var polygons: [[CGPoint]] = []
        func add(_ polygon: [CGPoint]) {
            var area: CGFloat = 0
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                area += a.x * b.y - b.x * a.y
            }
            polygons.append(area < 0 ? polygon.reversed() : polygon)
        }
        func circle(_ c: CGPoint) {
            let segments = max(12, min(64, Int(half * 4)))
            add((0..<segments).map { i in
                let angle = CGFloat(i) / CGFloat(segments) * 2 * .pi
                return CGPoint(x: c.x + half * cos(angle), y: c.y + half * sin(angle))
            })
        }
        for (points, closed) in path._flattened(tolerance: 0.1) {
            var pts: [CGPoint] = []
            for p in points where pts.last.map({ hypot($0.x - p.x, $0.y - p.y) > 1e-6 }) ?? true { pts.append(p) }
            if closed, pts.count > 2, let first = pts.first, let last = pts.last, hypot(first.x - last.x, first.y - last.y) < 1e-6 { pts.removeLast() }
            if pts.count == 1 {
                if state.lineCap == .round { circle(pts[0]) }
                if state.lineCap == .square { add([CGPoint(x: pts[0].x - half, y: pts[0].y - half), CGPoint(x: pts[0].x + half, y: pts[0].y - half), CGPoint(x: pts[0].x + half, y: pts[0].y + half), CGPoint(x: pts[0].x - half, y: pts[0].y + half)]) }
                continue
            }
            let count = closed ? pts.count : pts.count - 1
            for i in 0..<count {
                var a = pts[i], b = pts[(i + 1) % pts.count]
                let length = hypot(b.x - a.x, b.y - a.y)
                let dx = (b.x - a.x) / length, dy = (b.y - a.y) / length
                if !closed, state.lineCap == .square {
                    if i == 0 { a = CGPoint(x: a.x - dx * half, y: a.y - dy * half) }
                    if i == count - 1 { b = CGPoint(x: b.x + dx * half, y: b.y + dy * half) }
                }
                let nx = -dy * half, ny = dx * half
                add([CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny), CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)])
            }
            // Joins.
            let joints = closed ? Array(0..<pts.count) : Array(1..<max(1, pts.count - 1))
            for i in joints {
                let v = pts[i], p = pts[(i - 1 + pts.count) % pts.count], n = pts[(i + 1) % pts.count]
                if state.lineJoin == .round { circle(v); continue }
                let l1 = hypot(v.x - p.x, v.y - p.y), l2 = hypot(n.x - v.x, n.y - v.y)
                let d1 = CGPoint(x: (v.x - p.x) / l1, y: (v.y - p.y) / l1), d2 = CGPoint(x: (n.x - v.x) / l2, y: (n.y - v.y) / l2)
                let cross = d1.x * d2.y - d1.y * d2.x
                guard abs(cross) > 1e-9 else { continue }
                // Outer side: right of the turn for a left turn, and the other way round.
                let side: CGFloat = cross > 0 ? -1 : 1
                let o1 = CGPoint(x: v.x - d1.y * half * side, y: v.y + d1.x * half * side)
                let o2 = CGPoint(x: v.x - d2.y * half * side, y: v.y + d2.x * half * side)
                var polygon = [v, o1, o2]
                if state.lineJoin == .miter {
                    let cosine = -(d1.x * d2.x + d1.y * d2.y)
                    let miterRatio = 1 / max(1e-9, sin(acos(max(-1, min(1, cosine))) / 2))
                    if miterRatio <= state.miterLimit {
                        let bisector = CGPoint(x: (o1.x + o2.x) / 2 - v.x, y: (o1.y + o2.y) / 2 - v.y)
                        let bl = hypot(bisector.x, bisector.y)
                        if bl > 1e-9 {
                            let tip = CGPoint(x: v.x + bisector.x / bl * half * miterRatio, y: v.y + bisector.y / bl * half * miterRatio)
                            polygon = [v, o1, tip, o2]
                        }
                    }
                }
                add(polygon)
            }
            if !closed, state.lineCap == .round {
                circle(pts[0]); circle(pts[pts.count - 1])
            }
        }
        return polygons
    }
}
