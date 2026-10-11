// JNI glue between the Swift backend (SwiftUIAndroid) and the Kotlin host (org.swiftui).
// Swift calls the sui_* functions; Kotlin's `org.swiftui.Native` methods call the swiftui_*
// functions that Swift exports with @_cdecl. Everything runs on the Android main thread.
#pragma once
#ifdef __ANDROID__
#include <stdbool.h>
#include <stdint.h>
#include <sys/system_properties.h>

/// A JNI global reference (jobject).
typedef void *sui_ref;

// MARK: Swift → Kotlin
void sui_log(int priority, const char *message);
/// HostView.apply(ByteBuffer): applies a batch of render commands.
void sui_host_apply(sui_ref host, const void *bytes, int32_t length);
/// HostView.requestFrame(): one Choreographer frame callback (→ swiftui_frame).
void sui_host_request_frame(sui_ref host);
/// HostView.platform(op, argument): platform services (open URL, haptics, share, ...).
/// Returns a string result (malloc'd, caller frees) or NULL.
char *sui_host_platform(sui_ref host, int32_t op, const char *argument);
/// TextMeasure.measure(spec, maxWidth, out): out = width, height, first baseline, line height.
void sui_measure_text(const void *spec, int32_t length, float maxWidth, float *out);
void sui_delete_global_ref(sui_ref ref);
/// Images.decode(ByteBuffer, out): decodes PNG/JPEG/WebP/... into a bitmap the host keeps
/// (Images.decoded[id]); out = width, height (px). Returns the id, or -1.
int32_t sui_decode_image(const void *bytes, int32_t length, int32_t *size);
/// Images.release(id): drops a decoded bitmap.
void sui_release_image(int32_t id);
/// Paths.op(ByteBuffer, op, evenOdd): boolean operation of two encoded paths (path a, path b).
/// Returns the encoded result (malloc'd; caller frees) and its length.
void *sui_path_op(const void *paths, int32_t length, int32_t op, bool evenOdd, int32_t *resultLength);

// MARK: Main loop
/// Drains libdispatch's main queue and fires Foundation run loop timers on the main ALooper.
/// Call on the main thread.
void sui_main_loop_install(void);
/// Wakes the main looper after `seconds` (timers); negative disarms.
void sui_main_loop_arm_timer(double seconds);

// MARK: Kotlin → Swift (implemented in Swift with @_cdecl)
int64_t swiftui_create_host(sui_ref hostView, float density, int32_t scene);
void swiftui_destroy_host(int64_t host);
void swiftui_set_size(int64_t host, float width, float height);
void swiftui_set_insets(int64_t host, float top, float left, float bottom, float right);
void swiftui_set_environment(int64_t host, int32_t key, int32_t value);
void swiftui_event(int64_t host, int32_t node, int32_t type, double a, double b, double c, const char *text);
void swiftui_frame(int64_t host, double seconds);
bool swiftui_back(int64_t host);
void swiftui_timer_fired(void);
#endif
