package org.swiftui2

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.text.TextPaint
import kotlin.math.max
import kotlin.math.min

/** Stroke attributes (ByteWriter.strokeStyle). */
class StrokeStyle(val cap: Int, val join: Int, val miter: Float, val dash: FloatArray, val phase: Float) {
    fun apply(paint: Paint, density: Float) {
        paint.strokeCap = when (cap) { 1 -> Paint.Cap.ROUND; 2 -> Paint.Cap.SQUARE; else -> Paint.Cap.BUTT }
        paint.strokeJoin = when (join) { 1 -> Paint.Join.ROUND; 2 -> Paint.Join.BEVEL; else -> Paint.Join.MITER }
        paint.strokeMiter = miter
        paint.pathEffect = if (dash.size >= 2) DashPathEffect(FloatArray(dash.size) { dash[it] * density }, phase * density) else null
    }

    companion object {
        fun read(r: Reader): StrokeStyle? {
            if (!r.bool()) return null
            val cap = r.u8(); val join = r.u8(); val miter = r.f32()
            val dash = FloatArray(r.i32()) { r.f32() }
            return StrokeStyle(cap, join, miter, dash, r.f32())
        }
    }
}

class Shadow(val color: Int, val radius: Float, val dx: Float, val dy: Float) {
    companion object {
        fun read(r: Reader) = Shadow(r.color(), r.f32(), r.f32(), r.f32())
    }
}

/** A filled and/or stroked path; the path is scaled from the size it was built for to the frame. */
class ShapeNode(host: HostView, id: Int) : NodeView(host, id, KIND_SHAPE) {
    private val path = Path()
    private val scaled = Path()
    private var pathWidth = 0f
    private var pathHeight = 0f
    private var fill: Int? = null
    private var stroke: Int? = null
    private var lineWidth = 1f
    private var strokeStyle: StrokeStyle? = null
    private var gradient: Gradient? = null
    private var shadow: Shadow? = null
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }

    init { setWillNotDraw(false) }

    override fun applyContent(r: Reader) {
        val d = host.density
        Paths.read(r, d, path)
        pathWidth = r.f32() * d; pathHeight = r.f32() * d
        fill = r.optColor()
        stroke = r.optColor()
        lineWidth = r.f32()
        strokeStyle = StrokeStyle.read(r)
        gradient = if (r.bool()) Gradient.read(r) else null
        shadow = if (r.bool()) Shadow.read(r) else null
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val d = host.density
        var drawn = path
        if (pathWidth > 0 && pathHeight > 0 && (pathWidth.toInt() != width || pathHeight.toInt() != height)) {
            val m = Matrix()
            m.setScale(width / pathWidth, height / pathHeight)
            path.transform(m, scaled)
            drawn = scaled
        }
        val gradient = gradient
        val shadow = shadow
        val fill = fill
        val stroke = stroke
        // Like the AppKit backend: a gradient paints the filled (or, with a stroke style, the
        // stroked) path; otherwise fill and stroke colors apply.
        val fills = if (gradient != null) strokeStyle == null else fill != null
        val strokes = if (gradient != null) strokeStyle != null else stroke != null
        if (fills) {
            fillPaint.color = fill ?: 0xFF000000.toInt()
            fillPaint.shader = gradient?.shader(width.toFloat(), height.toFloat(), d)
            if (shadow != null) fillPaint.setShadowLayer(max(shadow.radius * d, 0.01f), shadow.dx * d, shadow.dy * d, shadow.color) else fillPaint.clearShadowLayer()
            canvas.drawPath(drawn, fillPaint)
        }
        if (strokes) {
            strokePaint.color = stroke ?: 0xFF000000.toInt()
            strokePaint.strokeWidth = lineWidth * d
            strokePaint.pathEffect = null
            strokeStyle?.apply(strokePaint, d)
            strokePaint.shader = gradient?.shader(width.toFloat(), height.toFloat(), d)
            if (shadow != null && !fills) strokePaint.setShadowLayer(max(shadow.radius * d, 0.01f), shadow.dx * d, shadow.dy * d, shadow.color) else strokePaint.clearShadowLayer()
            canvas.drawPath(drawn, strokePaint)
        }
    }
}

