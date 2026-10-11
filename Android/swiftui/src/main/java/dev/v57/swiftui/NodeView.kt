package dev.v57.swiftui

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Outline
import android.graphics.Path
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import kotlin.math.roundToInt

const val KIND_CONTAINER = 0
const val KIND_TEXT = 1
const val KIND_COLOR = 2
const val KIND_SHAPE = 3
const val KIND_IMAGE = 4
const val KIND_BUTTON = 5
const val KIND_TOGGLE = 6
const val KIND_TEXT_FIELD = 7
const val KIND_SLIDER = 8
const val KIND_SCROLL = 9
const val KIND_EFFECT = 10
const val KIND_DATE_PICKER = 11
const val KIND_COLOR_WELL = 12
const val KIND_DRAWING = 13
const val KIND_PLATFORM_VIEW = 14
const val KIND_MASK_SOURCE = 15

/**
 * A view for one SwiftUI platform render node. Frames come from SwiftUI's layout: a node is
 * measured and laid out to its frame directly (no Android layout pass is needed for frame
 * changes); `onMeasure`/`onLayout` only re-apply the stored frames when Android asks.
 */
abstract class NodeView(val host: HostView, val nodeId: Int, val kind: Int) : ViewGroup(host.context) {
    // Frame in the parent's coordinates (px).
    var frameLeft = 0; private set
    var frameTop = 0; private set
    var frameWidth = 0; private set
    var frameHeight = 0; private set

    init {
        clipChildren = false
        clipToPadding = false
        setWillNotDraw(true)
        isMotionEventSplittingEnabled = false
    }

    fun setFrame(x: Float, y: Float, w: Float, h: Float) {
        val d = host.density
        val left = (x * d).roundToInt()
        val top = (y * d).roundToInt()
        setFramePx(left, top, ((x + w) * d).roundToInt() - left, ((y + h) * d).roundToInt() - top)
    }

    fun setFramePx(left: Int, top: Int, width: Int, height: Int) {
        val sizeChanged = width != frameWidth || height != frameHeight
        frameLeft = left; frameTop = top; frameWidth = width; frameHeight = height
        if (sizeChanged) {
            measureToFrame()
            frameSizeChanged()
        }
        layoutToFrame()
        if (sizeChanged) updateTransform()
    }

