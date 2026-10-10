package org.swiftui2

import android.graphics.Canvas
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.widget.EdgeEffect
import android.widget.OverScroller
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * A SwiftUI2 scroll view: children are the content (frames relative to the content origin),
 * scrolled with `scrollTo`; touch dragging, flinging (OverScroller), the platform overscroll
 * effect (stretch) and native scrollbars. The offset is reported to Swift (lazy stacks, scroll
 * geometry) as it changes.
 */
class ScrollNode(host: HostView, id: Int) : NodeView(host, id, KIND_SCROLL) {
    private var horizontal = false
    private var vertical = true
    private var contentWidth = 0
    private var contentHeight = 0
    private var originX = 0
    private var originY = 0
    private var scrollEnabled = true
    private var requestID = 0
    private var appliedAnchor = false

    private val scroller = OverScroller(context)
    private val config = ViewConfiguration.get(context)
    private val touchSlop = config.scaledTouchSlop
    private val minFling = config.scaledMinimumFlingVelocity
    private val maxFling = config.scaledMaximumFlingVelocity
    private var velocity: VelocityTracker? = null
    private var dragging = false
    private var lastX = 0f
    private var lastY = 0f
    private var downX = 0f
    private var downY = 0f
    private val edgeTop = EdgeEffect(context)
    private val edgeBottom = EdgeEffect(context)
    private val edgeLeft = EdgeEffect(context)
    private val edgeRight = EdgeEffect(context)
    private var phase = PHASE_IDLE

    init {
        isScrollContainer = true
        scrollBarStyle = SCROLLBARS_INSIDE_OVERLAY
        isVerticalScrollBarEnabled = true
        isHorizontalScrollBarEnabled = false
        clipChildren = true
        setWillNotDraw(false)
        overScrollMode = OVER_SCROLL_IF_CONTENT_SCROLLS
    }

    override fun applyContent(r: Reader) {
        val d = host.density
        val axes = r.u8()
        horizontal = axes and 1 != 0
        vertical = axes and 2 != 0
        contentWidth = (r.f32() * d).roundToInt(); contentHeight = (r.f32() * d).roundToInt()
        originX = (r.f32() * d).roundToInt(); originY = (r.f32() * d).roundToInt()
        isVerticalScrollBarEnabled = r.bool() && vertical
        isHorizontalScrollBarEnabled = r.bool() && horizontal
        scrollEnabled = r.bool()
        clipChildren = r.bool()
        val request = r.i32()
        val hasRequest = r.bool()
        val requestX = r.f32(); val requestY = r.f32()
        val hasAnchor = r.bool()
        val anchorX = r.f32(); val anchorY = r.f32()
        r.u8(); r.u8() // bounce behaviors: Android overscroll follows the content size
        r.bool() // snapping (not yet)
        if (request != requestID && hasRequest) {
            requestID = request
            scroller.forceFinished(true)
            scrollToClamped((requestX * d).roundToInt(), (requestY * d).roundToInt())
        } else if (!appliedAnchor && hasAnchor && width > 0 && height > 0 && documentWidth > 0 && documentHeight > 0) {
            appliedAnchor = true
            scrollToClamped((maxX * anchorX).roundToInt(), (maxY * anchorY).roundToInt())
        } else {
            // The content may have shrunk.
            scrollToClamped(scrollX, scrollY)
        }
        awakenScrollBars()
    }

    private val documentWidth get() = max(contentWidth + originX, if (horizontal) 0 else width)
    private val documentHeight get() = max(contentHeight + originY, if (vertical) 0 else height)
    private val maxX get() = if (horizontal) max(0, documentWidth - width) else 0
    private val maxY get() = if (vertical) max(0, documentHeight - height) else 0

    private fun scrollToClamped(x: Int, y: Int) = scrollTo(x.coerceIn(0, maxX), y.coerceIn(0, maxY))

    override fun onScrollChanged(l: Int, t: Int, oldl: Int, oldt: Int) {
        super.onScrollChanged(l, t, oldl, oldt)
        val d = host.density
        host.event(nodeId, Events.SCROLLED, l / d.toDouble(), t / d.toDouble())
    }

    private fun setPhase(value: Int) {
        if (value == phase) return
        phase = value
        host.event(nodeId, Events.SCROLL_PHASE, value.toDouble())
    }

    // Scrollbars
    override fun computeVerticalScrollRange() = max(documentHeight, height)
    override fun computeVerticalScrollOffset() = scrollY
    override fun computeVerticalScrollExtent() = height
    override fun computeHorizontalScrollRange() = max(documentWidth, width)
    override fun computeHorizontalScrollOffset() = scrollX
    override fun computeHorizontalScrollExtent() = width

