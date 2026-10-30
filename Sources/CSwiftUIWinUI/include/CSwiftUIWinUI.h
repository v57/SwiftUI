// Glue between the Swift backend (SwiftUIWinUI) and the C# WinUI 3 host (Windows/SwiftUIHost).
// The host loads the app DLL, registers its callbacks with `swiftui_register` (Swift → C#) and
// calls the exported swiftui_* functions (C# → Swift, implemented in Swift with @_cdecl).
// Everything runs on the host's UI thread (the process's main thread).
#pragma once
#ifdef _WIN32
#include <stdbool.h>
#include <stdint.h>

/// A GCHandle of a host object (a C# `HostView`).
typedef void *sui_ref;

/// Host functions Swift calls (C# `[UnmanagedCallersOnly]` methods).
typedef struct sui_callbacks {
    /// Debug output (level: 4 info, 5 warning, 6 error).
    void (*log)(int32_t level, const char *message);
    /// HostView.Apply: applies a batch of render commands.
    void (*host_apply)(sui_ref host, const void *bytes, int32_t length);
    /// HostView.RequestFrame: one CompositionTarget.Rendering callback (→ swiftui_frame).
    void (*host_request_frame)(sui_ref host);
    /// HostView.Platform(op, argument): platform services. Returns a UTF-8 string allocated with
    /// `alloc` (Swift frees it with `free`), or NULL.
    char *(*host_platform)(sui_ref host, int32_t op, const char *argument);
    /// TextMeasure.Measure(spec, maxWidth, out): out = width, height, first baseline, line height.
    void (*measure_text)(const void *spec, int32_t length, float maxWidth, float *out);
    /// Frees a GCHandle (a host the Swift side no longer uses).
    void (*release_ref)(sui_ref ref);
    /// Images.Decode(bytes, out): decodes PNG/JPEG/... into a bitmap the host keeps; out = pixel
    /// size. Returns the id, or -1.
    int32_t (*decode_image)(const void *bytes, int32_t length, int32_t *size);
    void (*release_image)(int32_t id);
    /// Wakes the main loop after `seconds` (Foundation run loop timers); negative disarms.
    void (*arm_timer)(double seconds);
    /// Opens a window showing `scene` (an index into the registered scenes); the host creates a
    /// HostView, which calls swiftui_create_host. `value` identifies a presented value (or -1).
    void (*open_window)(int32_t scene, int64_t value, const char *title, float width, float height);
    /// Closes the window of a host.
    void (*close_window)(sui_ref host);
    /// Memory for strings returned to Swift.
    void (*free)(void *pointer);
    /// Images.FromPixels: a bitmap from BGRA rows as they are (premultiplied; `opaque`: the fourth byte isn't
    /// alpha), with no encoding, for images replaced many times a second (video). Returns the id, or -1.
    int32_t (*pixel_image)(const void *bgra, int32_t width, int32_t height, int32_t bytesPerRow, bool opaque);
} sui_callbacks;

// MARK: Swift → C# (through the registered callbacks; same API as CSwiftUIAndroid)
void sui_log(int priority, const char *message);
void sui_host_apply(sui_ref host, const void *bytes, int32_t length);
void sui_host_request_frame(sui_ref host);
/// Returns a malloc'd string (caller frees) or NULL.
char *sui_host_platform(sui_ref host, int32_t op, const char *argument);
void sui_measure_text(const void *spec, int32_t length, float maxWidth, float *out);
void sui_delete_global_ref(sui_ref ref);
int32_t sui_decode_image(const void *bytes, int32_t length, int32_t *size);
/// -1 when the host has no pixel images (an older host): use sui_decode_image.
int32_t sui_pixel_image(const void *bgra, int32_t width, int32_t height, int32_t bytesPerRow, bool opaque);
void sui_release_image(int32_t id);
void sui_main_loop_arm_timer(double seconds);
void sui_open_window(int32_t scene, int64_t value, const char *title, float width, float height);
void sui_close_window(sui_ref host);

// MARK: Exported to the host (bridge.c)

__declspec(dllexport) void swiftui_register(const sui_callbacks *callbacks);
/// Runs the app's `main` (the `@main App`): registers the scenes and opens the launch windows.
__declspec(dllexport) bool swiftui_run_main(void);
__declspec(dllexport) void *swiftui_main_queue_handle(void);
__declspec(dllexport) void swiftui_drain_main_queue(void);

// Implemented in Swift (@_cdecl) and exported from the app DLL (see bridge.c):
// int64_t swiftui_create_host(sui_ref hostView, int32_t scene, int64_t value);
// void swiftui_destroy_host(int64_t host);  (the window closed)
// void swiftui_set_size(int64_t host, float width, float height, float scale);
// void swiftui_set_environment(int64_t host, int32_t key, int32_t value);
// void swiftui_event(int64_t host, int32_t node, int32_t type, double a, double b, double c, const char *text);
// void swiftui_frame(int64_t host, double seconds);
// bool swiftui_back(int64_t host);
// void swiftui_timer_fired(void);
// bool swiftui_key(int64_t host, int32_t code, const char *characters, int32_t modifiers, int32_t phase);
// bool swiftui_raw_input(int64_t host, int32_t node, const char *event, double x, double y, int32_t modifiers);
// int32_t swiftui_inspect(int64_t host, char *buffer, int32_t capacity);  (the element channel's JSON)
#endif
