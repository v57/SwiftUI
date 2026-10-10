#ifdef _WIN32
#include "CSwiftUI2WinUI.h"
#include <stdio.h>
#include <string.h>

// The Swift entry points (@_cdecl in SwiftUI2WinUI) are exported from whichever DLL links this
// file: the app library the host loads.
#pragma comment(linker, "/EXPORT:swiftui2_create_host")
#pragma comment(linker, "/EXPORT:swiftui2_destroy_host")
#pragma comment(linker, "/EXPORT:swiftui2_set_size")
#pragma comment(linker, "/EXPORT:swiftui2_set_environment")
#pragma comment(linker, "/EXPORT:swiftui2_event")
#pragma comment(linker, "/EXPORT:swiftui2_frame")
#pragma comment(linker, "/EXPORT:swiftui2_back")
#pragma comment(linker, "/EXPORT:swiftui2_timer_fired")

// The `@main App` of the app library; libraries without one link the stub instead.
int main(int argc, char **argv);
int swiftui2_no_main(int argc, char **argv) { return -1; }
#pragma comment(linker, "/alternatename:main=swiftui2_no_main")

static sui_callbacks sui_host;

static void defaultLog(int32_t level, const char *message) {
    fprintf(stderr, "%s\n", message);
}

void swiftui2_register(const sui_callbacks *callbacks) {
    sui_host = *callbacks;
}

bool swiftui2_run_main(void) {
    static char *argv[] = {"swiftui2", NULL};
    if (main == swiftui2_no_main) {
        sui_log(6, "The app library has no SwiftUI2 App entry point (@main)");
        return false;
    }
    main(1, argv);
    return true;
}

// MARK: Swift → C#

void sui_log(int priority, const char *message) {
    if (sui_host.log) sui_host.log(priority, message); else defaultLog(priority, message);
}

void sui_host_apply(sui_ref host, const void *bytes, int32_t length) { sui_host.host_apply(host, bytes, length); }
void sui_host_request_frame(sui_ref host) { sui_host.host_request_frame(host); }

char *sui_host_platform(sui_ref host, int32_t op, const char *argument) {
    char *result = sui_host.host_platform(host, op, argument);
    if (!result) return NULL;
    char *copy = _strdup(result);
    sui_host.free(result);
    return copy;
}

void sui_measure_text(const void *spec, int32_t length, float maxWidth, float *out) { sui_host.measure_text(spec, length, maxWidth, out); }
void sui_delete_global_ref(sui_ref ref) { if (ref && sui_host.release_ref) sui_host.release_ref(ref); }
int32_t sui_decode_image(const void *bytes, int32_t length, int32_t *size) { return sui_host.decode_image(bytes, length, size); }
void sui_release_image(int32_t id) { if (sui_host.release_image) sui_host.release_image(id); }
void sui_main_loop_arm_timer(double seconds) { if (sui_host.arm_timer) sui_host.arm_timer(seconds); }

void sui_open_window(int32_t scene, int64_t value, const char *title, float width, float height) {
    sui_host.open_window(scene, value, title, width, height);
}

void sui_close_window(sui_ref host) { sui_host.close_window(host); }

// MARK: Main loop (the host waits on the handle and drains on its UI thread)

void *_dispatch_get_main_queue_handle_4CF(void);
void _dispatch_main_queue_callback_4CF(void *msg);

void *swiftui2_main_queue_handle(void) { return _dispatch_get_main_queue_handle_4CF(); }
void swiftui2_drain_main_queue(void) { _dispatch_main_queue_callback_4CF(NULL); }
#endif
