import Foundation

public enum CGImageAlphaInfo: UInt32, Sendable {
    case none, premultipliedLast, premultipliedFirst, last, first, noneSkipLast, noneSkipFirst, alphaOnly
}

public struct CGBitmapInfo: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(alphaInfo: CGImageAlphaInfo) { rawValue = alphaInfo.rawValue }

    public static let alphaInfoMask = CGBitmapInfo(rawValue: 0x1F)
    public static let floatComponents = CGBitmapInfo(rawValue: 1 << 8)
    public static let byteOrderMask = CGBitmapInfo(rawValue: 0x7000)
    public static let byteOrderDefault = CGBitmapInfo([])
    public static let byteOrder16Little = CGBitmapInfo(rawValue: 1 << 12)
    public static let byteOrder32Little = CGBitmapInfo(rawValue: 2 << 12)
    public static let byteOrder16Big = CGBitmapInfo(rawValue: 3 << 12)
    public static let byteOrder32Big = CGBitmapInfo(rawValue: 4 << 12)
}

public enum CGInterpolationQuality: Int32, Sendable { case `default`, none, low, high, medium }

public enum CGColorRenderingIntent: Int32, Sendable {
    case defaultIntent, absoluteColorimetric, relativeColorimetric, perceptual, saturation
}

/// Bytes an image is made from.
public final class CGDataProvider: @unchecked Sendable {
    public let data: Data?
    public init?(data: Data) { self.data = data }
}

/// Where each channel sits in a pixel of an 8-bit-per-component bitmap.
struct PixelFormat: Equatable {
    enum Alpha { case none, premultiplied, straight }
    var bytesPerPixel: Int
    /// Byte offsets in the pixel (gray: all the same; alpha -1 when there is none).
    var r: Int, g: Int, b: Int, a: Int
    var alpha: Alpha
    var alphaOnly = false

    init?(bitmapInfo: UInt32, colorComponents: Int, bitsPerComponent: Int) {
        guard bitsPerComponent == 8, let info = CGImageAlphaInfo(rawValue: bitmapInfo & CGBitmapInfo.alphaInfoMask.rawValue)
        else { return nil }
        let little = bitmapInfo & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder32Little.rawValue
        switch info {
        case .premultipliedLast, .last, .noneSkipLast: alpha = info == .premultipliedLast ? .premultiplied : info == .last ? .straight : .none
        case .premultipliedFirst, .first, .noneSkipFirst: alpha = info == .premultipliedFirst ? .premultiplied : info == .first ? .straight : .none
        case .none, .alphaOnly: alpha = info == .alphaOnly ? .premultiplied : .none
        }
        if info == .alphaOnly {
            bytesPerPixel = 1; r = 0; g = 0; b = 0; a = 0; alphaOnly = true
            return
        }
        if colorComponents == 1 {
            switch info {
            case .none: bytesPerPixel = 1; r = 0; g = 0; b = 0; a = -1
            case .premultipliedLast, .last, .noneSkipLast: bytesPerPixel = 2; r = 0; g = 0; b = 0; a = info == .noneSkipLast ? -1 : 1
            default: bytesPerPixel = 2; r = 1; g = 1; b = 1; a = info == .noneSkipFirst ? -1 : 0
            }
            return
        }
        switch info {
        case .none: bytesPerPixel = 3; r = 0; g = 1; b = 2; a = -1
        case .premultipliedLast, .last, .noneSkipLast:
            bytesPerPixel = 4
            (r, g, b, a) = little ? (3, 2, 1, 0) : (0, 1, 2, 3)
        default:
            bytesPerPixel = 4
            (r, g, b, a) = little ? (2, 1, 0, 3) : (1, 2, 3, 0)
        }
        if alpha == .none { a = -1 }
    }

    static let rgba = PixelFormat(bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue, colorComponents: 3, bitsPerComponent: 8)!

    /// A pixel as premultiplied components, 0...1.
    @inline(__always)
    func load(_ p: UnsafePointer<UInt8>) -> (Double, Double, Double, Double) {
        if alphaOnly { return (0, 0, 0, Double(p[0]) / 255) }
        let alphaValue = a >= 0 ? Double(p[a]) / 255 : 1
        var red = Double(p[r]) / 255, green = Double(p[g]) / 255, blue = Double(p[b]) / 255
        if alpha == .straight { red *= alphaValue; green *= alphaValue; blue *= alphaValue }
        return (red, green, blue, alphaValue)
    }

    @inline(__always)
    func store(_ p: UnsafeMutablePointer<UInt8>, _ c: (Double, Double, Double, Double)) {
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        if alphaOnly { p[0] = byte(c.3); return }
        var (red, green, blue) = (c.0, c.1, c.2)
        if alpha == .straight || alpha == .none, c.3 > 0, c.3 < 1 { red /= c.3; green /= c.3; blue /= c.3 }
        if r == g && g == b {
            p[r] = byte(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        } else {
            p[r] = byte(red); p[g] = byte(green); p[b] = byte(blue)
        }
        if a >= 0 { p[a] = byte(c.3) }
    }
}

/// A bitmap image: 8 bits per component, gray or RGB, with or without alpha.
public final class CGImage: @unchecked Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let bitsPerPixel: Int
    public let bytesPerRow: Int
    public let colorSpace: CGColorSpace?
    public let bitmapInfo: CGBitmapInfo
    public let dataProvider: CGDataProvider?
    public let shouldInterpolate: Bool
    public let renderingIntent: CGColorRenderingIntent
    let format: PixelFormat
    let bytes: [UInt8]

