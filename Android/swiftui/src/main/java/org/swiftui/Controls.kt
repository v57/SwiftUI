package org.swiftui

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.RadioButton
import android.widget.SeekBar
import android.widget.Switch
import java.text.DateFormat
import java.util.Calendar
import java.util.Date
import kotlin.math.min
import kotlin.math.roundToInt

/** Theme colors. */
object Theme {
    fun color(context: Context, attr: Int, fallback: Int): Int {
        val value = TypedValue()
        return if (context.theme.resolveAttribute(attr, value, true)) {
            if (value.resourceId != 0) context.getColor(value.resourceId) else value.data
        } else fallback
    }

    fun accent(context: Context) = color(context, android.R.attr.colorAccent, 0xFF6750A4.toInt())

    fun isDark(context: Context) =
        (context.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES
}

fun withAlpha(color: Int, alpha: Float) = (color and 0x00FFFFFF) or ((alpha * 255).roundToInt().coerceIn(0, 255) shl 24)

/** Button: the label nodes are its children; the bezel is a Material shape with a ripple. */
class ButtonNode(host: HostView, id: Int) : NodeView(host, id, KIND_BUTTON) {
    private var style = 0
    private var enabled = true
    private var tint: Int? = null
    private var isOn = false
    private var shapeKind = 0
    private var radius = -1f
    private var repeats = false
    private val bezel = GradientDrawable()

    override fun applyContent(r: Reader) {
        style = r.u8()
        enabled = r.bool()
        tint = r.optColor()
        isOn = r.bool()
        shapeKind = r.u8()
        radius = r.f32()
        repeats = r.bool()
        baseAlpha = if (enabled) 1f else 0.38f
        updateBackground()
    }

    private val bordered get() = style == 0 || style == 1 || style == 2

    private fun updateBackground() {
        val dark = Theme.isDark(context)
        val accent = tint ?: Theme.accent(context)
        val ripple = ColorStateList.valueOf(withAlpha(if (style == 2) 0xFFFFFFFF.toInt() else accent, 0.2f))
        if (!bordered) {
            background = RippleDrawable(ripple, null, ColorDrawable(0xFFFFFFFF.toInt()))
            return
        }
        bezel.cornerRadius = cornerRadius()
        val fill = when (style) {
            2 -> accent
            else -> tint?.let { withAlpha(it, 0.16f) } ?: if (dark) 0x29FFFFFF else 0x14000000
        }
        bezel.setColor(if (isOn) blendBlack(fill, 0.12f) else fill)
        background = RippleDrawable(ripple, bezel, null)
    }

    private fun blendBlack(color: Int, fraction: Float): Int {
        fun c(shift: Int) = (((color shr shift) and 0xFF) * (1 - fraction)).roundToInt()
        return (color and 0xFF000000.toInt()) or (c(16) shl 16) or (c(8) shl 8) or c(0)
    }

    private fun cornerRadius(): Float {
        val h = frameHeight.toFloat(); val w = frameWidth.toFloat()
        return when (shapeKind) {
            2 -> min(w, h) / 2
            3 -> if (radius >= 0) min(radius * host.density, h / 2) else min(12 * host.density, h / 2)
            else -> h / 2 // Material buttons are fully rounded
        }
    }

    override fun frameSizeChanged() {
        if (bordered) bezel.cornerRadius = cornerRadius()
    }

    private var repeat: Runnable? = null

