package org.swiftui2

import android.graphics.Bitmap
import android.graphics.BlendMode
import android.graphics.Canvas
import android.graphics.ColorMatrixColorFilter
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Region
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewOutlineProvider
import kotlin.math.abs
import kotlin.math.ceil

/**
 * A container applying a display effect to its children (DisplayEffect), and the touch target
 * of gestures (tap targets, pointer handlers, press state, long press).
 */
class EffectNode(host: HostView, id: Int) : NodeView(host, id, KIND_EFFECT) {
    class Effect(val type: Int, val values: FloatArray = FloatArray(0), val path: Path? = null, val flags: Int = 0)

    private var effect = Effect(0)
    private var touchFlags = 0
    private var clipPath: Path? = null
    private var hitRegion: Region? = null
    private var shadow: Shadow? = null
    private var isMask = false
    var drawingMask = false
        private set

    override fun applyContent(r: Reader) {
        effect = readEffect(r, host.density)
        touchFlags = r.u8()
        // Reset, then apply the new effect.
        baseAlpha = 1f
        clipPath = null; hitRegion = null; shadow = null; isMask = false
        if (clipToOutline) { clipToOutline = false; outlineProvider = ViewOutlineProvider.BACKGROUND }
        var transform: FloatArray? = null
        var projection: FloatArray? = null
        var layerPaint: Paint? = null
        isFocusable = false
        val v = effect.values
        when (effect.type) {
            1 -> baseAlpha = v[0]
            2 -> clip(effect.path!!)
            4 -> transform = v
            5 -> projection = v
            6 -> shadow = Shadow(effect.flags, v[1], v[2], v[3])
            7 -> isMask = true
            10 -> {
                isFocusable = true
                isFocusableInTouchMode = true
                if (v[0] != 0f && !hasFocus()) post { requestFocus() }
            }
            12 -> layerPaint = Paint().apply { colorFilter = ColorMatrixColorFilter(v) }
            13 -> if (android.os.Build.VERSION.SDK_INT >= 29) layerPaint = Paint().apply { blendMode = blendMode(v[0].toInt()) }
            14 -> hitRegion = region(effect.path!!)
        }
        effectTransform = transform
        effectProjection = projection
        if (layerPaint != null) setLayerType(LAYER_TYPE_HARDWARE, layerPaint)
        else if (layerType != LAYER_TYPE_NONE) setLayerType(LAYER_TYPE_NONE, null)
        setWillNotDraw(!(shadow != null || isMask || clipPath != null))
        invalidate()
    }

    override fun describe() = " effect:${effect.type}" + (if (touchFlags != 0) " touch:$touchFlags" else "") +
        (if (clipToOutline) " clipsToOutline" else "") + (if (alpha != 1f) " alpha:$alpha" else "")