/** Images: SF Symbols as Material Symbols glyphs, named drawables/assets, decoded bitmaps. */
class ImageNode(host: HostView, id: Int) : NodeView(host, id, KIND_IMAGE) {
    private var glyph: String? = null
    private var glyphSizePx = 0f
    private var drawable: Drawable? = null
    private var bitmap: Bitmap? = null
    private var resizable = false
    private var tint: Int? = null
    private var redacted: Int? = null
    private val glyphPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)

    init { setWillNotDraw(false) }

    override fun applyContent(r: Reader) {
        glyph = null; drawable = null; bitmap = null
        when (r.u8()) {
            0 -> {
                glyph = r.string()
                val filled = r.bool()
                glyphSizePx = r.f32() * host.density
                val weight = r.i32()
                glyphPaint.typeface = Fonts.symbols
                glyphPaint.fontVariationSettings = "'FILL' ${if (filled) 1 else 0}, 'wght' ${weight.coerceIn(100, 700)}"
            }
            1 -> {
                val name = r.string() ?: ""
                val loaded = Images.load(context, name)
                if (loaded is Drawable) drawable = loaded else bitmap = loaded as? Bitmap
            }
            else -> bitmap = Images.decoded[r.i32()]
        }
        resizable = r.bool()
        tint = r.optColor()
        redacted = r.optColor()
        invalidate()
    }

    override fun describe() = glyph?.let { " glyph:$it" } ?: ""

    override fun onDraw(canvas: Canvas) {
        redacted?.let { color ->
            val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = (color and 0x00FFFFFF) or 0x29000000 }
            val side = min(width, height).toFloat()
            val rect = RectF((width - side) / 2, (height - side) / 2, (width + side) / 2, (height + side) / 2)
            canvas.drawRoundRect(rect, side / 6, side / 6, p)
            return
        }
        glyph?.let { name ->
            // The glyph fills its em square: size it to the frame and center it.
            val size = if (resizable) min(width, height).toFloat() else min(glyphSizePx, min(width, height).toFloat()).coerceAtLeast(1f)
            glyphPaint.textSize = size
            glyphPaint.color = tint ?: 0xFF000000.toInt()
            val textWidth = glyphPaint.measureText(name)
            val metrics = glyphPaint.fontMetrics
            val baseline = (height - (metrics.descent - metrics.ascent)) / 2 - metrics.ascent
            canvas.drawText(name, (width - textWidth) / 2, baseline, glyphPaint)
            return
        }
        drawable?.let {
            it.setBounds(0, 0, width, height)
            it.colorFilter = tint?.let { color -> PorterDuffColorFilter(color, PorterDuff.Mode.SRC_IN) }
            it.draw(canvas)
            return
        }
        bitmap?.let {
            bitmapPaint.colorFilter = tint?.let { color -> PorterDuffColorFilter(color, PorterDuff.Mode.SRC_IN) }
            canvas.drawBitmap(it, Rect(0, 0, it.width, it.height), Rect(0, 0, width, height), bitmapPaint)
        }
    }
}

/** Named images: drawables (res/drawable-*: name), then `assets/images/<name>.png|jpg|webp`. */
object Images {
    val decoded = HashMap<Int, Bitmap>()
    private var nextId = 1

    /** Decodes image data for Swift's `decodeImage`; out = pixel size. Returns the id or -1. */
    @JvmStatic
    fun decode(data: java.nio.ByteBuffer, out: IntArray): Int {
        val bytes = ByteArray(data.remaining())
        data.get(bytes)
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return -1
        val id = nextId++
        decoded[id] = bitmap
        out[0] = bitmap.width
        out[1] = bitmap.height
        return id
    }

    @JvmStatic
    fun release(id: Int) { decoded.remove(id) }
    private val cache = HashMap<String, Any?>()

    fun load(context: Context, name: String): Any? {
        if (cache.containsKey(name)) return cache[name]
        val resource = name.lowercase().replace(Regex("[^a-z0-9_]"), "_")
        var result: Any? = null
        val id = context.resources.getIdentifier(resource, "drawable", context.packageName)
        if (id != 0) result = context.getDrawable(id)
        if (result == null) {
            for (ext in arrayOf("png", "jpg", "jpeg", "webp")) {
                result = runCatching { context.assets.open("images/$name.$ext").use(BitmapFactory::decodeStream) }.getOrNull()
                if (result != null) break
            }
        }
        cache[name] = result
        return result
    }

