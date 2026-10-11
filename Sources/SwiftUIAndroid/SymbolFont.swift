#if os(Android) || os(Linux) || os(Windows)
import Foundation
#if os(Android)
import CSwiftUIAndroid
#elseif os(Windows)
import CSwiftUIWinUI
#endif
import _SwiftUICore

/// `Image(systemName:)` on Android, Linux and Windows (SwiftUIGtk and SwiftUIWinUI link this
/// file): SF Symbols may only
/// be used on Apple platforms, so symbol names resolve to **Material Symbols** (Apache 2.0, a variable font with a fill axis) glyphs,
/// addressed by their ligature names. `SymbolNames.table` maps SF names to Material names;
/// variants (`.fill`, `.circle`, ...) fall back to their base symbol, and unknown names show a
/// placeholder glyph (logged once).
enum SymbolFont {
    struct Glyph: Hashable {
        /// Material Symbols ligature (the glyph's name).
        var text: String
        /// Draw with the font's FILL axis at 1.
        var filled: Bool
    }

    /// Material glyphs fill their em square; SF Symbols of the same point size are ~1.2× taller
    /// than the font's cap height. Scaling by this keeps symbol frames close to SwiftUI's.
    static let glyphScale: CGFloat = 1.2

    static func scaleFactor(_ scale: Image.Scale) -> CGFloat {
        switch scale {
        case .small: 0.8
        case .medium: 1
        case .large: 1.3
        }
    }

    static func glyphSize(_ image: ResolvedImage) -> CGFloat {
        image.pointSize * scaleFactor(image.scale) * glyphScale
    }

    static func glyph(for image: ResolvedImage) -> Glyph {
        if case .system(let name) = image.source { return glyph(forSystemName: name) }
        return Glyph(text: "image", filled: false)
    }

    nonisolated(unsafe) private static var cache: [String: Glyph] = [:]
    nonisolated(unsafe) private static var warned: Set<String> = []

    static func glyph(forSystemName name: String) -> Glyph {
        if let cached = cache[name] { return cached }
        let glyph = resolve(name)
        cache[name] = glyph
        return glyph
    }

    /// Suffixes that select a variant of the base symbol.
    private static let fillSuffix = ".fill"

    private static func resolve(_ name: String) -> Glyph {
        if let direct = SymbolNames.table[name] { return direct }
        // `x.fill` → `x`, filled.
        if name.hasSuffix(fillSuffix) {
            let base = String(name.dropLast(fillSuffix.count))
            if let glyph = SymbolNames.table[base] { return Glyph(text: glyph.text, filled: true) }
        }
        // Drop trailing components (`person.crop.circle.badge.plus` → `person.crop.circle` → ...).
        var candidate = name
        var filled = false
        while let dot = candidate.lastIndex(of: ".") {
            if candidate[dot...] == fillSuffix { filled = true }
            candidate = String(candidate[..<dot])
            if let glyph = SymbolNames.table[candidate] { return Glyph(text: glyph.text, filled: glyph.filled || filled) }
            if let glyph = SymbolNames.table[candidate + fillSuffix] { return Glyph(text: glyph.text, filled: true) }
        }
        if !warned.contains(name) {
            warned.insert(name)
            let message = "SF Symbol '\(name)' has no Material Symbols mapping (SymbolNames.table); showing a placeholder"
            #if os(Android) || os(Windows)
            sui_log(5, message)
            #else
            FileHandle.standardError.write(Data(("SwiftUI: " + message + "\n").utf8))
            #endif
        }
        return Glyph(text: "help", filled: false)
    }
}
#endif
