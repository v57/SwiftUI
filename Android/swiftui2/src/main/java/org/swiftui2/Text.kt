package org.swiftui2

import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.MetricAffectingSpan
import android.text.style.StrikethroughSpan
import android.text.style.UnderlineSpan
import android.view.MotionEvent
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** Fonts: system families by design/weight, app fonts from `assets/fonts/<name>.ttf|otf`. */
object Fonts {
    private val cache = HashMap<String, Typeface>()
    lateinit var context: Context

    /** The Material Symbols variable font (assets/MaterialSymbolsOutlined.ttf). */
    val symbols: Typeface by lazy {
        runCatching { Typeface.createFromAsset(context.assets, "MaterialSymbolsOutlined.ttf") }.getOrElse { Typeface.DEFAULT }
    }

    fun typeface(design: Int, weight: Int, italic: Boolean, name: String?): Typeface {
        val key = "$design/$weight/$italic/$name"
        cache[key]?.let { return it }
        val base = when {
            name != null -> named(name) ?: Typeface.DEFAULT
            design == 1 -> Typeface.MONOSPACE
            design == 2 -> Typeface.SERIF
            else -> Typeface.DEFAULT
        }
        val result = Typeface.create(base, weight.coerceIn(1, 1000), italic)
        cache[key] = result
        return result
    }

    private fun named(name: String): Typeface? {
        for (ext in arrayOf("ttf", "otf")) {
            runCatching { return Typeface.createFromAsset(context.assets, "fonts/$name.$ext") }
        }
        return when (name.lowercase()) {
            "menlo", "monaco", "courier", "courier new", "sf mono" -> Typeface.MONOSPACE
            "georgia", "times", "times new roman", "new york" -> Typeface.SERIF
            else -> Typeface.create(name, Typeface.NORMAL)
        }
    }
}

/** Font attributes of a run (TypefaceSpan(Typeface) needs API 28; this also sets size/axes). */
class FontSpan(
    private val typeface: Typeface, private val sizePx: Float, private val letterSpacingPx: Float,
    private val baselineShiftPx: Float, private val features: String?, private val variation: String?,
) : MetricAffectingSpan() {
    override fun updateMeasureState(paint: TextPaint) = apply(paint)
    override fun updateDrawState(paint: TextPaint) = apply(paint)

    private fun apply(paint: TextPaint) {
        paint.typeface = typeface
        paint.textSize = sizePx
        if (letterSpacingPx != 0f && sizePx > 0) paint.letterSpacing = letterSpacingPx / sizePx
        if (baselineShiftPx != 0f) paint.baselineShift -= baselineShiftPx.toInt()
        if (features != null) paint.fontFeatureSettings = features
        if (variation != null) paint.fontVariationSettings = variation
    }
}

/** A link run: tapping it opens the URL (through the view's openURL action). */
class LinkSpan(val url: String) : android.text.style.CharacterStyle() {
    override fun updateDrawState(paint: TextPaint) {}
}

