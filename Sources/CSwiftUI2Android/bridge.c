#ifdef __ANDROID__
#include "CSwiftUI2Android.h"
#include <android/log.h>
#include <android/looper.h>
#include <dlfcn.h>
#include <sys/system_properties.h>
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

static JavaVM *vm;
static jclass hostViewClass, textMeasureClass;
static jmethodID applyMethod, requestFrameMethod, platformMethod, measureMethod;
static jfloatArray measureOut;

static JNIEnv *env(void) {
    JNIEnv *e = NULL;
    if ((*vm)->GetEnv(vm, (void **)&e, JNI_VERSION_1_6) != JNI_OK) {
        (*vm)->AttachCurrentThread(vm, &e, NULL);
    }
    return e;
}

static void check(JNIEnv *e) {
    if ((*e)->ExceptionCheck(e)) {
        (*e)->ExceptionDescribe(e);
        (*e)->ExceptionClear(e);
    }
}

void sui_log(int priority, const char *message) { __android_log_write(priority, "SwiftUI2", message); }

void sui_host_apply(sui_ref host, const void *bytes, int32_t length) {
    JNIEnv *e = env();
    jobject buffer = (*e)->NewDirectByteBuffer(e, (void *)bytes, length);
    (*e)->CallVoidMethod(e, (jobject)host, applyMethod, buffer);
    check(e);
    (*e)->DeleteLocalRef(e, buffer);
}

void sui_host_request_frame(sui_ref host) {
    JNIEnv *e = env();
    (*e)->CallVoidMethod(e, (jobject)host, requestFrameMethod);
    check(e);
}

char *sui_host_platform(sui_ref host, int32_t op, const char *argument) {
    JNIEnv *e = env();
    jstring arg = argument ? (*e)->NewStringUTF(e, argument) : NULL;
    jstring result = (jstring)(*e)->CallObjectMethod(e, (jobject)host, platformMethod, op, arg);
    check(e);
    if (arg) (*e)->DeleteLocalRef(e, arg);
    if (!result) return NULL;
    const char *chars = (*e)->GetStringUTFChars(e, result, NULL);
    char *copy = strdup(chars);
    (*e)->ReleaseStringUTFChars(e, result, chars);
    (*e)->DeleteLocalRef(e, result);
    return copy;
}

void sui_measure_text(const void *spec, int32_t length, float maxWidth, float *out) {
    JNIEnv *e = env();
    jobject buffer = (*e)->NewDirectByteBuffer(e, (void *)spec, length);
    (*e)->CallStaticVoidMethod(e, textMeasureClass, measureMethod, buffer, maxWidth, measureOut);
    check(e);
    (*e)->GetFloatArrayRegion(e, measureOut, 0, 4, out);
    (*e)->DeleteLocalRef(e, buffer);
}

void sui_delete_global_ref(sui_ref ref) {
    if (ref) (*env())->DeleteGlobalRef(env(), (jobject)ref);
}

// MARK: Main loop

int _dispatch_get_main_queue_handle_4CF(void);
void _dispatch_main_queue_callback_4CF(void *msg);

static int timerFd = -1;

static int onMainQueue(int fd, int events, void *data) {
    uint64_t value;
    read(fd, &value, sizeof value); // eventfd: reset the counter
    _dispatch_main_queue_callback_4CF(NULL);
    swiftui2_timer_fired(); // work on the main queue may have scheduled run loop timers
    return 1;
}

static int onTimer(int fd, int events, void *data) {
    uint64_t expirations;
    read(fd, &expirations, sizeof expirations);
    swiftui2_timer_fired();
    return 1;
}

void sui_main_loop_install(void) {
    static bool installed = false;
    if (installed) return;
    installed = true;
    ALooper *looper = ALooper_forThread();
    if (!looper) return;
    int fd = _dispatch_get_main_queue_handle_4CF();
    ALooper_addFd(looper, fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, onMainQueue, NULL);
    timerFd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    ALooper_addFd(looper, timerFd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, onTimer, NULL);
    // Work queued before installation.
    _dispatch_main_queue_callback_4CF(NULL);
}

void sui_main_loop_arm_timer(double seconds) {
    if (timerFd < 0) return;
    struct itimerspec spec = {0};
    if (seconds >= 0) {
        if (seconds < 0.000001) seconds = 0.000001; // zero would disarm
        spec.it_value.tv_sec = (time_t)seconds;
        spec.it_value.tv_nsec = (long)((seconds - (double)spec.it_value.tv_sec) * 1e9);
    }
    timerfd_settime(timerFd, 0, &spec, NULL);
}

