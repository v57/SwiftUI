#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// Native GTK dialogs: file chooser (`fileImporter`/`fileExporter`), color chooser (`ColorPicker`)
/// and the date popover (`DatePicker`).
@MainActor
enum GtkDialogs {
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static func presentFileDialog(_ request: FileDialogRequest, parent: UnsafeMutablePointer<GtkWidget>?, completion: @escaping @MainActor ([URL]?) -> Void) {
        let action: GtkFileChooserAction
        switch request.kind {
        case .open: action = request.canChooseDirectories ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_OPEN
        case .save: action = GTK_FILE_CHOOSER_ACTION_SAVE
        }
        let title = request.options.message ?? (request.kind == .open ? "Open" : "Save")
        let accept = request.options.confirmationLabel ?? (request.kind == .open ? "_Open" : "_Save")
        let dialog = gtk_file_chooser_native_new(title, parent.map { sui_window(raw($0)) }, action, accept, "_Cancel")!
        let chooser = sui_file_chooser(UnsafeMutableRawPointer(dialog))
        gtk_file_chooser_set_select_multiple(chooser, request.allowsMultipleSelection.gboolean)
        gtk_file_chooser_set_show_hidden(chooser, request.options.showsHiddenFiles.gboolean)
        if request.kind == .save {
            gtk_file_chooser_set_do_overwrite_confirmation(chooser, 1)
            if let name = request.defaultFilename { gtk_file_chooser_set_current_name(chooser, name) }
        }
        if let directory = request.options.defaultDirectory {
            gtk_file_chooser_set_current_folder(chooser, directory.path)
        }
        let response = gtk_native_dialog_run(UnsafeMutablePointer(dialog))
        var urls: [URL]?
        if response == GTK_RESPONSE_ACCEPT.rawValue {
            urls = []
            var list = gtk_file_chooser_get_filenames(chooser)
            let head = list
            while let item = list {
                if let name = item.pointee.data?.assumingMemoryBound(to: CChar.self) {
                    urls?.append(URL(fileURLWithPath: String(cString: name)))
                    g_free(name)
                }
                list = item.pointee.next
            }
            g_slist_free(head)
        }
        g_object_unref(UnsafeMutableRawPointer(dialog))
        completion(urls)
    }

    static func chooseColor(_ color: Color.Resolved, parent: UnsafeMutablePointer<GtkWidget>?, completion: @escaping @MainActor (Color.Resolved) -> Void) {
        let dialog = gtk_color_chooser_dialog_new("Color", parent.map { sui_window(raw($0)) })!
        let chooser = sui_color_chooser(raw(dialog))
        gtk_color_chooser_set_use_alpha(chooser, 1)
        var rgba = color.gdk
        gtk_color_chooser_set_rgba(chooser, &rgba)
        let response = gtk_dialog_run(sui_dialog(raw(dialog)))
        if response == GTK_RESPONSE_OK.rawValue {
            gtk_color_chooser_get_rgba(chooser, &rgba)
            completion(Color.Resolved(rgba))
        }
        gtk_widget_destroy(dialog)
    }

    /// A popover with a calendar (date) and hour/minute spin buttons (time) pointing at `rect`
    /// of `relativeTo`.
    static func showDatePopover(_ picker: ResolvedDatePicker, relativeTo widget: UnsafeMutablePointer<GtkWidget>, rect: CGRect,
                                onChange: @escaping @MainActor (Date) -> Void) {
        let popover = gtk_popover_new(widget)!
        var gdkRect = GdkRectangle(x: Int32(rect.minX), y: Int32(rect.minY), width: Int32(rect.width), height: Int32(rect.height))
        gtk_popover_set_pointing_to(sui_popover(raw(popover)), &gdkRect)
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        gtk_container_set_border_width(sui_container(raw(box)), 8)
        gtk_container_add(sui_container(raw(popover)), box)
        let calendarTimeZone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = calendarTimeZone
        let state = Box(picker.date)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: picker.date)
        final class Context {
            let state: Box<Date>
            let onChange: @MainActor (Date) -> Void
            let calendar: Calendar
            let range: ClosedRange<Date>?
            var calendarWidget: UnsafeMutablePointer<GtkWidget>?
            var hour: UnsafeMutablePointer<GtkWidget>?
            var minute: UnsafeMutablePointer<GtkWidget>?
            init(state: Box<Date>, onChange: @escaping @MainActor (Date) -> Void, calendar: Calendar, range: ClosedRange<Date>?) {
                self.state = state; self.onChange = onChange; self.calendar = calendar; self.range = range
            }
            @MainActor func changed() {
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: state.value)
                if let calendarWidget {
                    var year: guint = 0, month: guint = 0, day: guint = 0
                    gtk_calendar_get_date(sui_calendar(raw(calendarWidget)), &year, &month, &day)
                    components.year = Int(year); components.month = Int(month) + 1; components.day = Int(day)
                }
                if let hour { components.hour = Int(gtk_spin_button_get_value_as_int(sui_spin_button(raw(hour)))) }
                if let minute { components.minute = Int(gtk_spin_button_get_value_as_int(sui_spin_button(raw(minute)))) }
                guard var date = calendar.date(from: components) else { return }
                if let range { date = min(max(date, range.lowerBound), range.upperBound) }
                guard date != state.value else { return }
                state.value = date
                onChange(date)
            }
        }
        let context = Context(state: state, onChange: onChange, calendar: calendar, range: picker.range)
        let data = Unmanaged.passRetained(context).toOpaque()
        let changed: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            MainActor.assumeIsolated { object(data, as: Context.self).changed() }
        }
        if picker.components.contains(.date) {
            let calendarWidget = gtk_calendar_new()!
            gtk_calendar_select_month(sui_calendar(raw(calendarWidget)), guint(components.month! - 1), guint(components.year!))
            gtk_calendar_select_day(sui_calendar(raw(calendarWidget)), guint(components.day!))
            gtk_box_pack_start(sui_box(raw(box)), calendarWidget, 0, 0, 0)
            context.calendarWidget = calendarWidget
            connect(raw(calendarWidget), "day-selected", data, changed)
        }
        if picker.components.contains(.hourAndMinute) {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
            let hour = gtk_spin_button_new_with_range(0, 23, 1)!
            let minute = gtk_spin_button_new_with_range(0, 59, 1)!
            gtk_spin_button_set_value(sui_spin_button(raw(hour)), Double(components.hour ?? 0))
            gtk_spin_button_set_value(sui_spin_button(raw(minute)), Double(components.minute ?? 0))
            gtk_spin_button_set_wrap(sui_spin_button(raw(minute)), 1)
            gtk_box_pack_start(sui_box(raw(row)), hour, 0, 0, 0)
            gtk_box_pack_start(sui_box(raw(row)), gtk_label_new(":"), 0, 0, 0)
            gtk_box_pack_start(sui_box(raw(row)), minute, 0, 0, 0)
            gtk_box_pack_start(sui_box(raw(box)), row, 0, 0, 0)
            context.hour = hour
            context.minute = minute
            connect(raw(hour), "value-changed", data, changed)
            connect(raw(minute), "value-changed", data, changed)
        }
        let closed: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { popover, data in
            Unmanaged<Context>.fromOpaque(data!).release()
            gtk_widget_destroy(sui_widget(popover))
        }
        connect(raw(popover), "closed", data, closed)
        gtk_widget_show_all(box)
        gtk_popover_popup(sui_popover(raw(popover)))
    }
}
#endif
