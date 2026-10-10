package org.swiftui2

import android.app.Activity
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import android.util.Log
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher

/**
 * Runs a SwiftUI2 app: loads the Swift library named by the `org.swiftui2.library` meta-data,
 * runs its `@main` App (which registers the scenes) and shows the launch scene in a [HostView].
 */
open class SwiftUI2Activity : Activity() {
    lateinit var hostView: HostView
        private set

    private val backCallback = OnBackInvokedCallback {
        if (!Native.back(hostView.host)) finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val library = libraryName()
        // Debugging: `am start -e env.NAME value` sets environment variables for the Swift app.
        intent.extras?.keySet()?.filter { it.startsWith("env.") }?.forEach { key ->
            android.system.Os.setenv(key.removePrefix("env."), intent.getStringExtra(key) ?: "", true)
        }
        if (!started) {
            System.loadLibrary(library)
            check(Native.runMain(library)) { "lib$library.so has no SwiftUI2 App entry point" }
            started = true
        }
        hostView = HostView(this, scene = intent.getIntExtra(EXTRA_SCENE, -1))
        setContentView(hostView)
        // Debugging: `am start --ei org.swiftui2.dump <ms>` logs the view tree (tag SwiftUI2Dump).
        val dumpDelay = intent.getIntExtra(EXTRA_DUMP, -1)
        if (dumpDelay >= 0) hostView.postDelayed({ hostView.dump() }, dumpDelay.toLong())
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, backCallback)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (!Native.back(hostView.host)) super.onBackPressed()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        hostView.configurationChanged(newConfig)
    }

    override fun onDestroy() {
        if (android.os.Build.VERSION.SDK_INT >= 33) onBackInvokedDispatcher.unregisterOnBackInvokedCallback(backCallback)
        hostView.destroy()
        super.onDestroy()
    }

    protected open fun libraryName(): String {
        val info = packageManager.getActivityInfo(componentName, PackageManager.GET_META_DATA)
        return info.metaData?.getString(META_LIBRARY)
            ?: error("Set <meta-data android:name=\"$META_LIBRARY\" android:value=\"<SwiftLibrary>\"/> on the activity")
    }

    companion object {
        const val META_LIBRARY = "org.swiftui2.library"
        /** Index of the scene to show (default: the one that opens at launch). */
        const val EXTRA_SCENE = "org.swiftui2.scene"
        const val EXTRA_DUMP = "org.swiftui2.dump"
        private var started = false
        internal const val TAG = "SwiftUI2"

        internal fun log(message: String) = Log.i(TAG, message)
    }
}
