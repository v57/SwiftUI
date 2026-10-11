#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

// MARK: - GObject glue

/// GObject instance pointers are passed around as raw pointers; these cast to the GTK type a
/// function expects (`GTK_WIDGET(x)` etc. are macros Swift can't import).
@inline(__always) func widget(_ object: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<GtkWidget>? { sui_widget(object) }
@inline(__always) func raw<T>(_ pointer: UnsafeMutablePointer<T>?) -> UnsafeMutableRawPointer? { UnsafeMutableRawPointer(pointer) }

/// Connects a C callback to a GObject signal. `callback` must be a `@convention(c)` function;
/// `data` is passed back as the last argument.
@discardableResult
func connect<F>(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ data: UnsafeMutableRawPointer?, _ callback: F) -> UInt {
    UInt(sui_signal_connect(instance, signal, unsafeBitCast(callback, to: GCallback.self), data))
}

/// An unretained pointer to `object` for C callbacks (the object outlives the connection).
func unretained(_ object: AnyObject) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(object).toOpaque()
}

func object<T: AnyObject>(_ pointer: UnsafeMutableRawPointer?, as type: T.Type = T.self) -> T {
    Unmanaged<T>.fromOpaque(pointer!).takeUnretainedValue()
}

extension Bool {
    var gboolean: gboolean { self ? 1 : 0 }
}

// MARK: - Main loop integration

/// GTK owns the main loop (`gtk_main`), so the work Foundation and Swift concurrency put on the
/// main thread must be serviced from it: the main dispatch queue (DispatchQueue.main, MainActor
/// tasks) wakes GLib through libdispatch's main-queue eventfd, and `RunLoop.main` timers are
/// fired by arming a GLib timeout for the run loop's next fire date.
@MainActor
enum GtkMainLoop {
    private static var installed = false
    private static var timerSource: guint = 0

    static func install() {
        guard !installed else { return }
        installed = true
        let fd = _dispatch_get_main_queue_handle_4CF()
        let callback: @convention(c) (Int32, GIOCondition, gpointer?) -> gboolean = { fd, _, _ in
            sui_drain_fd(fd)
            _dispatch_main_queue_callback_4CF(nil)
            MainActor.assumeIsolated { GtkMainLoop.serviceTimers() }
            return 1
        }
        _ = g_unix_fd_add_full(G_PRIORITY_DEFAULT, fd, G_IO_IN, callback, nil, nil)
        // Work queued before the loop started.
        _dispatch_main_queue_callback_4CF(nil)
    }

    /// Fires due `RunLoop.main` timers and arms a GLib timeout for the next one.
    static func serviceTimers() {
        if timerSource != 0 {
            g_source_remove(timerSource)
            timerSource = 0
        }
        guard let next = RunLoop.main.limitDate(forMode: .default) else { return }
        let delay = next.timeIntervalSinceNow
        guard delay < 86_400 else { return }
        let milliseconds = guint(max(0, (delay * 1000).rounded(.up)))
        let callback: @convention(c) (gpointer?) -> gboolean = { _ in
            MainActor.assumeIsolated {
                GtkMainLoop.timerSource = 0
                GtkMainLoop.serviceTimers()
            }
            return 0
        }
        timerSource = g_timeout_add_full(G_PRIORITY_DEFAULT, milliseconds, callback, nil, nil)
    }
}

@_silgen_name("_dispatch_get_main_queue_handle_4CF")
func _dispatch_get_main_queue_handle_4CF() -> Int32

@_silgen_name("_dispatch_main_queue_callback_4CF")
func _dispatch_main_queue_callback_4CF(_ message: UnsafeMutableRawPointer?)

/// `SWIFTUI_GTK_DEBUG=<level>` logs to stderr: 1 input events and hit paths, 2 also the render
/// tree on each click, 3 also content updates and animation frames.
enum GtkDebug {
    static let level = Int(ProcessInfo.processInfo.environment["SWIFTUI_GTK_DEBUG"] ?? "") ?? 0
    static var enabled: Bool { level > 0 }

    static func log(_ message: @autoclosure () -> String, level required: Int = 1) {
        guard level >= required else { return }
        FileHandle.standardError.write(Data(("[SwiftUIGtk] " + message() + "\n").utf8))
    }
}