    override fun onInterceptTouchEvent(event: MotionEvent) = true

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!enabled) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                drawableHotspotChanged(event.x, event.y)
                isPressed = true
                if (!bordered) alpha = 0.6f * baseAlpha
                if (repeats) {
                    host.event(nodeId, Events.PRIMARY)
                    val runnable = object : Runnable {
                        override fun run() {
                            if (isPressed) { host.event(nodeId, Events.PRIMARY); postDelayed(this, 100) }
                        }
                    }
                    repeat = runnable
                    postDelayed(runnable, 400)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                drawableHotspotChanged(event.x, event.y)
                val inside = event.inside(this)
                if (inside != isPressed) isPressed = inside
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val fire = event.actionMasked == MotionEvent.ACTION_UP && event.inside(this) && repeat == null
                isPressed = false
                alpha = baseAlpha
                repeat?.let(::removeCallbacks)
                repeat = null
                if (fire) {
                    playSoundEffect(android.view.SoundEffectConstants.CLICK)
                    host.event(nodeId, Events.PRIMARY)
                }
            }
        }
        return true
    }
}

/** Toggle: a native Switch, CheckBox or RadioButton filling the frame. */
class ToggleNode(host: HostView, id: Int) : NodeView(host, id, KIND_TOGGLE) {
    private var widget: CompoundButton? = null
    private var widgetStyle = -1
    private var updating = false
    private var mixed = false

    override fun applyContent(r: Reader) {
        val isOn = r.bool()
        val style = r.u8()
        val enabled = r.bool()
        mixed = r.bool()
        r.u8() // control size
        if (style != widgetStyle) {
            widget?.let(::removeView)
            val created: CompoundButton = when (style) {
                1 -> Switch(context).apply { showText = false }
                2 -> RadioButton(context)
                else -> CheckBox(context)
            }
            created.minWidth = 0; created.minHeight = 0
            created.setPadding(0, 0, 0, 0)
            created.background = null
            created.setOnCheckedChangeListener { _, checked ->
                if (!updating) host.event(nodeId, Events.SET_BOOL, if (checked || mixed) 1.0 else 0.0)
            }
            addView(created)
            widget = created
            widgetStyle = style
        }
        val widget = widget!!
        updating = true
        if (widget.isChecked != isOn) widget.isChecked = isOn
        widget.isEnabled = enabled
        updating = false
    }
}

/** Text fields and editors: a native EditText. */
class TextFieldNode(host: HostView, id: Int) : NodeView(host, id, KIND_TEXT_FIELD) {
    private val field = EditText(context)
    private var updating = false
    private var wantsFocus = false
    private var configured = -1
    private val defaultBackground = field.background
    private val defaultPadding = intArrayOf(field.paddingLeft, field.paddingTop, field.paddingRight, field.paddingBottom)