    public init?(
        width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int, space: CGColorSpace,
        bitmapInfo: CGBitmapInfo, provider: CGDataProvider, decode: UnsafePointer<CGFloat>?, shouldInterpolate: Bool,
        intent: CGColorRenderingIntent
    ) {
        guard width > 0, height > 0, let data = provider.data, data.count >= bytesPerRow * (height - 1) + width * bitsPerPixel / 8,
            let format = PixelFormat(bitmapInfo: bitmapInfo.rawValue, colorComponents: space.numberOfComponents, bitsPerComponent: bitsPerComponent),
            format.bytesPerPixel * 8 == bitsPerPixel
        else { return nil }
        self.width = width; self.height = height
        self.bitsPerComponent = bitsPerComponent; self.bitsPerPixel = bitsPerPixel; self.bytesPerRow = bytesPerRow
        colorSpace = space; self.bitmapInfo = bitmapInfo; dataProvider = provider
        self.shouldInterpolate = shouldInterpolate; renderingIntent = intent
        self.format = format
        bytes = [UInt8](data)
    }

    init(width: Int, height: Int, bytesPerRow: Int, format: PixelFormat, space: CGColorSpace?, bitmapInfo: CGBitmapInfo, bytes: [UInt8]) {
        self.width = width; self.height = height
        bitsPerComponent = 8; bitsPerPixel = format.bytesPerPixel * 8; self.bytesPerRow = bytesPerRow
        colorSpace = space; self.bitmapInfo = bitmapInfo
        dataProvider = CGDataProvider(data: Data(bytes))
        shouldInterpolate = true; renderingIntent = .defaultIntent
        self.format = format
        self.bytes = bytes
    }

    public var alphaInfo: CGImageAlphaInfo {
        CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none
    }

    public var isMask: Bool { false }

    /// Premultiplied components of the pixel at (x, y), row 0 at the top.
    @inline(__always)
    func pixel(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
        bytes.withUnsafeBufferPointer { format.load($0.baseAddress! + y * bytesPerRow + x * format.bytesPerPixel) }
    }

    public func cropping(to rect: CGRect) -> CGImage? {
        let r = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
        let rowBytes = w * format.bytesPerPixel
        var out = [UInt8](repeating: 0, count: rowBytes * h)
        for row in 0..<h {
            let source = (y0 + row) * bytesPerRow + x0 * format.bytesPerPixel
            out.replaceSubrange(row * rowBytes..<(row + 1) * rowBytes, with: bytes[source..<source + rowBytes])
        }
        return CGImage(width: w, height: h, bytesPerRow: rowBytes, format: format, space: colorSpace, bitmapInfo: bitmapInfo, bytes: out)
    }

    public func copy() -> CGImage? { self }

    /// Straight-alpha RGBA bytes, rows top to bottom.
    public func _rgbaBytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var index = 0
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
                if a > 0 {
                    out[index] = byte(r / a); out[index + 1] = byte(g / a); out[index + 2] = byte(b / a)
                }
                out[index + 3] = byte(a)
                index += 4
            }
        }
        return out
    }

    /// The image as an (uncompressed) PNG file.
    public func _pngData() -> Data { PNG.encode(width: width, height: height, rgba: _rgbaBytes()) }

    public static func == (lhs: CGImage, rhs: CGImage) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A minimal PNG writer: 8-bit RGBA, stored (uncompressed) deflate blocks.
enum PNG {
    static func encode(width: Int, height: Int, rgba: [UInt8]) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height {
            raw.append(0)
            raw += rgba[y * width * 4..<(y + 1) * width * 4]
        }
        var zlib: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let count = min(65535, raw.count - offset)
            let final: UInt8 = offset + count == raw.count ? 1 : 0
            zlib += [final, UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            zlib += raw[offset..<offset + count]
            offset += count
        } while offset < raw.count
        var s1: UInt32 = 1, s2: UInt32 = 0
        for byte in raw { s1 = (s1 + UInt32(byte)) % 65521; s2 = (s2 + s1) % 65521 }
        zlib += bigEndian((s2 << 16) | s1)

        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        func chunk(_ type: String, _ body: [UInt8]) {
            let typeBytes = Array(type.utf8)
            png += bigEndian(UInt32(body.count)) + typeBytes + body
            png += bigEndian(crc(typeBytes + body))
        }
        chunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [8, 6, 0, 0, 0])
        chunk("IDAT", zlib)
        chunk("IEND", [])
        return Data(png)
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