/// Monotonic seconds (animation clock).
func monotonicSeconds() -> Double { Double(g_get_monotonic_time()) / 1_000_000 }

// MARK: - Cairo helpers

typealias Cairo = OpaquePointer

extension Color.Resolved {
    func set(_ cr: Cairo, opacity factor: Double = 1) {
        cairo_set_source_rgba(cr, Double(red), Double(green), Double(blue), Double(opacity) * factor)
    }

    init(_ rgba: GdkRGBA) {
        self.init(red: Float(rgba.red), green: Float(rgba.green), blue: Float(rgba.blue), opacity: Float(rgba.alpha))
    }

    var gdk: GdkRGBA { GdkRGBA(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(opacity)) }

    static let black = Color.Resolved(red: 0, green: 0, blue: 0)
    static let white = Color.Resolved(red: 1, green: 1, blue: 1)
}

/// Appends a SwiftUI path to the current cairo path (scaled from `pathSize` to `size` when given).
func addPath(_ cr: Cairo, _ path: Path, scaleX: CGFloat = 1, scaleY: CGFloat = 1) {
    var current = CGPoint.zero
    func p(_ point: CGPoint) -> (Double, Double) { (Double(point.x * scaleX), Double(point.y * scaleY)) }
    for element in path.elements {
        switch element {
        case .move(let to):
            let (x, y) = p(to); cairo_move_to(cr, x, y); current = to
        case .line(let to):
            let (x, y) = p(to); cairo_line_to(cr, x, y); current = to
        case let .quadCurve(to, control):
            // Quadratic → cubic.
            let c1 = CGPoint(x: current.x + 2 / 3 * (control.x - current.x), y: current.y + 2 / 3 * (control.y - current.y))
            let c2 = CGPoint(x: to.x + 2 / 3 * (control.x - to.x), y: to.y + 2 / 3 * (control.y - to.y))
            let (x1, y1) = p(c1), (x2, y2) = p(c2), (x, y) = p(to)
            cairo_curve_to(cr, x1, y1, x2, y2, x, y)
            current = to
        case let .curve(to, control1, control2):
            let (x1, y1) = p(control1), (x2, y2) = p(control2), (x, y) = p(to)
            cairo_curve_to(cr, x1, y1, x2, y2, x, y)
            current = to
        case .closeSubpath:
            cairo_close_path(cr)
        }
    }
}

func roundedRect(_ cr: Cairo, _ rect: CGRect, radius: CGFloat) {
    let r = Double(max(0, min(radius, min(rect.width, rect.height) / 2)))
    let x = Double(rect.minX), y = Double(rect.minY), w = Double(rect.width), h = Double(rect.height)
    cairo_new_sub_path(cr)
    cairo_arc(cr, x + w - r, y + r, r, -.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, .pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, .pi / 2, .pi)
    cairo_arc(cr, x + r, y + r, r, .pi, 3 * .pi / 2)
    cairo_close_path(cr)
}

/// Applies a stroke style (caps, joins, dashes) and line width.
func applyStroke(_ cr: Cairo, width: CGFloat, style: StrokeStyle?) {
    cairo_set_line_width(cr, Double(width))
    guard let style else {
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
        cairo_set_dash(cr, nil, 0, 0)
        return
    }
    switch style.lineCap {
    case .round: cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    case .square: cairo_set_line_cap(cr, CAIRO_LINE_CAP_SQUARE)
    default: cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
    }
    switch style.lineJoin {
    case .round: cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    case .bevel: cairo_set_line_join(cr, CAIRO_LINE_JOIN_BEVEL)
    default: cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
    }
    cairo_set_miter_limit(cr, Double(style.miterLimit))
    let dashes = style.dash.map { Double($0) }
    if dashes.count >= 1, dashes.contains(where: { $0 > 0 }) {
        dashes.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, Int32($0.count), Double(style.dashPhase)) }
    } else {
        cairo_set_dash(cr, nil, 0, 0)
    }
}

