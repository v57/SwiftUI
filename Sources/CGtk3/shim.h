// GTK 3 for the SwiftUI2 GTK backend. Swift can't use GObject's cast and signal macros, so the
// few the backend needs are wrapped here as inline functions.
#ifndef SWIFTUI2_CGTK3_SHIM_H
#define SWIFTUI2_CGTK3_SHIM_H

#include <gtk/gtk.h>
#include <glib-unix.h>
#include <pango/pangocairo.h>
#include <fontconfig/fontconfig.h>
#include <string.h>
#include <unistd.h>

static inline gulong sui_signal_connect(gpointer instance, const char *signal, GCallback callback, gpointer data) {
    return g_signal_connect_data(instance, signal, callback, data, NULL, (GConnectFlags)0);
}

static inline GtkWidget *sui_widget(gpointer object) { return GTK_WIDGET(object); }
static inline GtkWindow *sui_window(gpointer object) { return GTK_WINDOW(object); }
static inline GtkContainer *sui_container(gpointer object) { return GTK_CONTAINER(object); }
static inline GtkFixed *sui_fixed(gpointer object) { return GTK_FIXED(object); }
static inline GtkOverlay *sui_overlay(gpointer object) { return GTK_OVERLAY(object); }
static inline GtkEntry *sui_entry(gpointer object) { return GTK_ENTRY(object); }
static inline GtkEditable *sui_editable(gpointer object) { return GTK_EDITABLE(object); }
static inline GtkTextView *sui_text_view(gpointer object) { return GTK_TEXT_VIEW(object); }
static inline GtkHeaderBar *sui_header_bar(gpointer object) { return GTK_HEADER_BAR(object); }
static inline GtkButton *sui_button(gpointer object) { return GTK_BUTTON(object); }
static inline GtkBox *sui_box(gpointer object) { return GTK_BOX(object); }
static inline GtkPopover *sui_popover(gpointer object) { return GTK_POPOVER(object); }
static inline GtkCalendar *sui_calendar(gpointer object) { return GTK_CALENDAR(object); }
static inline GtkSpinButton *sui_spin_button(gpointer object) { return GTK_SPIN_BUTTON(object); }
static inline GtkDialog *sui_dialog(gpointer object) { return GTK_DIALOG(object); }
static inline GtkColorChooser *sui_color_chooser(gpointer object) { return GTK_COLOR_CHOOSER(object); }
static inline GtkFileChooser *sui_file_chooser(gpointer object) { return GTK_FILE_CHOOSER(object); }
static inline GtkScrolledWindow *sui_scrolled_window(gpointer object) { return GTK_SCROLLED_WINDOW(object); }
static inline GtkSearchEntry *sui_search_entry(gpointer object) { return GTK_SEARCH_ENTRY(object); }
static inline GtkMenuButton *sui_menu_button(gpointer object) { return GTK_MENU_BUTTON(object); }

static inline GdkEventType sui_event_type(GdkEvent *event) { return event->type; }

/// A style context for a (CSS node) path such as {"button"} or {"scale", "trough", "slider"},
/// with optional style classes on the last node. Used to draw controls with the GTK theme.
static inline GtkStyleContext *sui_style_context(const char **names, int count, const char *classes) {
    GtkWidgetPath *path = gtk_widget_path_new();
    for (int i = 0; i < count; i++) {
        GType type = G_TYPE_NONE;
        if (strcmp(names[i], "button") == 0) type = GTK_TYPE_BUTTON;
        else if (strcmp(names[i], "entry") == 0) type = GTK_TYPE_ENTRY;
        else if (strcmp(names[i], "scale") == 0) type = GTK_TYPE_SCALE;
        else if (strcmp(names[i], "switch") == 0) type = GTK_TYPE_SWITCH;
        else if (strcmp(names[i], "checkbutton") == 0) type = GTK_TYPE_CHECK_BUTTON;
        else if (strcmp(names[i], "radiobutton") == 0) type = GTK_TYPE_RADIO_BUTTON;
        else if (strcmp(names[i], "scrollbar") == 0) type = GTK_TYPE_SCROLLBAR;
        else if (strcmp(names[i], "window") == 0) type = GTK_TYPE_WINDOW;
        else if (strcmp(names[i], "label") == 0) type = GTK_TYPE_LABEL;
        gtk_widget_path_append_type(path, type);
        gtk_widget_path_iter_set_object_name(path, -1, names[i]);
    }
    if (classes != NULL) {
        gchar **parts = g_strsplit(classes, " ", -1);
        for (gchar **part = parts; *part != NULL; part++) {
            if (**part != '\0') gtk_widget_path_iter_add_class(path, -1, *part);
        }
        g_strfreev(parts);
    }
    GtkStyleContext *context = gtk_style_context_new();
    gtk_style_context_set_path(context, path);
    gtk_style_context_set_screen(context, gdk_screen_get_default());
    gtk_widget_path_unref(path);
    return context;
}