    init {
        addView(field)
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                if (!updating) host.event(nodeId, Events.SET_TEXT, text = s.toString())
            }
        })
        field.setOnEditorActionListener { _, action, _ ->
            if (action == EditorInfo.IME_ACTION_DONE || action == EditorInfo.IME_NULL) {
                host.event(nodeId, Events.SUBMIT)
                false
            } else false
        }
        field.onFocusChangeListener = View.OnFocusChangeListener { _, focused ->
            host.event(nodeId, Events.FOCUS_CHANGED, if (focused) 1.0 else 0.0)
        }
    }

    /** Autofill hints from `textContentType`. */
    private fun autofill(contentType: String?) {
        val hint = when (contentType) {
            "username" -> View.AUTOFILL_HINT_USERNAME
            "password" -> View.AUTOFILL_HINT_PASSWORD
            "newPassword" -> "newPassword"
            "emailAddress" -> View.AUTOFILL_HINT_EMAIL_ADDRESS
            "telephoneNumber" -> View.AUTOFILL_HINT_PHONE
            "name" -> View.AUTOFILL_HINT_NAME
            "postalCode" -> View.AUTOFILL_HINT_POSTAL_CODE
            "fullStreetAddress" -> View.AUTOFILL_HINT_POSTAL_ADDRESS
            "creditCardNumber" -> View.AUTOFILL_HINT_CREDIT_CARD_NUMBER
            "oneTimeCode" -> "smsOTPCode"
            else -> null
        }
        if (hint != null) field.setAutofillHints(hint)
        field.importantForAutofill = if (hint != null) IMPORTANT_FOR_AUTOFILL_YES else IMPORTANT_FOR_AUTOFILL_AUTO
    }

    override fun applyContent(r: Reader) {
        val d = host.density
        val text = r.string() ?: ""
        val placeholder = r.string()
        val flags = r.u8()
        val style = r.u8()
        val size = r.f32(); val weight = r.i32(); val design = r.u8(); val italic = r.bool(); r.bool(); val name = r.string(); r.f32()
        val color = r.color()
        val alignment = r.u8()
        val contentType = r.string()
        val keyboard = r.u8()
        val capitalization = r.u8()
        val enabled = flags and 1 != 0
        val secure = flags and 2 != 0
        val multiline = flags and 4 != 0 || flags and 32 != 0
        val focus = flags and 8 != 0
        val noAutocorrect = flags and 16 != 0

        updating = true
        val configuration = (if (secure) 1 else 0) or (if (multiline) 2 else 0) or (if (noAutocorrect) 4 else 0) or (style shl 4) or
            (keyboard shl 8) or (capitalization shl 16) or ((contentType?.hashCode() ?: 0) shl 24)
        if (configuration != configured) {
            configured = configuration
            field.inputType = inputType(secure, multiline, noAutocorrect, keyboard, capitalization, contentType)
            autofill(contentType)
            field.isSingleLine = !multiline
            field.imeOptions = if (multiline) EditorInfo.IME_ACTION_NONE else EditorInfo.IME_ACTION_DONE
            field.gravity = (if (multiline) Gravity.TOP else Gravity.CENTER_VERTICAL) or Gravity.START
            when (style) {
                1 -> { field.background = null; field.setPadding(0, 0, 0, 0) }
                2 -> {
                    field.background = GradientDrawable().apply {
                        cornerRadius = 8 * d
                        setStroke((1 * d).roundToInt(), withAlpha(color, 0.38f))
                    }
                    field.setPadding(defaultPadding[0], defaultPadding[1], defaultPadding[2], defaultPadding[3])
                }
                else -> {
                    field.background = defaultBackground
                    field.setPadding(defaultPadding[0], defaultPadding[1], defaultPadding[2], defaultPadding[3])
                }
            }
        }
        if (field.text.toString() != text) {
            val selection = field.selectionEnd
            field.setText(text)
            field.setSelection(min(selection.coerceAtLeast(0), text.length))
        }
        field.hint = placeholder
        field.isEnabled = enabled
        field.setTextSize(TypedValue.COMPLEX_UNIT_PX, size * d)
        field.typeface = Fonts.typeface(design, weight, italic, name)
        field.setTextColor(color)
        field.setHintTextColor(withAlpha(color, 0.5f))
        field.textAlignment = when (alignment) { 1 -> TEXT_ALIGNMENT_CENTER; 2 -> TEXT_ALIGNMENT_VIEW_END; else -> TEXT_ALIGNMENT_VIEW_START }
        updating = false
        if (focus != wantsFocus) {
            wantsFocus = focus
            if (focus) post {
                field.requestFocus()
                context.getSystemService(InputMethodManager::class.java).showSoftInput(field, 0)
            } else if (field.hasFocus()) {
                field.clearFocus()
                context.getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(field.windowToken, 0)
            }
        }
    }
}