/// A cairo pattern for a gradient laid out in a `size` box.
func gradientPattern(_ gradient: ResolvedGradient, size: CGSize) -> OpaquePointer? {
    let w = Double(size.width), h = Double(size.height)
    let pattern: OpaquePointer?
    let stops = gradient.stops
    switch gradient.kind {
    case let .linear(start, end):
        pattern = cairo_pattern_create_linear(Double(start.x) * w, Double(start.y) * h, Double(end.x) * w, Double(end.y) * h)
    case let .radial(center, startRadius, endRadius):
        let cx = Double(center.x) * w, cy = Double(center.y) * h
        pattern = cairo_pattern_create_radial(cx, cy, Double(startRadius), cx, cy, Double(endRadius))
    case let .elliptical(center, startFraction, endFraction):
        // A radial gradient in a unit circle, scaled to the box.
        pattern = cairo_pattern_create_radial(0, 0, Double(startFraction) * 0.5, 0, 0, Double(endFraction) * 0.5)
        var matrix = cairo_matrix_t()
        cairo_matrix_init_scale(&matrix, 1 / max(w, 0.001), 1 / max(h, 0.001))
        cairo_matrix_translate(&matrix, -Double(center.x) * w, -Double(center.y) * h)
        cairo_pattern_set_matrix(pattern, &matrix)
    case let .angular(center, startAngle, endAngle):
        // Cairo has no conic gradient: a mesh of wedges approximates it.
        let cx = Double(center.x) * w, cy = Double(center.y) * h
        let radius = hypot(max(cx, w - cx), max(cy, h - cy)) + 1
        let mesh = cairo_pattern_create_mesh()
        let segments = 64
        let span = endAngle - startAngle
        func color(at t: Double) -> Color.Resolved { ResolvedGradientSampler.color(stops, at: CGFloat(t)) }
        for i in 0..<segments {
            let t0 = Double(i) / Double(segments), t1 = Double(i + 1) / Double(segments)
            let a0 = startAngle + span * t0, a1 = startAngle + span * t1
            let c0 = color(at: t0), c1 = color(at: t1)
            cairo_mesh_pattern_begin_patch(mesh)
            cairo_mesh_pattern_move_to(mesh, cx, cy)
            cairo_mesh_pattern_line_to(mesh, cx + radius * cos(a0), cy + radius * sin(a0))
            cairo_mesh_pattern_line_to(mesh, cx + radius * cos(a1), cy + radius * sin(a1))
            cairo_mesh_pattern_line_to(mesh, cx, cy)
            for (index, c) in [c0, c0, c1, c1].enumerated() {
                cairo_mesh_pattern_set_corner_color_rgba(mesh, UInt32(index), Double(c.red), Double(c.green), Double(c.blue), Double(c.opacity))
            }
            cairo_mesh_pattern_end_patch(mesh)
        }
        return mesh
    }
    if stops.isEmpty { cairo_pattern_add_color_stop_rgba(pattern, 0, 0, 0, 0, 1) }
    for stop in stops {
        cairo_pattern_add_color_stop_rgba(pattern, Double(stop.location), Double(stop.color.red), Double(stop.color.green),
                                          Double(stop.color.blue), Double(stop.color.opacity))
    }
    cairo_pattern_set_extend(pattern, CAIRO_EXTEND_PAD)
    return pattern
}

enum ResolvedGradientSampler {
    static func color(_ stops: [ResolvedGradient.Stop], at t: CGFloat) -> Color.Resolved {
        guard let first = stops.first else { return .black }
        if t <= first.location { return first.color }
        for (a, b) in zip(stops, stops.dropFirst()) where t <= b.location {
            let f = Float((t - a.location) / max(b.location - a.location, 0.0001))
            return Color.Resolved(red: a.color.red + (b.color.red - a.color.red) * f, green: a.color.green + (b.color.green - a.color.green) * f,
                                  blue: a.color.blue + (b.color.blue - a.color.blue) * f, opacity: a.color.opacity + (b.color.opacity - a.color.opacity) * f)
        }
        return stops.last!.color
    }
}

/// Sets the source to a paint (color or gradient over `size`).
func setPaint(_ cr: Cairo, _ paint: ResolvedPaint, size: CGSize) {
    switch paint {
    case .color(let color):
        color.set(cr)
    case .gradient(let gradient):
        let pattern = gradientPattern(gradient, size: size)
        cairo_set_source(cr, pattern)
        cairo_pattern_destroy(pattern)
    }
}
#endif