static inline GdkRGBA sui_style_color(GtkStyleContext *context, GtkStateFlags state) {
    GdkRGBA color;
    gtk_style_context_set_state(context, state);
    gtk_style_context_get_color(context, state, &color);
    return color;
}

static inline int sui_style_int(GtkStyleContext *context, GtkStateFlags state, const char *property) {
    int value = 0;
    gtk_style_context_get(context, state, property, &value, NULL);
    return value;
}

static inline GdkRGBA sui_style_background(GtkStyleContext *context, GtkStateFlags state) {
    GdkRGBA *color = NULL;
    GdkRGBA result = {0, 0, 0, 0};
    gtk_style_context_get(context, state, "background-color", &color, NULL);
    if (color != NULL) { result = *color; gdk_rgba_free(color); }
    return result;
}

static inline void sui_render_box(GtkStyleContext *context, GtkStateFlags state, cairo_t *cr, double x, double y, double w, double h) {
    gtk_style_context_set_state(context, state);
    gtk_render_background(context, cr, x, y, w, h);
    gtk_render_frame(context, cr, x, y, w, h);
}

static inline void sui_render_check(GtkStyleContext *context, GtkStateFlags state, cairo_t *cr, double x, double y, double w, double h) {
    gtk_style_context_set_state(context, state);
    gtk_render_background(context, cr, x, y, w, h);
    gtk_render_frame(context, cr, x, y, w, h);
    gtk_render_check(context, cr, x, y, w, h);
}

static inline void sui_render_option(GtkStyleContext *context, GtkStateFlags state, cairo_t *cr, double x, double y, double w, double h) {
    gtk_style_context_set_state(context, state);
    gtk_render_background(context, cr, x, y, w, h);
    gtk_render_frame(context, cr, x, y, w, h);
    gtk_render_option(context, cr, x, y, w, h);
}

static inline void sui_render_slider(GtkStyleContext *context, GtkStateFlags state, cairo_t *cr, double x, double y, double w, double h) {
    gtk_style_context_set_state(context, state);
    gtk_render_slider(context, cr, x, y, w, h, GTK_ORIENTATION_HORIZONTAL);
}

static inline void sui_render_focus(GtkStyleContext *context, cairo_t *cr, double x, double y, double w, double h) {
    gtk_render_focus(context, cr, x, y, w, h);
}

/// The default GTK font ("Ubuntu Sans 11" → family and size in points).
static inline char *sui_default_font_name(void) {
    gchar *name = NULL;
    GtkSettings *settings = gtk_settings_get_default();
    if (settings != NULL) g_object_get(settings, "gtk-font-name", &name, NULL);
    return name;
}

static inline gboolean sui_prefers_dark(void) {
    gboolean dark = FALSE;
    gchar *theme = NULL;
    GtkSettings *settings = gtk_settings_get_default();
    if (settings == NULL) return FALSE;
    g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, "gtk-theme-name", &theme, NULL);
    if (theme != NULL) {
        if (g_str_has_suffix(theme, "-dark") || g_str_has_suffix(theme, "-Dark")) dark = TRUE;
        g_free(theme);
    }
    return dark;
}

static inline void sui_set_prefer_dark(gboolean dark) {
    GtkSettings *settings = gtk_settings_get_default();
    if (settings != NULL) g_object_set(settings, "gtk-application-prefer-dark-theme", dark, NULL);
}

/// Adds a font file to fontconfig's application fonts (the symbol font).
static inline gboolean sui_add_font_file(const char *path) {
    return FcConfigAppFontAddFile(FcConfigGetCurrent(), (const FcChar8 *)path);
}

static inline gboolean sui_has_font_family(const char *family) {
    PangoFontMap *map = pango_cairo_font_map_get_default();
    PangoFontFamily **families = NULL;
    int count = 0;
    gboolean found = FALSE;
    pango_font_map_list_families(map, &families, &count);
    for (int i = 0; i < count && !found; i++) {
        if (g_ascii_strcasecmp(pango_font_family_get_name(families[i]), family) == 0) found = TRUE;
    }
    g_free(families);
    return found;
}

/// The pango-cairo font map caches the font set; reload it after adding application fonts.
static inline void sui_reload_font_map(void) {
    PangoFontMap *map = pango_cairo_font_map_new();
    pango_cairo_font_map_set_default(PANGO_CAIRO_FONT_MAP(map));
    g_object_unref(map);
}

static inline void sui_drain_fd(int fd) {
    char buffer[64];
    while (read(fd, buffer, sizeof buffer) > 0) {}
}

static inline guint sui_keyval_to_lower(guint keyval) { return gdk_keyval_to_lower(keyval); }

#endif
