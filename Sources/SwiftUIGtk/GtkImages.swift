#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// A decoded image (`GdkPixbuf`), the backend's `PlatformImage` object.
final class GtkPixbuf {
    let pixbuf: OpaquePointer

    /// Takes ownership of a pixbuf reference.
    init(pixbuf: OpaquePointer) { self.pixbuf = pixbuf }

    deinit { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }

    var size: CGSize { CGSize(width: CGFloat(gdk_pixbuf_get_width(pixbuf)), height: CGFloat(gdk_pixbuf_get_height(pixbuf))) }
}

/// Named images: files in the app's resources (`<name>.png|jpg|jpeg|svg|webp` in the bundle's
/// resource directory, `Resources/` or `Assets/` next to the executable or the working directory),
/// then the icon theme (freedesktop icon names such as "folder" or "edit-copy-symbolic").
@MainActor
enum GtkImages {
    private static var cache: [String: GtkPixbuf?] = [:]
    private static let extensions = ["png", "jpg", "jpeg", "svg", "webp", "bmp"]

    private static var searchDirectories: [URL] {
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL { directories.append(resources) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for base in [executable, cwd] {
            directories.append(base)
            directories.append(base.appendingPathComponent("Resources"))
            directories.append(base.appendingPathComponent("Assets"))
        }
        // SwiftPM resource bundles next to the executable (`<Package>_<Target>.resources`).
        if let contents = try? FileManager.default.contentsOfDirectory(at: executable, includingPropertiesForKeys: nil) {
            directories += contents.filter { $0.pathExtension == "resources" }
        }
        return directories
    }

    static func load(named name: String) -> GtkPixbuf? {
        if let cached = cache[name] { return cached }
        var result: GtkPixbuf?
        outer: for directory in searchDirectories {
            for ext in extensions {
                let path = directory.appendingPathComponent(name + "." + ext).path
                guard FileManager.default.fileExists(atPath: path) else { continue }
                var error: UnsafeMutablePointer<GError>?
                if let pixbuf = gdk_pixbuf_new_from_file(path, &error) {
                    result = GtkPixbuf(pixbuf: pixbuf)
                    break outer
                }
                if let error { g_error_free(error) }
            }
        }
        if result == nil, let theme = gtk_icon_theme_get_default(), gtk_icon_theme_has_icon(theme, name) != 0 {
            var error: UnsafeMutablePointer<GError>?
            if let pixbuf = gtk_icon_theme_load_icon(theme, name, 32, GTK_ICON_LOOKUP_FORCE_SIZE, &error) {
                result = GtkPixbuf(pixbuf: pixbuf)
            }
            if let error { g_error_free(error) }
        }
        cache[name] = result
        return result
    }

    static func decode(_ data: Data) -> GtkPixbuf? {
        let loader = gdk_pixbuf_loader_new()!
        defer { g_object_unref(UnsafeMutableRawPointer(loader)) }
        var error: UnsafeMutablePointer<GError>?
        let written = data.withUnsafeBytes { buffer in
            gdk_pixbuf_loader_write(loader, buffer.bindMemory(to: guchar.self).baseAddress, gsize(buffer.count), &error)
        }
        if error != nil { g_error_free(error); error = nil }
        gdk_pixbuf_loader_close(loader, &error)
        if let error { g_error_free(error) }
        guard written != 0, let pixbuf = gdk_pixbuf_loader_get_pixbuf(loader) else { return nil }
        g_object_ref(UnsafeMutableRawPointer(pixbuf))
        return GtkPixbuf(pixbuf: pixbuf)
    }

    /// Draws a pixbuf stretched into a `size` box, optionally as a template in `tint`.
    static func draw(_ image: GtkPixbuf, in cr: Cairo, size: CGSize, tint: Color.Resolved?) {
        let natural = image.size
        guard natural.width > 0, natural.height > 0, size.width > 0, size.height > 0 else { return }
        cairo_save(cr)
        // Template images: the pixels become a mask for the tint (same CTM as the push).
        if tint != nil { cairo_push_group(cr) }
        cairo_save(cr)
        cairo_scale(cr, Double(size.width / natural.width), Double(size.height / natural.height))
        gdk_cairo_set_source_pixbuf(cr, image.pixbuf, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD)
        cairo_paint(cr)
        cairo_restore(cr)
        if let tint {
            let pattern = cairo_pop_group(cr)
            tint.set(cr)
            cairo_mask(cr, pattern)
            cairo_pattern_destroy(pattern)
        }
        cairo_restore(cr)
    }
}
#endif
