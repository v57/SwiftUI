package org.swiftui2

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.util.SparseArray
import android.view.Choreographer
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * Hosts one SwiftUI2 view graph. The Swift renderer sends batches of commands ([apply]); views
 * are positioned absolutely from SwiftUI2's layout (1pt = 1dp), never by Android layout passes.
 */
class HostView(context: Context, scene: Int = -1) : ViewGroup(context), Choreographer.FrameCallback {
    val density = resources.displayMetrics.density
    /** The root of the render tree (id 0), placed inside the system bar insets. */
    val root = ContainerNode(this, 0)
    private val views = SparseArray<NodeView>()
    var host: Long = 0
        private set
    private var insets = IntArray(4) // left, top, right, bottom (px)
    private var frameRequested = false

    init {
        Fonts.context = context.applicationContext
        TextMeasure.density = density
        views.put(0, root)
        addView(root)
        clipChildren = false
        isMotionEventSplittingEnabled = false
        host = Native.createHost(this, density, scene)
        Native.setEnvironment(host, EnvironmentKeys.COLOR_SCHEME, if (isNight(resources.configuration)) 1 else 0)
        setOnApplyWindowInsetsListener { _, windowInsets ->
            val types = WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout() or WindowInsets.Type.ime()
            val i = windowInsets.getInsets(types)
            val updated = intArrayOf(i.left, i.top, i.right, i.bottom)
            if (!updated.contentEquals(insets)) {
                insets = updated
                updateRootFrame()
            }
            WindowInsets.CONSUMED
        }
    }