    fun measureToFrame() {
        measure(MeasureSpec.makeMeasureSpec(frameWidth, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(frameHeight, MeasureSpec.EXACTLY))
    }

    fun layoutToFrame() = layout(frameLeft, frameTop, frameLeft + frameWidth, frameTop + frameHeight)

    /** The frame's size changed (before layout). */
    open fun frameSizeChanged() {}

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(frameWidth, frameHeight)
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child is NodeView) child.measureToFrame()
            else child.measure(MeasureSpec.makeMeasureSpec(frameWidth, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(frameHeight, MeasureSpec.EXACTLY))
        }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child is NodeView) child.layoutToFrame() else child.layout(0, 0, r - l, b - t)
        }
    }

    // MARK: Children

    /** The view node children are added to (scroll views: themselves; the content scrolls). */
    open val childContainer: ViewGroup get() = this

    open fun setChildren(children: List<NodeView>) {
        val container = childContainer
        val wanted = HashSet<View>(children)
        for (i in container.childCount - 1 downTo 0) {
            val child = container.getChildAt(i)
            if (child is NodeView && child !in wanted) container.removeViewInLayout(child)
        }
        var index = firstNodeChildIndex()
        for (child in children) {
            if (container.getChildAt(index) !== child) {
                (child.parent as? ViewGroup)?.removeViewInLayout(child)
                (container as NodeView).addNodeChild(child, index)
            }
            index++
        }
        container.invalidate()
    }

    /** Index where node children start (after a node's own native views). */
    open fun firstNodeChildIndex() = 0

    fun addNodeChild(child: NodeView, index: Int) {
        addViewInLayout(child, index, child.layoutParams ?: generateDefaultLayoutParams(), true)
        child.layoutToFrame()
    }

    fun removeChild(child: NodeView) = childContainer.removeViewInLayout(child)

    abstract fun applyContent(r: Reader)

    /** Extra description for tree dumps. */
    open fun describe(): String = ""

    open fun destroyed() {}

    // MARK: Presentation and transforms

    private var presentation = Presentation.IDENTITY
    /** The node's own opacity (opacity effect / disabled controls). */
    var baseAlpha = 1f
        set(value) { field = value; updateAlpha() }

    /** Effect transform: offset/scale/rotation about an anchor, or a projection (3x3, row major). */
    var effectTransform: FloatArray? = null
        set(value) { field = value; updateTransform() }
    var effectProjection: FloatArray? = null
        set(value) { field = value; updateTransform() }

    fun setPresentation(p: Presentation) {
        presentation = p
        updateAlpha()
        updateTransform()
    }

    private fun updateAlpha() {
        alpha = baseAlpha * presentation.opacity
    }

    private val matrix = Matrix()

    fun updateTransform() {
        val d = host.density
        val w = frameWidth.toFloat(); val h = frameHeight.toFloat()
        val effect = effectTransform
        val projection = effectProjection
        val p = presentation
        val hasPresentation = !p.isIdentity
        if (projection == null && (effect == null || !hasPresentation)) {
            // One anchored transform: plain view properties.
            if (android.os.Build.VERSION.SDK_INT >= 29) animationMatrix = null
            val offsetX: Float; val offsetY: Float; val sx: Float; val sy: Float; val rotation: Float; val ax: Float; val ay: Float
            if (effect != null) {
                offsetX = effect[0]; offsetY = effect[1]; sx = effect[2]; sy = effect[3]; rotation = effect[4]; ax = effect[5]; ay = effect[6]
            } else {
                offsetX = p.offsetX; offsetY = p.offsetY; sx = p.scaleX; sy = p.scaleY; rotation = p.rotation; ax = p.anchorX; ay = p.anchorY
            }
            pivotX = ax * w; pivotY = ay * h
            scaleX = sx; scaleY = sy
            this.rotation = rotation
            translationX = offsetX * d; translationY = offsetY * d
            return
        }
        // Composite: effect (projection or anchored), then the presentation, as a matrix.
        pivotX = 0f; pivotY = 0f; scaleX = 1f; scaleY = 1f; rotation = 0f; translationX = 0f; translationY = 0f
        matrix.reset()
        if (projection != null) {
            val m = projection
            matrix.setValues(floatArrayOf(m[0], m[3], m[6] * d, m[1], m[4], m[7] * d, m[2] / d, m[5] / d, m[8]))
        } else if (effect != null) {
            anchored(matrix, effect[0] * d, effect[1] * d, effect[2], effect[3], effect[4], effect[5] * w, effect[6] * h)
        }
        if (hasPresentation) {
            val pm = Matrix()
            anchored(pm, p.offsetX * d, p.offsetY * d, p.scaleX, p.scaleY, p.rotation, p.anchorX * w, p.anchorY * h)
            matrix.postConcat(pm)
        }
        if (android.os.Build.VERSION.SDK_INT >= 29) animationMatrix = Matrix(matrix)
        invalidate()
    }

    private fun anchored(m: Matrix, tx: Float, ty: Float, sx: Float, sy: Float, degrees: Float, ax: Float, ay: Float) {
        m.setTranslate(-ax, -ay)
        m.postScale(sx, sy)
        m.postRotate(degrees)
        m.postTranslate(ax + tx, ay + ty)
    }

    // MARK: Accessibility

    open fun applyAccessibility(hidden: Boolean, label: String?, value: String?, identifier: String?) {
        importantForAccessibility = if (hidden) IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS else IMPORTANT_FOR_ACCESSIBILITY_AUTO
        if (label != null || value != null) contentDescription = listOfNotNull(label, value).joinToString(", ")
        if (identifier != null) tag = identifier
    }

    companion object {
        fun make(host: HostView, id: Int, kind: Int): NodeView = when (kind) {
            KIND_TEXT -> TextNode(host, id)
            KIND_COLOR -> ColorNode(host, id)
            KIND_SHAPE -> ShapeNode(host, id)
            KIND_IMAGE -> ImageNode(host, id)
            KIND_BUTTON -> ButtonNode(host, id)
            KIND_TOGGLE -> ToggleNode(host, id)
            KIND_TEXT_FIELD -> TextFieldNode(host, id)
            KIND_SLIDER -> SliderNode(host, id)
            KIND_SCROLL -> ScrollNode(host, id)
            KIND_EFFECT -> EffectNode(host, id)
            KIND_DATE_PICKER -> DatePickerNode(host, id)
            KIND_COLOR_WELL -> ColorWellNode(host, id)
            KIND_DRAWING -> CanvasNode(host, id)
            KIND_MASK_SOURCE -> MaskSourceNode(host, id)
            KIND_PLATFORM_VIEW -> PlatformViewNode(host, id)
            else -> ContainerNode(host, id)
        }

        /** Consumes a content payload for a view that no longer exists. */
        fun skipContent(host: HostView, kind: Int, r: Reader) = make(host, -1, kind).applyContent(r)
    }
}

/** Layout-only container (the root, groups). */
open class ContainerNode(host: HostView, id: Int) : NodeView(host, id, KIND_CONTAINER) {
    override fun applyContent(r: Reader) { r.u8() }
}

/** `.mask { }` content: drawn only into its container's mask. */
class MaskSourceNode(host: HostView, id: Int) : NodeView(host, id, KIND_MASK_SOURCE) {
    override fun applyContent(r: Reader) { EffectNode.readEffect(r); r.u8() }
    override fun dispatchDraw(canvas: Canvas) {
        if ((parent as? EffectNode)?.drawingMask == true) super.dispatchDraw(canvas)
    }
}

class ColorNode(host: HostView, id: Int) : NodeView(host, id, KIND_COLOR) {
    private var color = 0
    private val paint = android.graphics.Paint()
    init { setWillNotDraw(false) }