/** EditText input type from SwiftUI's keyboard type, autocapitalization and content type. */
private fun inputType(secure: Boolean, multiline: Boolean, noAutocorrect: Boolean, keyboard: Int, capitalization: Int, contentType: String?): Int {
    // UIKeyboardType: 2 numbersAndPunctuation, 3 URL, 4 numberPad, 5 phonePad, 7 emailAddress,
    // 8 decimalPad, 10 webSearch, 11 asciiCapableNumberPad.
    var type = when {
        keyboard == 4 || keyboard == 11 -> InputType.TYPE_CLASS_NUMBER
        keyboard == 8 -> InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        keyboard == 5 || contentType == "telephoneNumber" -> InputType.TYPE_CLASS_PHONE
        else -> InputType.TYPE_CLASS_TEXT
    }
    if (type == InputType.TYPE_CLASS_TEXT) {
        type = type or when {
            secure -> if (keyboard == 4 || keyboard == 11) InputType.TYPE_NUMBER_VARIATION_PASSWORD else InputType.TYPE_TEXT_VARIATION_PASSWORD
            keyboard == 3 || contentType == "URL" -> InputType.TYPE_TEXT_VARIATION_URI
            keyboard == 7 || contentType == "emailAddress" || contentType == "username" -> InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
            contentType == "name" || contentType == "givenName" || contentType == "familyName" -> InputType.TYPE_TEXT_VARIATION_PERSON_NAME
            contentType == "fullStreetAddress" -> InputType.TYPE_TEXT_VARIATION_POSTAL_ADDRESS
            keyboard == 10 -> InputType.TYPE_TEXT_VARIATION_FILTER
            else -> 0
        }
        type = type or when (capitalization) {
            1 -> InputType.TYPE_TEXT_FLAG_CAP_WORDS
            2 -> InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            3 -> InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
            0 -> 0
            else -> if (keyboard == 0 && !secure) InputType.TYPE_TEXT_FLAG_CAP_SENTENCES else 0
        }
        type = type or if (noAutocorrect || secure) InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS else InputType.TYPE_TEXT_FLAG_AUTO_CORRECT
        if (multiline) type = type or InputType.TYPE_TEXT_FLAG_MULTI_LINE
    }
    return type
}

/** Slider: a native SeekBar over the value range. */
class SliderNode(host: HostView, id: Int) : NodeView(host, id, KIND_SLIDER) {
    private val seekBar = SeekBar(context)
    private var low = 0.0
    private var high = 1.0
    private var updating = false

    init {
        seekBar.max = STEPS
        seekBar.setPadding(seekBar.paddingLeft, 0, seekBar.paddingRight, 0)
        addView(seekBar)
        seekBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
                if (fromUser && !updating) host.event(nodeId, Events.SET_DOUBLE, low + (high - low) * progress / STEPS)
            }
            override fun onStartTrackingTouch(bar: SeekBar) = host.event(nodeId, Events.EDITING_CHANGED, 1.0)
            override fun onStopTrackingTouch(bar: SeekBar) = host.event(nodeId, Events.EDITING_CHANGED, 0.0)
        })
    }

    override fun applyContent(r: Reader) {
        val value = r.f64()
        low = r.f64(); high = r.f64()
        val enabled = r.bool()
        val showsThumb = r.bool()
        updating = true
        seekBar.progress = if (high > low) ((value - low) / (high - low) * STEPS).roundToInt() else 0
        seekBar.isEnabled = enabled
        seekBar.thumb?.alpha = if (showsThumb) 255 else 0
        updating = false
    }

    companion object { const val STEPS = 10_000 }
}

/** Date picker: shows the formatted date; tapping opens the platform date/time dialogs. */
class DatePickerNode(host: HostView, id: Int) : NodeView(host, id, KIND_DATE_PICKER) {
    private var date = Date()
    private var hasDate = true
    private var hasTime = false
    private var enabled = true
    private var min: Long? = null
    private var max: Long? = null
    private val paint = android.text.TextPaint(Paint.ANTI_ALIAS_FLAG)

    init {
        setWillNotDraw(false)
        background = RippleDrawable(ColorStateList.valueOf(0x22000000), GradientDrawable().apply {
            cornerRadius = 8 * host.density
            setColor(if (Theme.isDark(context)) 0x29FFFFFF else 0x14000000)
        }, null)
    }

    override fun applyContent(r: Reader) {
        date = Date((r.f64() * 1000).toLong())
        hasDate = r.bool(); hasTime = r.bool(); enabled = r.bool(); r.u8()
        val hasRange = r.bool()
        val lo = r.f64(); val hi = r.f64()
        min = if (hasRange) (lo * 1000).toLong() else null
        max = if (hasRange) (hi * 1000).toLong() else null
        alpha = if (enabled) 1f else 0.38f
        invalidate()
    }