    private fun clip(path: Path) {
        val rect = RectF()
        if (path.isRect(rect)) {
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    outline.setRect(Rect(rect.left.toInt(), rect.top.toInt(), ceil(rect.right).toInt(), ceil(rect.bottom).toInt()))
                }
            }
            clipToOutline = true
        } else if (android.os.Build.VERSION.SDK_INT >= 33) {
            // Any path can clip through the outline on API 33+ (antialiased, no offscreen layer).
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) = outline.setPath(path)
            }
            clipToOutline = true
        } else {
            clipPath = path
        }
        invalidateOutline()
    }

    private fun region(path: Path): Region {
        val bounds = RectF()
        path.computeBounds(bounds, true)
        val region = Region()
        region.setPath(path, Region(bounds.left.toInt() - 1, bounds.top.toInt() - 1, bounds.right.toInt() + 1, bounds.bottom.toInt() + 1))
        return region
    }

    private fun blendMode(index: Int): BlendMode = when (index) {
        1 -> BlendMode.MULTIPLY; 2 -> BlendMode.SCREEN; 3 -> BlendMode.OVERLAY; 4 -> BlendMode.DARKEN; 5 -> BlendMode.LIGHTEN
        6 -> BlendMode.COLOR_DODGE; 7 -> BlendMode.COLOR_BURN; 8 -> BlendMode.SOFT_LIGHT; 9 -> BlendMode.HARD_LIGHT
        10 -> BlendMode.DIFFERENCE; 11 -> BlendMode.EXCLUSION; 12 -> BlendMode.HUE; 13 -> BlendMode.SATURATION
        14 -> BlendMode.COLOR; 15 -> BlendMode.LUMINOSITY; 16 -> BlendMode.SRC_ATOP; 17 -> BlendMode.DST_OVER
        18 -> BlendMode.DST_OUT; 19 -> BlendMode.DARKEN; 20 -> BlendMode.PLUS
        else -> BlendMode.SRC_OVER
    }

    // MARK: Drawing (path clips, shadows, masks)

    private val maskPaint = Paint().apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN) }

    override fun dispatchDraw(canvas: Canvas) {
        shadow?.let { drawShadow(canvas, it) }
        val clip = clipPath
        if (isMask) {
            val save = canvas.saveLayer(null, null)
            for (i in 0 until childCount) {
                val child = getChildAt(i)
                if (child !is MaskSourceNode) drawChild(canvas, child, drawingTime)
            }
            val source = (0 until childCount).map(::getChildAt).lastOrNull { it is MaskSourceNode }
            if (source != null) {
                val mask = canvas.saveLayer(null, maskPaint)
                drawingMask = true
                drawChild(canvas, source, drawingTime)
                drawingMask = false
                canvas.restoreToCount(mask)
            }
            canvas.restoreToCount(save)
        } else if (clip != null) {
            canvas.save()
            canvas.clipPath(clip)
            super.dispatchDraw(canvas)
            canvas.restore()
        } else {
            super.dispatchDraw(canvas)
        }
    }

    private var shadowBitmap: Bitmap? = null

    /** A soft shadow of the content: its alpha, blurred, in the shadow color, at the offset. */
    private fun drawShadow(canvas: Canvas, shadow: Shadow) {
        if (width <= 0 || height <= 0) return
        val d = host.density
        val bitmap = shadowBitmap?.takeIf { it.width == width && it.height == height }
            ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { shadowBitmap = it }
        bitmap.eraseColor(0)
        super.dispatchDraw(Canvas(bitmap))
        val paint = shadowPaint(shadow, d)
        val offset = IntArray(2)
        val alpha = bitmap.extractAlpha(paint, offset)
        canvas.drawBitmap(alpha, offset[0] + shadow.dx * d, offset[1] + shadow.dy * d, Paint().apply { color = shadow.color })
        alpha.recycle()
    }

    // MARK: Touches

    private var longPress: Runnable? = null
    private var longPressFired = false
    private var downX = 0f
    private var downY = 0f
    private var pressedInside = false

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        val region = hitRegion
        if (event.actionMasked == MotionEvent.ACTION_DOWN && region != null && !region.contains(event.x.toInt(), event.y.toInt())) return false
        return super.dispatchTouchEvent(event)
    }

    /** The node has hover handlers (HostView feeds them from touches and pointer hover). */
    val tracksHover get() = touchFlags and FLAG_HOVER != 0

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val touchFlags = touchFlags and FLAG_HOVER.inv()
        if (touchFlags == 0 && !isFocusable) return false
        if (touchFlags == 0) {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) requestFocus()
            return true
        }
        val d = host.density
        val x = event.x / d
        val y = event.y / d
        val time = event.eventTime / 1000.0
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (isFocusable) requestFocus()
                downX = event.x; downY = event.y
                longPressFired = false
                pressedInside = true
                if (touchFlags and FLAG_PRESSED != 0) host.event(nodeId, Events.PRESSED, 1.0)
                if (touchFlags and FLAG_POINTER != 0) host.event(nodeId, Events.POINTER_BEGAN, x.toDouble(), y.toDouble(), time)
                if (touchFlags and FLAG_SECONDARY != 0) {
                    val runnable = Runnable {
                        longPressFired = true
                        performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
                        host.event(nodeId, Events.SECONDARY_CLICK)
                    }
                    longPress = runnable
                    postDelayed(runnable, ViewConfiguration.getLongPressTimeout().toLong())
                }
            }
            MotionEvent.ACTION_MOVE -> {
                val slop = ViewConfiguration.get(context).scaledTouchSlop
                if (abs(event.x - downX) > slop || abs(event.y - downY) > slop) cancelLongPress()
                if (touchFlags and FLAG_POINTER != 0) host.event(nodeId, Events.POINTER_MOVED, x.toDouble(), y.toDouble(), time)
                val inside = event.inside(this)
                if (inside != pressedInside) {
                    pressedInside = inside
                    if (touchFlags and FLAG_PRESSED != 0) host.event(nodeId, Events.PRESSED, if (inside) 1.0 else 0.0)
                }
            }
            MotionEvent.ACTION_UP -> {
                cancelLongPress()
                if (touchFlags and FLAG_POINTER != 0) host.event(nodeId, Events.POINTER_ENDED, x.toDouble(), y.toDouble(), time)
                if (touchFlags and FLAG_PRESSED != 0) host.event(nodeId, Events.PRESSED, 0.0)
                if (touchFlags and FLAG_PRIMARY != 0 && event.inside(this) && !longPressFired) host.event(nodeId, Events.PRIMARY)
            }
            MotionEvent.ACTION_CANCEL -> {
                cancelLongPress()
                if (touchFlags and FLAG_POINTER != 0) host.event(nodeId, Events.POINTER_CANCELLED, x.toDouble(), y.toDouble(), time)
                if (touchFlags and FLAG_PRESSED != 0) host.event(nodeId, Events.PRESSED, 0.0)
            }
        }
        return true
    }

    override fun cancelLongPress() {
        super.cancelLongPress()
        longPress?.let(::removeCallbacks)
        longPress = null
    }

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        if (isFocusable) host.event(nodeId, Events.FOCUS_CHANGED, if (gainFocus) 1.0 else 0.0)
    }

    companion object {
        const val FLAG_PRIMARY = 1
        const val FLAG_POINTER = 2
        const val FLAG_PRESSED = 4
        const val FLAG_SECONDARY = 8
        const val FLAG_HOVER = 16

        /** Reads ByteWriter.effect. Values: opacity [o]; transform [dx, dy, sx, sy, deg, ax, ay];
         *  projection [9]; shadow [_, radius, dx, dy] + color in flags; focusable [wants, ring];
         *  color filter [20]; blend mode [index]. */
        fun readEffect(r: Reader, density: Float = 1f): Effect = when (val type = r.u8()) {
            1 -> Effect(type, floatArrayOf(r.f32()))
            2, 14 -> Effect(type, path = Paths.read(r, density))
            4 -> Effect(type, FloatArray(7) { r.f32() })
            5 -> Effect(type, FloatArray(9) { r.f32() })
            6 -> { val color = r.color(); Effect(type, floatArrayOf(0f, r.f32(), r.f32(), r.f32()), flags = color) }
            10 -> Effect(type, floatArrayOf(if (r.bool()) 1f else 0f, if (r.bool()) 1f else 0f))
            12 -> Effect(type, FloatArray(20) { r.f32() })
            13 -> Effect(type, floatArrayOf(r.u8().toFloat()))
            else -> Effect(type)
        }
    }
}