    override fun applyContent(r: Reader) {
        val updated = r.color()
        if (updated != color) {
            color = updated
            invalidate()
        }
    }

    // drawColor would fill the whole clip (parents don't clip their children).
    override fun onDraw(canvas: Canvas) {
        paint.color = color
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
    }
}

/** Paths (ByteWriter.path), in dp; scaled to px when built. */
object Paths {
    fun read(r: Reader, density: Float, into: Path = Path()): Path {
        into.reset()
        val count = r.i32()
        repeat(count) {
            when (r.u8()) {
                0 -> into.moveTo(r.f32() * density, r.f32() * density)
                1 -> into.lineTo(r.f32() * density, r.f32() * density)
                2 -> { val cx = r.f32(); val cy = r.f32(); val x = r.f32(); val y = r.f32(); into.quadTo(cx * density, cy * density, x * density, y * density) }
                3 -> {
                    val c1x = r.f32(); val c1y = r.f32(); val c2x = r.f32(); val c2y = r.f32(); val x = r.f32(); val y = r.f32()
                    into.cubicTo(c1x * density, c1y * density, c2x * density, c2y * density, x * density, y * density)
                }
                else -> into.close()
            }
        }
        return into
    }

    /** Boolean operation of two encoded paths (dp), for Swift's `Path.union` & co. */
    @JvmStatic
    fun op(buffer: java.nio.ByteBuffer, operation: Int, evenOdd: Boolean): ByteArray {
        buffer.order(java.nio.ByteOrder.LITTLE_ENDIAN)
        val r = Reader(buffer)
        val a = read(r, 1f)
        val b = read(r, 1f)
        if (evenOdd) { a.fillType = Path.FillType.EVEN_ODD; b.fillType = Path.FillType.EVEN_ODD }
        val op = when (operation) {
            1, 4 -> Path.Op.INTERSECT
            2, 5 -> Path.Op.DIFFERENCE
            3 -> Path.Op.XOR
            else -> Path.Op.UNION
        }
        val result = Path()
        result.op(a, b, op)
        return encode(result)
    }

    /** Encodes a path like Swift's ByteWriter.path (dp). */
    fun encode(path: Path): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = java.nio.ByteBuffer.allocate(4 + 25).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        val elements = ArrayList<Pair<Int, FloatArray>>()
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            val iterator = path.pathIterator
            val points = FloatArray(8)
            while (iterator.hasNext()) {
                when (iterator.next(points, 0)) {
                    android.graphics.PathIterator.VERB_MOVE -> elements += 0 to floatArrayOf(points[0], points[1])
                    android.graphics.PathIterator.VERB_LINE -> elements += 1 to floatArrayOf(points[2], points[3])
                    android.graphics.PathIterator.VERB_QUAD -> elements += 2 to floatArrayOf(points[2], points[3], points[4], points[5])
                    android.graphics.PathIterator.VERB_CUBIC -> elements += 3 to floatArrayOf(points[2], points[3], points[4], points[5], points[6], points[7])
                    android.graphics.PathIterator.VERB_CLOSE -> elements += 4 to floatArrayOf()
                    android.graphics.PathIterator.VERB_CONIC -> elements += 2 to floatArrayOf(points[2], points[3], points[4], points[5])
                    else -> {}
                }
            }
        } else {
            // Before API 34: a polyline approximation (one contour per jump).
            val approx = path.approximate(0.25f)
            var i = 0
            var lastFraction = -1f
            while (i < approx.size) {
                val fraction = approx[i]; val x = approx[i + 1]; val y = approx[i + 2]
                elements += (if (fraction == lastFraction || elements.isEmpty()) 0 else 1) to floatArrayOf(x, y)
                lastFraction = fraction
                i += 3
            }
        }
        buffer.putInt(elements.size)
        out.write(buffer.array(), 0, 4)
        for ((verb, values) in elements) {
            buffer.clear()
            buffer.put(verb.toByte())
            for (v in values) buffer.putFloat(v)
            out.write(buffer.array(), 0, buffer.position())
        }
        return out.toByteArray()
    }

    /** A rounded-rect clip (the common case) can use the view outline: fast and antialiased. */
    fun roundedRect(path: Path): Pair<RectF, Float>? {
        val rect = RectF()
        if (path.isRect(rect)) return rect to 0f
        return null
    }
}

/** Outline clipping for rectangular clips. */
class RectOutline(private val rect: RectF, private val radius: Float) : ViewOutlineProvider() {
    override fun getOutline(view: View, outline: Outline) {
        outline.setRoundRect(rect.left.toInt(), rect.top.toInt(), rect.right.toInt(), rect.bottom.toInt(), radius)
    }
}

/** Placeholder for embedded native views (representables). */
class PlatformViewNode(host: HostView, id: Int) : NodeView(host, id, KIND_PLATFORM_VIEW) {
    override fun applyContent(r: Reader) { r.i32() }
}

/** Touch helpers. */
fun MotionEvent.inside(view: View) = x >= 0 && y >= 0 && x < view.width && y < view.height