/** Decoded text (ByteWriter.text): styled string and paragraph attributes. */
class TextSpec(
    val text: CharSequence,
    val lineLimit: Int,
    val alignment: Int,
    val truncation: Int,
    val lineSpacingPx: Float,
    val minimumScaleFactor: Float,
    val minimumLines: Int,
    val redacted: Boolean,
    val firstSizePx: Float,
    val gradient: Gradient?,
) {
    fun layout(paint: TextPaint, widthPx: Int): StaticLayout {
        val alignment = when (alignment) {
            1 -> Layout.Alignment.ALIGN_CENTER
            2 -> Layout.Alignment.ALIGN_OPPOSITE
            else -> Layout.Alignment.ALIGN_NORMAL
        }
        paint.textSize = firstSizePx
        val builder = StaticLayout.Builder.obtain(text, 0, text.length, paint, max(1, widthPx))
            .setAlignment(alignment)
            .setIncludePad(false)
            .setLineSpacing(lineSpacingPx, 1f)
            .setUseLineSpacingFromFallbacks(true)
            .setBreakStrategy(Layout.BREAK_STRATEGY_HIGH_QUALITY)
        if (lineLimit > 0) {
            builder.setMaxLines(lineLimit)
            builder.setEllipsize(
                if (lineLimit == 1) when (truncation) { 0 -> TextUtils.TruncateAt.START; 1 -> TextUtils.TruncateAt.MIDDLE; else -> TextUtils.TruncateAt.END }
                else TextUtils.TruncateAt.END,
            )
        }
        return builder.build()
    }

    companion object {
        fun read(r: Reader, density: Float): TextSpec {
            val builder = SpannableStringBuilder()
            var firstSize = 0f
            var gradient: Gradient? = null
            val runCount = r.i32()
            repeat(runCount) { index ->
                val kind = r.u8()
                val string = r.string() ?: ""
                val sizeDp = r.f32(); val weight = r.i32(); val design = r.u8(); val italic = r.bool()
                val monospacedDigit = r.bool(); val name = r.string(); r.f32() // width axis
                val start = builder.length
                var span: FontSpan
                val color: Int
                if (kind == 1) {
                    // Inline symbol: Material Symbols ligature in the symbol font.
                    val glyphSize = r.f32(); val glyphWeight = r.i32(); val filled = r.bool()
                    color = r.color()
                    builder.append(string)
                    span = FontSpan(Fonts.symbols, glyphSize * density, 0f, 0f, null, "'FILL' ${if (filled) 1 else 0}, 'wght' $glyphWeight")
                } else {
                    color = r.color()
                    builder.append(string)
                    span = FontSpan(Fonts.typeface(design, weight, italic, name), sizeDp * density, 0f, 0f, if (monospacedDigit) "tnum" else null, null)
                }
                if (index == 0) firstSize = sizeDp * density
                val flags = r.u8()
                val tracking = r.f32(); val baselineOffset = r.f32()
                val background = r.optColor()
                val link = r.string()
                val runGradient = if (r.bool()) Gradient.read(r) else null
                if (runGradient != null) gradient = runGradient
                if (tracking != 0f || baselineOffset != 0f) {
                    span = if (kind == 1) span else FontSpan(Fonts.typeface(design, weight, italic, name), sizeDp * density, tracking * density, baselineOffset * density, if (monospacedDigit) "tnum" else null, null)
                }
                val end = builder.length
                if (end > start) {
                    builder.setSpan(span, start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    builder.setSpan(ForegroundColorSpan(color), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    if (flags and 1 != 0) builder.setSpan(StrikethroughSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    if (flags and 2 != 0) builder.setSpan(UnderlineSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    if (background != null) builder.setSpan(BackgroundColorSpan(background), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    if (link != null) builder.setSpan(LinkSpan(link), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            }
            val lineLimit = r.i32()
            val alignment = r.u8()
            val truncation = r.u8()
            val lineSpacing = r.f32()
            val minimumScaleFactor = r.f32()
            val minimumLines = r.i32()
            val redacted = r.bool()
            return TextSpec(builder, lineLimit, alignment, truncation, lineSpacing * density, minimumScaleFactor, minimumLines, redacted, firstSize, gradient)
        }
    }
}

/** Text measurement for Swift's layout (`sui_measure_text`): StaticLayout, as TextNode draws. */
object TextMeasure {
    private val paint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    var density = 1f

    /** out = width, height, first baseline, line height (dp). maxWidth < 0: unconstrained. */
    @JvmStatic
    fun measure(spec: ByteBuffer, maxWidth: Float, out: FloatArray) {
        spec.order(ByteOrder.LITTLE_ENDIAN)
        val text = TextSpec.read(Reader(spec), density)
        val layout = layout(text, maxWidth)
        var width = 0f
        for (line in 0 until layout.lineCount) width = max(width, layout.getLineWidth(line))
        if (maxWidth >= 0 && text.lineLimit > 0 && layout.getEllipsisCount(layout.lineCount - 1) > 0) {
            // Truncated text takes the whole proposed width (its last line ends in "…").
            width = maxWidth * density
        }
        out[0] = ceil(width) / density
        out[1] = layout.height / density
        out[2] = (if (layout.lineCount > 0) layout.getLineBaseline(0) else 0) / density
        out[3] = (if (layout.lineCount > 0) layout.getLineBottom(0) - layout.getLineTop(0) else 0) / density
    }

    fun layout(text: TextSpec, maxWidthDp: Float): StaticLayout {
        val widthPx = if (maxWidthDp < 0) ceil(desiredWidth(text)).toInt() else (maxWidthDp * density).toInt()
        return text.layout(paint, widthPx)
    }

    private fun desiredWidth(text: TextSpec): Float {
        paint.textSize = text.firstSizePx
        return Layout.getDesiredWidth(text.text, paint)
    }
}

/** Static text: draws the same StaticLayout that measured it. */
class TextNode(host: HostView, id: Int) : NodeView(host, id, KIND_TEXT) {
    private var spec: TextSpec? = null
    private var layout: StaticLayout? = null
    private val paint = TextPaint(Paint.ANTI_ALIAS_FLAG)

    init { setWillNotDraw(false) }

    override fun applyContent(r: Reader) {
        spec = TextSpec.read(r, host.density)
        layout = null
        contentDescription = spec?.text
        invalidate()
    }

    override fun frameSizeChanged() {
        layout = null
    }

    private fun currentLayout(): StaticLayout? {
        val spec = spec ?: return null
        layout?.let { return it }
        val made = spec.layout(paint, max(width, 1))
        layout = made
        return made
    }

    override fun onDraw(canvas: Canvas) {
        val spec = spec ?: return
        val layout = currentLayout() ?: return
        if (spec.redacted) return drawPlaceholders(canvas, layout)
        val gradient = spec.gradient
        if (gradient != null) {
            paint.shader = gradient.shader(width.toFloat(), height.toFloat(), host.density)
        }
        canvas.save()
        canvas.clipRect(0, 0, width, max(height, layout.height))
        layout.draw(canvas)
        canvas.restore()
        paint.shader = null
    }

    private fun drawPlaceholders(canvas: Canvas, layout: StaticLayout) {
        val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        fill.color = (layout.paint.color and 0x00FFFFFF) or 0x29000000
        for (line in 0 until layout.lineCount) {
            val top = layout.getLineTop(line).toFloat(); val bottom = layout.getLineBottom(line).toFloat()
            val height = (bottom - top) * 0.6f
            val mid = (top + bottom) / 2
            val rect = RectF(layout.getLineLeft(line), mid - height / 2, layout.getLineRight(line), mid + height / 2)
            canvas.drawRoundRect(rect, height / 4, height / 4, fill)
        }
    }

    // Links: tapping a link run opens it.
    private var pressedLink: LinkSpan? = null

    private fun link(event: MotionEvent): LinkSpan? {
        val text = spec?.text as? Spanned ?: return null
        val layout = currentLayout() ?: return null
        val line = layout.getLineForVertical(event.y.toInt())
        val offset = layout.getOffsetForHorizontal(line, event.x)
        return text.getSpans(offset, offset, LinkSpan::class.java).firstOrNull()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pressedLink = link(event)
                return pressedLink != null
            }
            MotionEvent.ACTION_UP -> {
                val link = pressedLink
                pressedLink = null
                if (link != null && link === link(event)) host.event(nodeId, Events.OPEN_URL, text = link.url)
                return link != null
            }
            MotionEvent.ACTION_CANCEL -> pressedLink = null
        }
        return pressedLink != null
    }
}

/** Swift `ResolvedGradient` (ByteWriter.gradient). */
class Gradient(val kind: Int, val p: FloatArray, val colors: IntArray, val locations: FloatArray) {
    /** The shader for a `width` × `height` px area (radii are dp). */
    fun shader(width: Float, height: Float, density: Float): Shader = when (kind) {
        1 -> android.graphics.RadialGradient(p[0] * width, p[1] * height, max(p[3] * density, 0.01f), colors, startLocations(p[2], p[3]), Shader.TileMode.CLAMP)
        2 -> android.graphics.SweepGradient(p[0] * width, p[1] * height, colors, locations).also {
            val matrix = android.graphics.Matrix()
            matrix.setRotate(Math.toDegrees(p[2].toDouble()).toFloat(), p[0] * width, p[1] * height)
            it.setLocalMatrix(matrix)
        }
        3 -> android.graphics.RadialGradient(p[0] * width, p[1] * height, max(p[3] * min(width, height) / 2, 0.01f), colors, locations, Shader.TileMode.CLAMP)
        else -> LinearGradient(p[0] * width, p[1] * height, p[2] * width, p[3] * height, colors, locations, Shader.TileMode.CLAMP)
    }

    /** Radial gradients start at `startRadius`: stops are remapped into [start/end, 1]. */
    private fun startLocations(startRadius: Float, endRadius: Float): FloatArray {
        if (startRadius <= 0 || endRadius <= 0) return locations
        val offset = startRadius / endRadius
        return FloatArray(locations.size) { offset + locations[it] * (1 - offset) }
    }

    companion object {
        fun read(r: Reader): Gradient {
            val kind = r.u8()
            val p = floatArrayOf(r.f32(), r.f32(), r.f32(), r.f32())
            val count = r.i32()
            val colors = IntArray(count)
            val locations = FloatArray(count)
            for (i in 0 until count) {
                colors[i] = r.color()
                locations[i] = r.f32()
            }
            return Gradient(kind, p, colors, locations)
        }
    }
}