    private fun canScroll() = scrollEnabled && (maxX > 0 || maxY > 0 || overScrollMode == OVER_SCROLL_ALWAYS)

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        if (!scrollEnabled) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastX = event.x; lastY = event.y; downX = event.x; downY = event.y
                dragging = !scroller.isFinished
                if (dragging) {
                    scroller.forceFinished(true)
                    parent?.requestDisallowInterceptTouchEvent(true)
                    setPhase(PHASE_INTERACTING)
                }
                velocity?.clear()
                trackVelocity(event)
            }
            MotionEvent.ACTION_MOVE -> {
                trackVelocity(event)
                val dx = abs(event.x - downX)
                val dy = abs(event.y - downY)
                if (!dragging && ((vertical && maxY > 0 && dy > touchSlop && dy > dx) || (horizontal && maxX > 0 && dx > touchSlop && dx > dy))) {
                    dragging = true
                    lastX = event.x; lastY = event.y
                    parent?.requestDisallowInterceptTouchEvent(true)
                    setPhase(PHASE_INTERACTING)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> if (dragging) endDrag(event.actionMasked == MotionEvent.ACTION_UP)
        }
        return dragging
    }

    private fun trackVelocity(event: MotionEvent) {
        val tracker = velocity ?: VelocityTracker.obtain().also { velocity = it }
        tracker.addMovement(event)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!canScroll()) return false
        trackVelocity(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastX = event.x; lastY = event.y; downX = event.x; downY = event.y
                if (!scroller.isFinished) scroller.forceFinished(true)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (!dragging) {
                    val dx = abs(event.x - downX); val dy = abs(event.y - downY)
                    if (dx > touchSlop || dy > touchSlop) {
                        dragging = true
                        parent?.requestDisallowInterceptTouchEvent(true)
                        setPhase(PHASE_INTERACTING)
                    }
                }
                if (dragging) {
                    val dx = if (horizontal) (lastX - event.x).roundToInt() else 0
                    val dy = if (vertical) (lastY - event.y).roundToInt() else 0
                    lastX = event.x; lastY = event.y
                    dragBy(dx, dy, event)
                }
            }
            MotionEvent.ACTION_UP -> if (dragging) endDrag(true)
            MotionEvent.ACTION_CANCEL -> if (dragging) endDrag(false)
        }
        return true
    }

    private fun dragBy(dx: Int, dy: Int, event: MotionEvent) {
        var x = scrollX + dx
        var y = scrollY + dy
        // Pulling past an edge stretches it (consumed by the edge effect first when releasing).
        if (vertical) {
            if (y < 0) { edgeTop.onPullDistance(-y.toFloat() / height, event.x / width); y = 0 }
            else if (y > maxY) { edgeBottom.onPullDistance((y - maxY).toFloat() / height, 1 - event.x / width); y = maxY }
        }
        if (horizontal) {
            if (x < 0) { edgeLeft.onPullDistance(-x.toFloat() / width, 1 - event.y / height); x = 0 }
            else if (x > maxX) { edgeRight.onPullDistance((x - maxX).toFloat() / width, event.y / height); x = maxX }
        }
        scrollTo(x, y)
        awakenScrollBars()
        postInvalidateOnAnimation()
    }

    private fun endDrag(fling: Boolean) {
        dragging = false
        edgeTop.onRelease(); edgeBottom.onRelease(); edgeLeft.onRelease(); edgeRight.onRelease()
        val tracker = velocity
        var flung = false
        if (fling && tracker != null) {
            tracker.computeCurrentVelocity(1000, maxFling.toFloat())
            val vx = if (horizontal) -tracker.xVelocity.toInt() else 0
            val vy = if (vertical) -tracker.yVelocity.toInt() else 0
            if (abs(vx) > minFling || abs(vy) > minFling) {
                scroller.fling(scrollX, scrollY, vx, vy, 0, maxX, 0, maxY, 0, 0)
                flung = true
                setPhase(PHASE_DECELERATING)
                postInvalidateOnAnimation()
            }
        }
        velocity?.recycle()
        velocity = null
        if (!flung) setPhase(PHASE_IDLE)
    }

    override fun computeScroll() {
        if (scroller.computeScrollOffset()) {
            val x = scroller.currX; val y = scroller.currY
            if (x != scrollX || y != scrollY) scrollToClamped(x, y)
            if (scroller.isOverScrolled || (x <= 0 || x >= maxX) && (y <= 0 || y >= maxY) && scroller.isFinished) {
                // Hitting an edge mid-fling: absorb the remaining velocity into the edge effect.
                val v = scroller.currVelocity.toInt()
                if (vertical && y <= 0 && v > 0) edgeTop.onAbsorb(v)
                if (vertical && y >= maxY && maxY > 0 && v > 0) edgeBottom.onAbsorb(v)
            }
            postInvalidateOnAnimation()
        } else if (phase == PHASE_DECELERATING) {
            setPhase(PHASE_IDLE)
        }
    }

    override fun draw(canvas: Canvas) {
        super.draw(canvas)
        var invalidate = false
        fun drawEdge(edge: EdgeEffect, rotation: Float, tx: Float, ty: Float, w: Int, h: Int) {
            if (edge.isFinished) return
            val save = canvas.save()
            canvas.translate(tx, ty)
            canvas.rotate(rotation)
            edge.setSize(w, h)
            if (edge.draw(canvas)) invalidate = true
            canvas.restoreToCount(save)
        }
        drawEdge(edgeTop, 0f, scrollX.toFloat(), scrollY.toFloat(), width, height)
        drawEdge(edgeBottom, 180f, (scrollX + width).toFloat(), (scrollY + height).toFloat(), width, height)
        drawEdge(edgeLeft, 270f, scrollX.toFloat(), (scrollY + height).toFloat(), height, width)
        drawEdge(edgeRight, 90f, (scrollX + width).toFloat(), scrollY.toFloat(), height, width)
        if (invalidate) postInvalidateOnAnimation()
    }

    override fun frameSizeChanged() {
        post { scrollToClamped(scrollX, scrollY) }
    }

    companion object {
        const val PHASE_IDLE = 0
        const val PHASE_INTERACTING = 2
        const val PHASE_DECELERATING = 3
    }
}
