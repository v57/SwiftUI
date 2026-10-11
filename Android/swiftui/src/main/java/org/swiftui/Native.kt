package org.swiftui

/** Kotlin → Swift calls (registered by the Swift library's JNI_OnLoad; see CSwiftUIAndroid.h). */
object Native {
    /** Runs the app library's `main` (registers the `@main App`'s scenes). */
    @JvmStatic external fun runMain(library: String): Boolean
    @JvmStatic external fun createHost(view: HostView, density: Float, scene: Int): Long
    @JvmStatic external fun destroyHost(host: Long)
    @JvmStatic external fun setSize(host: Long, width: Float, height: Float)
    @JvmStatic external fun setInsets(host: Long, top: Float, left: Float, bottom: Float, right: Float)
    @JvmStatic external fun setEnvironment(host: Long, key: Int, value: Int)
    @JvmStatic external fun event(host: Long, node: Int, type: Int, a: Double, b: Double, c: Double, text: String?)
    @JvmStatic external fun frame(host: Long, frameTimeNanos: Long)
    @JvmStatic external fun back(host: Long): Boolean
}

/** Event types (AndroidHost.Event). */
object Events {
    const val PRIMARY = 1
    const val SET_BOOL = 2
    const val SET_TEXT = 3
    const val SET_DOUBLE = 4
    const val EDITING_CHANGED = 5
    const val PRESSED = 6
    const val SUBMIT = 8
    const val FOCUS_CHANGED = 9
    const val SECONDARY_CLICK = 10
    const val SCROLLED = 11
    const val SCROLL_PHASE = 12
    const val OPEN_URL = 13
    const val SET_DATE = 14
    const val SET_COLOR = 15
    const val POINTER_BEGAN = 20
    const val POINTER_MOVED = 21
    const val POINTER_ENDED = 22
    const val POINTER_CANCELLED = 23
    const val HOVER = 24
    const val HOVER_LOCATION = 25
}

/** Environment keys (AndroidHost.setEnvironment). */
object EnvironmentKeys {
    const val COLOR_SCHEME = 1
}
