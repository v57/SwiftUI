#if canImport(AppKit)
import AppKit
import Symbols
import _SwiftUICore

extension ResolvedImage.Source {
    var isSymbol: Bool { if case .system = self { true } else { false } }
}

/// Content transitions run as Core Animation transitions on the view's layer.
@MainActor
enum ContentTransitions {
    static func fade(_ layer: CALayer?, duration: Double) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        layer?.add(transition, forKey: "contentTransition")
    }

    static func push(_ layer: CALayer?, duration: Double, fromTop: Bool) {
        let transition = CATransition()
        transition.type = .push
        // Layer coordinates are flipped in node views.
        transition.subtype = fromTop ? .fromBottom : .fromTop
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(transition, forKey: "contentTransition")
    }
}

/// Plays SwiftUI symbol effects with AppKit's symbol animations.
@MainActor
enum SymbolEffects {
    static func update(_ view: NSImageView, from old: [_SymbolEffectRequest], to new: [_SymbolEffectRequest]) {
        guard old != new else { return }
        let oldIndefinite = old.filter { $0.trigger == nil && $0.isActive }
        let newIndefinite = new.filter { $0.trigger == nil && $0.isActive }
        if oldIndefinite != newIndefinite {
            view.removeAllSymbolEffects(animated: false)
            for request in newIndefinite { addIndefinite(request, to: view) }
        }
        let oldDiscrete = old.filter { $0.trigger != nil }
        for (index, request) in new.filter({ $0.trigger != nil }).enumerated() {
            guard index < oldDiscrete.count, oldDiscrete[index].effect == request.effect, oldDiscrete[index].trigger != request.trigger else { continue }
            addDiscrete(request, to: view)
        }
    }

    static func replace(_ view: NSImageView, with image: NSImage, effect: ContentTransition._Kind) {
        var replace = Symbols.ReplaceSymbolEffect.replace
        if case .symbolEffect(let value?) = effect {
            if value.options.contains("downUp") { replace = replace.downUp }
            if value.options.contains("upUp") { replace = replace.upUp }
            if value.options.contains("offUp") { replace = replace.offUp }
            if value.options.contains("byLayer") { replace = replace.byLayer }
        }
        view.setSymbolImage(image, contentTransition: replace)
    }

    private static func options(_ options: _SwiftUICore.SymbolEffectOptions, discrete: Bool) -> Symbols.SymbolEffectOptions {
        var result: Symbols.SymbolEffectOptions
        switch options.repeatCount {
        case 0?: result = .nonRepeating
        case let count?: result = .repeat(count)
        case nil: result = discrete ? .default : .repeating
        }
        if options.speed != 1 { result = result.speed(options.speed) }
        return result
    }

    private static func has(_ request: _SymbolEffectRequest, _ option: String) -> Bool { request.effect.options.contains(option) }