// MARK: Kotlin → Swift

/// Runs the app library's `main` (the `@main App`'s entry point). On Android `App.main()` only
/// registers the app's scenes with the backend and returns; Kotlin then creates hosts.
static jboolean runMain(JNIEnv *e, jclass cls, jstring library) {
    sui_main_loop_install();
    const char *name = (*e)->GetStringUTFChars(e, library, NULL);
    char path[512];
    snprintf(path, sizeof path, "lib%s.so", name);
    (*e)->ReleaseStringUTFChars(e, library, name);
    void *handle = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
    if (!handle) handle = dlopen(path, RTLD_NOW);
    int (*entry)(int, char **) = handle ? (int (*)(int, char **))dlsym(handle, "main") : NULL;
    if (!entry) {
        __android_log_print(ANDROID_LOG_ERROR, "SwiftUI2", "No main entry point in %s: %s", path, dlerror());
        return JNI_FALSE;
    }
    static char *argv[] = {"swiftui2", NULL};
    entry(1, argv);
    return JNI_TRUE;
}

static jlong createHost(JNIEnv *e, jclass cls, jobject view, jfloat density, jint scene) {
    return swiftui2_create_host((*e)->NewGlobalRef(e, view), density, scene);
}

static void destroyHost(JNIEnv *e, jclass cls, jlong host) { swiftui2_destroy_host(host); }
static void setSize(JNIEnv *e, jclass cls, jlong host, jfloat w, jfloat h) { swiftui2_set_size(host, w, h); }
static void setInsets(JNIEnv *e, jclass cls, jlong host, jfloat t, jfloat l, jfloat b, jfloat r) { swiftui2_set_insets(host, t, l, b, r); }
static void setEnvironment(JNIEnv *e, jclass cls, jlong host, jint key, jint value) { swiftui2_set_environment(host, key, value); }

static void event(JNIEnv *e, jclass cls, jlong host, jint node, jint type, jdouble a, jdouble b, jdouble c, jstring text) {
    const char *chars = text ? (*e)->GetStringUTFChars(e, text, NULL) : NULL;
    swiftui2_event(host, node, type, a, b, c, chars);
    if (chars) (*e)->ReleaseStringUTFChars(e, text, chars);
}

static void frame(JNIEnv *e, jclass cls, jlong host, jlong nanos) { swiftui2_frame(host, (double)nanos / 1e9); }
static jboolean back(JNIEnv *e, jclass cls, jlong host) { return swiftui2_back(host); }

JNIEXPORT jint JNI_OnLoad(JavaVM *javaVM, void *reserved) {
    vm = javaVM;
    JNIEnv *e = env();
    jclass native = (*e)->FindClass(e, "org/swiftui2/Native");
    if (!native) { check(e); return JNI_VERSION_1_6; }
    static const JNINativeMethod methods[] = {
        {"runMain", "(Ljava/lang/String;)Z", (void *)runMain},
        {"createHost", "(Lorg/swiftui2/HostView;FI)J", (void *)createHost},
        {"destroyHost", "(J)V", (void *)destroyHost},
        {"setSize", "(JFF)V", (void *)setSize},
        {"setInsets", "(JFFFF)V", (void *)setInsets},
        {"setEnvironment", "(JII)V", (void *)setEnvironment},
        {"event", "(JIIDDDLjava/lang/String;)V", (void *)event},
        {"frame", "(JJ)V", (void *)frame},
        {"back", "(J)Z", (void *)back},
    };
    (*e)->RegisterNatives(e, native, methods, sizeof methods / sizeof methods[0]);
    check(e);
    hostViewClass = (*e)->NewGlobalRef(e, (*e)->FindClass(e, "org/swiftui2/HostView"));
    applyMethod = (*e)->GetMethodID(e, hostViewClass, "apply", "(Ljava/nio/ByteBuffer;)V");
    requestFrameMethod = (*e)->GetMethodID(e, hostViewClass, "requestFrame", "()V");
    platformMethod = (*e)->GetMethodID(e, hostViewClass, "platform", "(ILjava/lang/String;)Ljava/lang/String;");
    textMeasureClass = (*e)->NewGlobalRef(e, (*e)->FindClass(e, "org/swiftui2/TextMeasure"));
    measureMethod = (*e)->GetStaticMethodID(e, textMeasureClass, "measure", "(Ljava/nio/ByteBuffer;F[F)V");
    measureOut = (*e)->NewGlobalRef(e, (*e)->NewFloatArray(e, 4));
    check(e);
    return JNI_VERSION_1_6;
}
#endif