    private fun label(): String {
        val parts = ArrayList<String>()
        if (hasDate) parts += DateFormat.getDateInstance(DateFormat.MEDIUM).format(date)
        if (hasTime) parts += DateFormat.getTimeInstance(DateFormat.SHORT).format(date)
        return parts.joinToString("  ")
    }

    override fun onDraw(canvas: Canvas) {
        paint.textSize = 16 * host.density
        paint.color = if (Theme.isDark(context)) 0xFFFFFFFF.toInt() else 0xFF000000.toInt()
        val text = label()
        val w = paint.measureText(text)
        val m = paint.fontMetrics
        canvas.drawText(text, (width - w) / 2, (height - (m.descent - m.ascent)) / 2 - m.ascent, paint)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!enabled) return false
        if (event.actionMasked == MotionEvent.ACTION_DOWN) { drawableHotspotChanged(event.x, event.y); isPressed = true }
        if (event.actionMasked == MotionEvent.ACTION_CANCEL) isPressed = false
        if (event.actionMasked == MotionEvent.ACTION_UP) {
            isPressed = false
            if (event.inside(this)) pick()
        }
        return true
    }

    private fun pick() {
        val calendar = Calendar.getInstance().apply { time = date }
        fun send() = host.event(nodeId, Events.SET_DATE, calendar.timeInMillis / 1000.0)
        fun pickTime() = TimePickerDialog(context, { _, hour, minute ->
            calendar.set(Calendar.HOUR_OF_DAY, hour); calendar.set(Calendar.MINUTE, minute); send()
        }, calendar.get(Calendar.HOUR_OF_DAY), calendar.get(Calendar.MINUTE), android.text.format.DateFormat.is24HourFormat(context)).show()
        if (hasDate) {
            val dialog = DatePickerDialog(context, { _, year, month, day ->
                calendar.set(year, month, day)
                if (hasTime) pickTime() else send()
            }, calendar.get(Calendar.YEAR), calendar.get(Calendar.MONTH), calendar.get(Calendar.DAY_OF_MONTH))
            min?.let { dialog.datePicker.minDate = it }
            max?.let { dialog.datePicker.maxDate = it }
            dialog.show()
        } else if (hasTime) {
            pickTime()
        }
    }
}

/** Color well: a swatch (picking is not supported yet). */
class ColorWellNode(host: HostView, id: Int) : NodeView(host, id, KIND_COLOR_WELL) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    init { setWillNotDraw(false) }

    override fun applyContent(r: Reader) {
        paint.color = r.color()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val radius = min(width, height) / 2f
        canvas.drawCircle(width / 2f, height / 2f, radius, paint)
    }
}

/** Native widget metrics for Swift's layout (`AndroidControls`). */
object Widgets {
    fun controlMetrics(context: Context, density: Float): String {
        fun size(view: View): Pair<Float, Float> {
            view.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
            return view.measuredWidth / density to view.measuredHeight / density
        }
        fun compound(view: CompoundButton): CompoundButton = view.apply {
            minWidth = 0; minHeight = 0; setPadding(0, 0, 0, 0); background = null
        }
        val checkbox = size(compound(CheckBox(context)))
        val radio = size(compound(RadioButton(context)))
        val switch = size(compound(Switch(context).apply { showText = false }))
        val seekBar = SeekBar(context).let { it.setPadding(it.paddingLeft, 0, it.paddingRight, 0); size(it) }
        val field = EditText(context)
        val values = listOf(
            checkbox.first, checkbox.second, radio.first, radio.second, switch.first, switch.second, seekBar.second,
            field.paddingTop / density, field.paddingLeft / density, field.paddingBottom / density, field.paddingRight / density,
        )
        return values.joinToString(",")
    }
}