    private static func addIndefinite(_ request: _SymbolEffectRequest, to view: NSImageView) {
        let options = options(request.options, discrete: false)
        switch request.effect.name {
        case "bounce":
            var effect = Symbols.BounceSymbolEffect.bounce
            if has(request, "up") { effect = effect.up }
            if has(request, "down") { effect = effect.down }
            if has(request, "byLayer") { effect = effect.byLayer }
            if has(request, "wholeSymbol") { effect = effect.wholeSymbol }
            view.addSymbolEffect(effect, options: options)
        case "pulse":
            var effect = Symbols.PulseSymbolEffect.pulse
            if has(request, "byLayer") { effect = effect.byLayer }
            if has(request, "wholeSymbol") { effect = effect.wholeSymbol }
            view.addSymbolEffect(effect, options: options)
        case "variableColor":
            var effect = Symbols.VariableColorSymbolEffect.variableColor
            if has(request, "iterative") { effect = effect.iterative }
            if has(request, "cumulative") { effect = effect.cumulative }
            if has(request, "reversing") { effect = effect.reversing }
            if has(request, "nonReversing") { effect = effect.nonReversing }
            if has(request, "dimInactiveLayers") { effect = effect.dimInactiveLayers }
            if has(request, "hideInactiveLayers") { effect = effect.hideInactiveLayers }
            view.addSymbolEffect(effect, options: options)
        case "scale":
            var effect = Symbols.ScaleSymbolEffect.scale
            if has(request, "up") { effect = effect.up }
            if has(request, "down") { effect = effect.down }
            if has(request, "byLayer") { effect = effect.byLayer }
            view.addSymbolEffect(effect, options: options)
        case "appear":
            var effect = Symbols.AppearSymbolEffect.appear
            if has(request, "up") { effect = effect.up }
            if has(request, "down") { effect = effect.down }
            if has(request, "byLayer") { effect = effect.byLayer }
            view.addSymbolEffect(effect, options: options)
        case "disappear":
            var effect = Symbols.DisappearSymbolEffect.disappear
            if has(request, "up") { effect = effect.up }
            if has(request, "down") { effect = effect.down }
            if has(request, "byLayer") { effect = effect.byLayer }
            view.addSymbolEffect(effect, options: options)
        default:
            if #available(macOS 15.0, *) { addIndefinite15(request, to: view, options: options) }
        }
    }

    @available(macOS 15.0, *)
    private static func addIndefinite15(_ request: _SymbolEffectRequest, to view: NSImageView, options: Symbols.SymbolEffectOptions) {
        switch request.effect.name {
        case "wiggle":
            var effect = Symbols.WiggleSymbolEffect.wiggle
            if has(request, "left") { effect = effect.left }
            if has(request, "right") { effect = effect.right }
            if has(request, "up") { effect = effect.up }
            if has(request, "down") { effect = effect.down }
            if has(request, "forward") { effect = effect.forward }
            if has(request, "backward") { effect = effect.backward }
            if has(request, "clockwise") { effect = effect.clockwise }
            if has(request, "counterClockwise") { effect = effect.counterClockwise }
            view.addSymbolEffect(effect, options: options)
        case "rotate":
            var effect = Symbols.RotateSymbolEffect.rotate
            if has(request, "clockwise") { effect = effect.clockwise }
            if has(request, "counterClockwise") { effect = effect.counterClockwise }
            if has(request, "byLayer") { effect = effect.byLayer }
            view.addSymbolEffect(effect, options: options)
        case "breathe":
            var effect = Symbols.BreatheSymbolEffect.breathe
            if has(request, "pulse") { effect = effect.pulse }
            if has(request, "plain") { effect = effect.plain }
            if has(request, "byLayer") { effect = effect.byLayer }
            view.addSymbolEffect(effect, options: options)
        default:
            break
        }
    }

    private static func addDiscrete(_ request: _SymbolEffectRequest, to view: NSImageView) {
        let options = options(request.options, discrete: true)
        switch request.effect.name {
        case "bounce":
            var effect = Symbols.BounceSymbolEffect.bounce
            if has(request, "up") { effect = effect.up }
            if has(request, "down") { effect = effect.down }
            if has(request, "byLayer") { effect = effect.byLayer }
            view.addSymbolEffect(effect, options: options)
        case "pulse":
            view.addSymbolEffect(Symbols.PulseSymbolEffect.pulse, options: options)
        case "variableColor":
            var effect = Symbols.VariableColorSymbolEffect.variableColor
            if has(request, "iterative") { effect = effect.iterative }
            if has(request, "cumulative") { effect = effect.cumulative }
            view.addSymbolEffect(effect, options: options)
        default:
            if #available(macOS 15.0, *) {
                switch request.effect.name {
                case "wiggle": view.addSymbolEffect(Symbols.WiggleSymbolEffect.wiggle, options: options)
                case "rotate": view.addSymbolEffect(Symbols.RotateSymbolEffect.rotate, options: options)
                case "breathe": view.addSymbolEffect(Symbols.BreatheSymbolEffect.breathe, options: options)
                default: break
                }
            }
        }
    }
}
#endif
