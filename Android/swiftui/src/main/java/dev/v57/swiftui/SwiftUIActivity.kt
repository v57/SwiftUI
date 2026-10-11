package dev.v57.swiftui

import android.app.Activity
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import android.util.Log
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher

/**
 * Runs a SwiftUI app: loads the Swift library named by the `dev.v57.swiftui.library` meta-data,
 * runs its `@main` App (which registers the scenes) and shows the launch scene in a [HostView].
 */
open class SwiftUIActivity : Activity() {
    lateinit var hostView: HostView
        private set

    private val backCallback = OnBackInvokedCallback {
        if (!Native.back(hostView.host)) finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val library = libraryName()
        // Foundation's home/temporary directories: the app's private storage.
        if (android.system.Os.getenv("HOME").isNullOrEmpty() || android.system.Os.getenv("HOME") == "/") {
            android.system.Os.setenv("HOME", filesDir.absolutePath, true)
        }
        android.system.Os.setenv("TMPDIR", cacheDir.absolutePath, true)
        // Debugging: `am start -e env.NAME value` sets environment variables for the Swift app.
        intent.extras?.keySet()?.filter { it.startsWith("env.") }?.forEach { key ->
            android.system.Os.setenv(key.removePrefix("env."), intent.getStringExtra(key) ?: "", true)
        }
        if (!started) {
            System.loadLibrary(library)
            check(Native.runMain(library)) { "lib$library.so has no SwiftUI App entry point" }
            started = true
        }
        hostView = HostView(this, scene = intent.getIntExtra(EXTRA_SCENE, -1))
        hostView.onToolbarChange = { items ->
            actionBar?.setDisplayHomeAsUpEnabled(items.any { it.id == BACK })
            invalidateOptionsMenu()
        }
        setContentView(hostView)
        // Debugging: `am start --ei dev.v57.swiftui.dump <ms>` logs the view tree (tag SwiftUIDump).
        val dumpDelay = intent.getIntExtra(EXTRA_DUMP, -1)
        if (dumpDelay >= 0) hostView.postDelayed({ hostView.dump() }, dumpDelay.toLong())
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, backCallback)
        }
    }

    override fun onCreateOptionsMenu(menu: android.view.Menu): Boolean {
        for ((index, item) in hostView.toolbar.withIndex()) {
            if (item.id == BACK) continue
            val menuItem = menu.add(0, index + 1, index, item.title.ifEmpty { item.glyph })
            menuItem.isEnabled = item.enabled
            if (item.glyph.isNotEmpty()) menuItem.icon = SymbolDrawable(item.glyph, item.filled, resources.displayMetrics.density)
            menuItem.setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_IF_ROOM)
        }
        return true
    }

    override fun onOptionsItemSelected(item: android.view.MenuItem): Boolean {
        if (item.itemId == android.R.id.home) {
            hostView.toolbarAction(BACK)
            return true
        }
        val entry = hostView.toolbar.getOrNull(item.itemId - 1) ?: return super.onOptionsItemSelected(item)
        hostView.toolbarAction(entry.id)
        return true
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (!Native.back(hostView.host)) super.onBackPressed()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        hostView.configurationChanged(newConfig)
    }

    /** Debugging: `am broadcast -a dev.v57.swiftui.DUMP -p <package>` logs the view tree. */
    private val dumpReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context, intent: android.content.Intent) = hostView.dump()
    }

    override fun onResume() {
        super.onResume()
        val filter = android.content.IntentFilter("dev.v57.swiftui.DUMP")
        if (android.os.Build.VERSION.SDK_INT >= 33) registerReceiver(dumpReceiver, filter, RECEIVER_EXPORTED)
        else registerReceiver(dumpReceiver, filter)
    }

    override fun onPause() {
        unregisterReceiver(dumpReceiver)
        super.onPause()
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
        const val META_LIBRARY = "dev.v57.swiftui.library"
        const val BACK = "navigation.back"
        /** Index of the scene to show (default: the one that opens at launch). */
        const val EXTRA_SCENE = "dev.v57.swiftui.scene"
        const val EXTRA_DUMP = "dev.v57.swiftui.dump"
        private var started = false
        internal const val TAG = "SwiftUI"

        internal fun log(message: String) = Log.i(TAG, message)
    }
}