    private fun isNight(configuration: Configuration) =
        (configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    fun configurationChanged(configuration: Configuration) {
        if (host != 0L) Native.setEnvironment(host, EnvironmentKeys.COLOR_SCHEME, if (isNight(configuration)) 1 else 0)
    }

    fun destroy() {
        if (host != 0L) Native.destroyHost(host)
        host = 0
        Choreographer.getInstance().removeFrameCallback(this)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec))
        root.measureToFrame()
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        if (changed) updateRootFrame()
        root.layoutToFrame()
    }

    private fun updateRootFrame() {
        if (width == 0 || height == 0 || host == 0L) return
        val w = width - insets[0] - insets[2]
        val h = height - insets[1] - insets[3]
        root.setFramePx(insets[0], insets[1], w, h)
        Native.setSize(host, w / density, h / density)
    }

    // MARK: Commands

    fun apply(buffer: ByteBuffer) {
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        val r = Reader(buffer)
        while (buffer.hasRemaining()) {
            when (val op = r.u8()) {
                OP_CREATE -> {
                    val id = r.i32()
                    val kind = r.u8()
                    views.put(id, NodeView.make(this, id, kind))
                }
                OP_DESTROY -> {
                    val id = r.i32()
                    val view = views[id] ?: continue
                    views.remove(id)
                    (view.parent as? NodeView)?.removeChild(view)
                    view.destroyed()
                }
                OP_FRAME -> {
                    val id = r.i32()
                    val x = r.f32(); val y = r.f32(); val w = r.f32(); val h = r.f32()
                    views[id]?.setFrame(x, y, w, h)
                }
                OP_CHILDREN -> {
                    val id = r.i32()
                    val count = r.i32()
                    val children = ArrayList<NodeView>(count)
                    repeat(count) { views[r.i32()]?.let(children::add) }
                    views[id]?.setChildren(children)
                }
                OP_CONTENT -> {
                    val id = r.i32()
                    val kind = r.u8()
                    val view = views[id]
                    if (view != null && view.kind == kind) view.applyContent(r) else NodeView.skipContent(this, kind, r)
                }
                OP_PRESENTATION -> {
                    val id = r.i32()
                    val p = Presentation(r.f32(), r.f32(), r.f32(), r.f32(), r.f32(), r.f32(), r.f32(), r.f32())
                    views[id]?.setPresentation(p)
                }
                OP_ACCESSIBILITY -> {
                    val id = r.i32()
                    val hidden = r.bool()
                    val label = r.string(); val value = r.string(); r.string(); val identifier = r.string()
                    views[id]?.applyAccessibility(hidden, label, value, identifier)
                }
                else -> error("Unknown render command $op")
            }
        }
    }

    // MARK: Frames

    fun requestFrame() {
        if (frameRequested) return
        frameRequested = true
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun doFrame(frameTimeNanos: Long) {
        frameRequested = false
        if (host != 0L) Native.frame(host, frameTimeNanos)
    }

    fun event(node: Int, type: Int, a: Double = 0.0, b: Double = 0.0, c: Double = 0.0, text: String? = null) {
        if (host != 0L) Native.event(host, node, type, a, b, c, text)
    }

    // MARK: Platform services

    fun platform(op: Int, argument: String?): String? = when (op) {
        PLATFORM_OPEN_URL -> {
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(argument))) }
            null
        }
        PLATFORM_HAPTIC -> {
            performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            null
        }
        PLATFORM_SHARE -> {
            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, argument)
            runCatching { context.startActivity(Intent.createChooser(send, null)) }
            null
        }
        PLATFORM_COPY -> {
            val clipboard = context.getSystemService(ClipboardManager::class.java)
            clipboard.setPrimaryClip(ClipData.newPlainText("text", argument))
            null
        }
        PLATFORM_PASTE -> {
            val clipboard = context.getSystemService(ClipboardManager::class.java)
            clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
        }
        PLATFORM_CONTROL_METRICS -> Widgets.controlMetrics(context, density)
        PLATFORM_IMAGE_SIZE -> Images.size(context, argument ?: "", density)
        PLATFORM_SHOW_KEYBOARD -> {
            context.getSystemService(InputMethodManager::class.java).showSoftInput(findFocus(), 0)
            null
        }
        PLATFORM_HIDE_KEYBOARD -> {
            context.getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(windowToken, 0)
            null
        }
        PLATFORM_SET_TITLE -> {
            (context as? Activity)?.title = argument
            null
        }
        else -> null
    }

    fun px(dp: Float): Int = (dp * density).roundToInt()

    /** Logs the node tree with frames in dp, relative to the root (tag SwiftUI2Dump). */
    fun dump() {
        val lines = ArrayList<String>()
        fun fmt(v: Float) = if (v == v.roundToInt().toFloat()) v.roundToInt().toString() else String.format("%.1f", v)
        fun visit(view: View, depth: Int, ox: Float, oy: Float) {
            val node = view as? NodeView
            val x = ox + view.left + view.translationX
            val y = oy + view.top + view.translationY
            if (node != null && node !== root) {
                val name = node.javaClass.simpleName.removeSuffix("Node")
                lines += "  ".repeat(depth) + "$name #${node.nodeId} (${fmt(x / density)}, ${fmt(y / density)}, ${fmt(view.width / density)}, ${fmt(view.height / density)})" + node.describe()
            }
            if (view is ViewGroup && (node != null)) {
                for (i in 0 until view.childCount) {
                    val child = view.getChildAt(i)
                    if (child is NodeView) visit(child, if (node === root) depth else depth + 1, x - view.scrollX, y - view.scrollY)
                }
            }
        }
        visit(root, 0, -root.left.toFloat(), -root.top.toFloat())
        lines.chunked(40).forEach { android.util.Log.i("SwiftUI2Dump", it.joinToString("\n")) }
        android.util.Log.i("SwiftUI2Dump", "END ${lines.size} nodes")
    }

    companion object {
        const val OP_CREATE = 1
        const val OP_DESTROY = 2
        const val OP_FRAME = 3
        const val OP_CHILDREN = 4
        const val OP_CONTENT = 5
        const val OP_PRESENTATION = 6
        const val OP_ACCESSIBILITY = 7

        const val PLATFORM_OPEN_URL = 1
        const val PLATFORM_HAPTIC = 2
        const val PLATFORM_SHARE = 3
        const val PLATFORM_COPY = 4
        const val PLATFORM_PASTE = 5
        const val PLATFORM_CONTROL_METRICS = 6
        const val PLATFORM_IMAGE_SIZE = 7
        const val PLATFORM_SHOW_KEYBOARD = 8
        const val PLATFORM_HIDE_KEYBOARD = 9
        const val PLATFORM_SET_TITLE = 10
    }
}

/** Reads the little-endian command stream written by Swift's `ByteWriter`. */
class Reader(private val buffer: ByteBuffer) {
    fun u8(): Int = buffer.get().toInt() and 0xFF
    fun bool(): Boolean = u8() != 0
    fun i32(): Int = buffer.int
    fun f32(): Float = buffer.float
    fun f64(): Double = buffer.double
    fun color(): Int = buffer.int
    fun optColor(): Int? = if (bool()) buffer.int else null

    fun string(): String? {
        val length = buffer.int
        if (length < 0) return null
        if (length == 0) return ""
        val bytes = ByteArray(length)
        buffer.get(bytes)
        return String(bytes, Charsets.UTF_8)
    }
}

/** Transition presentation (RenderPresentation). */
data class Presentation(
    val opacity: Float, val scaleX: Float, val scaleY: Float, val anchorX: Float, val anchorY: Float,
    val offsetX: Float, val offsetY: Float, val rotation: Float,
) {
    val isIdentity get() = opacity == 1f && scaleX == 1f && scaleY == 1f && offsetX == 0f && offsetY == 0f && rotation == 0f

    companion object {
        val IDENTITY = Presentation(1f, 1f, 1f, 0.5f, 0.5f, 0f, 0f, 0f)
    }
}