    /** "width,height" (dp) of a named image, or null. */
    fun size(context: Context, name: String, density: Float): String? = when (val image = load(context, name)) {
        is Drawable -> "${image.intrinsicWidth / density},${image.intrinsicHeight / density}"
        is Bitmap -> "${image.width / density},${image.height / density}"
        else -> null
    }
}

/** `Canvas` views: replays the recorded drawing commands. */
class CanvasNode(host: HostView, id: Int) : NodeView(host, id, KIND_DRAWING) {
    private sealed class Command
    private class Fill(val path: Path, val color: Int, val gradient: Gradient?) : Command()
    private class Stroke(val path: Path, val color: Int, val gradient: Gradient?, val width: Float, val style: StrokeStyle?) : Command()
    private class DrawText(val spec: TextSpec, val x: Float, val y: Float, val ax: Float, val ay: Float) : Command()

    private var commands = emptyList<Command>()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)

    init { setWillNotDraw(false) }

    override fun applyContent(r: Reader) {
        val d = host.density
        val list = ArrayList<Command>()
        repeat(r.i32()) {
            when (r.u8()) {
                0 -> { val path = Paths.read(r, d); val (color, gradient) = paint(r); list += Fill(path, color, gradient) }
                1 -> {
                    val path = Paths.read(r, d); val (color, gradient) = paint(r)
                    val width = r.f32(); val style = StrokeStyle.read(r)
                    list += Stroke(path, color, gradient, width, style)
                }
                else -> { val spec = TextSpec.read(r, d); list += DrawText(spec, r.f32(), r.f32(), r.f32(), r.f32()) }
            }
        }
        commands = list
        invalidate()
    }

    private fun paint(r: Reader): Pair<Int, Gradient?> = if (r.u8() == 0) r.color() to null else 0xFF000000.toInt() to Gradient.read(r)

    override fun onDraw(canvas: Canvas) {
        val d = host.density
        for (command in commands) {
            when (command) {
                is Fill -> {
                    paint.style = Paint.Style.FILL; paint.pathEffect = null
                    paint.color = command.color
                    paint.shader = command.gradient?.shader(width.toFloat(), height.toFloat(), d)
                    canvas.drawPath(command.path, paint)
                }
                is Stroke -> {
                    paint.style = Paint.Style.STROKE
                    paint.color = command.color
                    paint.strokeWidth = command.width * d
                    paint.pathEffect = null
                    command.style?.apply(paint, d)
                    paint.shader = command.gradient?.shader(width.toFloat(), height.toFloat(), d)
                    canvas.drawPath(command.path, paint)
                }
                is DrawText -> {
                    val layout = TextMeasure.layout(command.spec, -1f)
                    canvas.save()
                    canvas.translate(command.x * d - command.ax * layout.width, command.y * d - command.ay * layout.height)
                    layout.draw(canvas)
                    canvas.restore()
                }
            }
        }
        paint.shader = null
    }
}

/** A blurred shadow of a shape (for effects that need a soft shadow behind arbitrary content). */
fun shadowPaint(shadow: Shadow, density: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = shadow.color
    if (shadow.radius > 0) maskFilter = BlurMaskFilter(shadow.radius * density, BlurMaskFilter.Blur.NORMAL)
}

/** A Material Symbols glyph as a drawable (app bar actions), tinted by the theme. */
class SymbolDrawable(private val glyph: String, filled: Boolean, density: Float) : Drawable() {
    private val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Fonts.symbols
        textSize = 24 * density
        fontVariationSettings = "'FILL' ${if (filled) 1 else 0}"
        color = 0xFF000000.toInt()
    }
    private val size = (24 * density).toInt()

    override fun draw(canvas: Canvas) {
        val b = bounds
        val m = paint.fontMetrics
        val w = paint.measureText(glyph)
        canvas.drawText(glyph, b.exactCenterX() - w / 2, b.exactCenterY() - (m.ascent + m.descent) / 2, paint)
    }
    override fun getIntrinsicWidth() = size
    override fun getIntrinsicHeight() = size
    override fun setAlpha(alpha: Int) { paint.alpha = alpha }
    override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) { paint.colorFilter = colorFilter }
    override fun setTintList(tint: android.content.res.ColorStateList?) {
        paint.colorFilter = tint?.let { PorterDuffColorFilter(it.defaultColor, PorterDuff.Mode.SRC_IN) }
        invalidateSelf()
    }
    @Deprecated("Deprecated in Java")
    override fun getOpacity() = android.graphics.PixelFormat.TRANSLUCENT
}
