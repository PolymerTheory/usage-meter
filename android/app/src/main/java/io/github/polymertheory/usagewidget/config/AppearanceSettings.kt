package io.github.polymertheory.usagewidget.config

import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.widget.TextViewCompat
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.slider.Slider
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Builds the "Customize" section of the settings screen: bar colours, the two
 * thresholds where they switch, the app background (per light/dark mode) and
 * the widget backgrounds — plus Restore defaults. Every change is persisted
 * immediately and reported through [onChanged]; `widgetToo` is false while a
 * slider is still being dragged, so the widget is repainted once on release.
 */
class AppearanceSettings(
    private val activity: AppCompatActivity,
    private val container: LinearLayout,
    private val onChanged: (appearance: Appearance, widgetToo: Boolean) -> Unit,
) {
    private var a = AppearanceStore.load(activity)
    private var syncing = false
    private val density = activity.resources.displayMetrics.density
    private fun dp(v: Int) = (v * density).roundToInt()

    private var restoreButton: MaterialButton? = null

    fun build() {
        container.removeAllViews()
        rows.clear()
        header("Customize")
        caption("Applies to both this screen and the home-screen widget.")

        subheader("Theme")
        themeToggle()

        subheader("Bar colors")
        colorRow("Low", a.lowColor, null) { commit(a.copy(lowColor = it ?: Appearance.DEFAULT_LOW)) }
        colorRow("Medium", a.midColor, null) { commit(a.copy(midColor = it ?: Appearance.DEFAULT_MID)) }
        colorRow("High", a.highColor, null) { commit(a.copy(highColor = it ?: Appearance.DEFAULT_HIGH)) }
        thresholdSliders()

        subheader("App background")
        colorRow("Light mode", a.appBgLight, DEFAULT_APP_LIGHT) { commit(a.copy(appBgLight = it)) }
        colorRow("Dark mode", a.appBgDark, DEFAULT_APP_DARK) { commit(a.copy(appBgDark = it)) }

        subheader("Widget background")
        colorRow("Card · light mode", a.widgetBgLight, Appearance.DEFAULT_CARD_LIGHT) { commit(a.copy(widgetBgLight = it)) }
        colorRow("Card · dark mode", a.widgetBgDark, Appearance.DEFAULT_CARD_DARK) { commit(a.copy(widgetBgDark = it)) }
        colorRow("Compact icon", a.iconBg, Appearance.DEFAULT_ICON_BG) { commit(a.copy(iconBg = it)) }

        restoreButton = MaterialButton(activity, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            text = "Restore defaults"
            isEnabled = !a.isDefault
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(8) }
            setOnClickListener { commit(Appearance()) }
        }
        container.addView(restoreButton)
    }

    private fun commit(newA: Appearance, widgetToo: Boolean = true) {
        val rebuild = newA.isDefault != a.isDefault
        val themeChanged = newA.themeMode != a.themeMode
        a = newA
        AppearanceStore.save(activity, a)
        // Recreates the activity in the new mode; the widget follows via resolveDark.
        if (themeChanged) applyNightMode(a.themeMode)
        onChanged(a, widgetToo)
        restoreButton?.isEnabled = !a.isDefault
        // Swatches/labels show the stored values, so redraw them after a pick.
        if (widgetToo && !syncing) {
            if (rebuild) build() else refreshSwatches()
        }
    }

    // ---- theme -------------------------------------------------------------

    private fun themeToggle() {
        val group = com.google.android.material.button.MaterialButtonToggleGroup(activity).apply {
            isSingleSelection = true
            isSelectionRequired = true
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(4) }
        }
        val modes = listOf(
            "System" to Appearance.THEME_SYSTEM,
            "Light" to Appearance.THEME_LIGHT,
            "Dark" to Appearance.THEME_DARK,
        )
        for ((label, mode) in modes) {
            val b = MaterialButton(activity, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
                text = label
                id = View.generateViewId()
                tag = mode
            }
            group.addView(b, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            if (mode == a.themeMode) group.check(b.id)
        }
        group.addOnButtonCheckedListener { g, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            val mode = g.findViewById<View>(checkedId).tag as Int
            if (mode != a.themeMode) commit(a.copy(themeMode = mode))
        }
        container.addView(group)
    }

    // ---- threshold sliders -------------------------------------------------

    private lateinit var midSlider: Slider
    private lateinit var highSlider: Slider
    private lateinit var midField: EditText
    private lateinit var highField: EditText

    private fun thresholdSliders() {
        midField = percentRow("Medium from") { typed ->
            Appearance.clampThresholds(typed, maxOf(a.highThreshold, typed + 1))
        }
        midSlider = slider(1f, 98f, a.midThreshold.toFloat())
        highField = percentRow("High from") { typed ->
            Appearance.clampThresholds(min(a.midThreshold, typed - 1), typed)
        }
        highSlider = slider(2f, 99f, a.highThreshold.toFloat())
        updateThresholdLabels()

        midSlider.addOnChangeListener { _, v, fromUser ->
            if (!fromUser || syncing) return@addOnChangeListener
            val (m, h) = Appearance.clampThresholds(v.toInt(), maxOf(a.highThreshold, v.toInt() + 1))
            moveThresholds(m, h)
        }
        highSlider.addOnChangeListener { _, v, fromUser ->
            if (!fromUser || syncing) return@addOnChangeListener
            val (m, h) = Appearance.clampThresholds(min(a.midThreshold, v.toInt() - 1), v.toInt())
            moveThresholds(m, h)
        }
    }

    /**
     * "Medium from [ 55 ] %" — a typed alternative to the slider. Applied when
     * the keyboard's Done is pressed or the field loses focus; [resolve] turns
     * the typed number into a valid, ordered (mid, high) pair, nudging the
     * other threshold if needed, exactly like dragging the slider would.
     */
    private fun percentRow(title: String, resolve: (Int) -> Pair<Int, Int>): EditText {
        val field = EditText(activity).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE
            filters = arrayOf(android.text.InputFilter.LengthFilter(2))
            gravity = Gravity.CENTER
            setSingleLine()
            minEms = 2
        }
        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(6) }
            addView(TextView(activity).apply { text = title; textSize = 15f })
            addView(field, LinearLayout.LayoutParams(dp(64), LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(8) })
            addView(TextView(activity).apply { text = "%"; textSize = 15f })
        }
        container.addView(row)

        fun apply() {
            val typed = field.text?.toString()?.toIntOrNull()
            if (typed == null) { updateThresholdLabels(); return }
            val (m, h) = resolve(typed)
            moveThresholds(m, h)
            onChanged(a, true) // repaint the widget once for a typed value
        }
        field.setOnEditorActionListener { v, actionId, _ ->
            if (actionId == android.view.inputmethod.EditorInfo.IME_ACTION_DONE) {
                apply()
                v.clearFocus()
                (activity.getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
                    as android.view.inputmethod.InputMethodManager).hideSoftInputFromWindow(v.windowToken, 0)
                true
            } else false
        }
        field.setOnFocusChangeListener { _, hasFocus -> if (!hasFocus) apply() }
        return field
    }

    private fun moveThresholds(mid: Int, high: Int) {
        syncing = true
        commit(a.copy(midThreshold = mid, highThreshold = high), widgetToo = false)
        midSlider.value = mid.toFloat()
        highSlider.value = high.toFloat()
        syncing = false
        updateThresholdLabels()
    }

    private fun updateThresholdLabels() {
        // Don't fight the user while they're typing in a field.
        if (!midField.hasFocus()) midField.setText(a.midThreshold.toString())
        if (!highField.hasFocus()) highField.setText(a.highThreshold.toString())
    }

    private fun slider(from: Float, to: Float, value: Float): Slider = Slider(activity).apply {
        valueFrom = from
        valueTo = to
        stepSize = 1f
        isTickVisible = false // 1% steps would draw ~100 dots along the track
        this.value = value.coerceIn(from, to)
        addOnSliderTouchListener(object : Slider.OnSliderTouchListener {
            override fun onStartTrackingTouch(slider: Slider) {}
            // Repaint the widget once, when the drag ends.
            override fun onStopTrackingTouch(slider: Slider) = onChanged(a, true)
        })
        container.addView(this)
    }

    // ---- colour rows + picker ---------------------------------------------

    private class SwatchRow(val view: View, val label: TextView, val title: String, val current: () -> Int?, val fallback: Int?)

    private val rows = mutableListOf<SwatchRow>()

    /**
     * [fallback] non-null means the setting is optional (backgrounds): null
     * stored value shows the built-in default and the picker offers "Default".
     */
    private fun colorRow(title: String, value: Int?, fallback: Int?, set: (Int?) -> Unit) {
        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(6), 0, dp(6))
            val tv = TypedValue()
            activity.theme.resolveAttribute(android.R.attr.selectableItemBackground, tv, true)
            setBackgroundResource(tv.resourceId)
        }
        val label = TextView(activity).apply {
            textSize = 15f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val swatch = View(activity).apply { layoutParams = LinearLayout.LayoutParams(dp(30), dp(30)) }
        row.addView(label)
        row.addView(swatch)
        container.addView(row)

        val current: () -> Int? = { currentValue(title) }
        rows += SwatchRow(swatch, label, title, current, fallback)
        paintRow(rows.last(), value)

        row.setOnClickListener {
            val shown = current() ?: fallback ?: Color.GRAY
            pickColor(title, shown, allowDefault = fallback != null, set)
        }
    }

    private fun currentValue(title: String): Int? = when (title) {
        "Low" -> a.lowColor
        "Medium" -> a.midColor
        "High" -> a.highColor
        "Light mode" -> a.appBgLight
        "Dark mode" -> a.appBgDark
        "Card · light mode" -> a.widgetBgLight
        "Card · dark mode" -> a.widgetBgDark
        "Compact icon" -> a.iconBg
        else -> null
    }

    private fun refreshSwatches() = rows.forEach { paintRow(it, it.current()) }

    private fun paintRow(row: SwatchRow, value: Int?) {
        val shown = value ?: row.fallback ?: Color.GRAY
        row.view.background = swatchDrawable(shown)
        row.label.text = if (value == null && row.fallback != null) "${row.title}  (default)" else row.title
    }

    private fun pickColor(title: String, current: Int, allowDefault: Boolean, onPick: (Int?) -> Unit) {
        val hex = EditText(activity).apply {
            setText(toHex(current))
            hint = "#RRGGBB"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            setSingleLine()
        }
        val preview = View(activity).apply {
            layoutParams = LinearLayout.LayoutParams(dp(30), dp(30)).apply { marginStart = dp(12) }
            background = swatchDrawable(current)
        }
        hex.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) {
                parseHex(s?.toString())?.let { preview.background = swatchDrawable(it) }
            }
        })
        val grid = GridLayout(activity).apply { columnCount = 6 }
        for (c in PALETTE) {
            grid.addView(View(activity).apply {
                background = swatchDrawable(c)
                layoutParams = GridLayout.LayoutParams().apply {
                    width = dp(34); height = dp(34)
                    setMargins(dp(5), dp(5), dp(5), dp(5))
                }
                setOnClickListener { hex.setText(toHex(c)) }
            })
        }
        val hexRow = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(10), 0, 0)
            addView(hex, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(preview)
        }
        val box = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), 0)
            addView(grid)
            addView(hexRow)
        }
        val builder = MaterialAlertDialogBuilder(activity)
            .setTitle(title)
            .setView(box)
            .setPositiveButton("OK") { _, _ ->
                val c = parseHex(hex.text?.toString())
                if (c != null) onPick(c)
                else Toast.makeText(activity, "Use a color like #34C759", Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton("Cancel", null)
        if (allowDefault) builder.setNeutralButton("Default") { _, _ -> onPick(null) }
        builder.show()
    }

    private fun swatchDrawable(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
        setStroke(dp(1), 0x55808080)
    }

    // ---- small text helpers -------------------------------------------------

    private fun header(text: String) = textView(text, com.google.android.material.R.style.TextAppearance_Material3_TitleLarge, top = 4)
    private fun subheader(text: String) = textView(text, com.google.android.material.R.style.TextAppearance_Material3_TitleSmall, top = 14)
    private fun caption(text: String): TextView =
        textView(text, com.google.android.material.R.style.TextAppearance_Material3_BodySmall, top = 2)

    private fun textView(text: String, style: Int, top: Int): TextView = TextView(activity).apply {
        this.text = text
        TextViewCompat.setTextAppearance(this, style)
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(top) }
        container.addView(this)
    }

    companion object {
        // Material 3 baseline window backgrounds — what the screen uses when untouched.
        val DEFAULT_APP_LIGHT = 0xFFFEF7FF.toInt()
        val DEFAULT_APP_DARK = 0xFF141218.toInt()

        val PALETTE = intArrayOf(
            0xFF34C759.toInt(), 0xFF30D158.toInt(), 0xFF00C7BE.toInt(), 0xFF0A84FF.toInt(),
            0xFF5E5CE6.toInt(), 0xFFBF5AF2.toInt(), 0xFFFF2D55.toInt(), 0xFFFF3B30.toInt(),
            0xFFFF9500.toInt(), 0xFFFFCC00.toInt(), 0xFFA2845E.toInt(), 0xFF8E8E93.toInt(),
            0xFFFFFFFF.toInt(), 0xFFF2F2F7.toInt(), 0xFFE3E8EE.toInt(), 0xFF263140.toInt(),
            0xFF151B23.toInt(), 0xFF000000.toInt(),
        )

        fun toHex(color: Int) = String.format("#%06X", color and 0xFFFFFF)

        /** Accepts "#RRGGBB" or "RRGGBB"; always returns an opaque colour. */
        fun parseHex(s: String?): Int? {
            val t = s?.trim()?.removePrefix("#") ?: return null
            if (t.length != 6 || !t.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) return null
            return (0xFF000000 or t.toLong(16)).toInt()
        }

        /** Applies the app-wide light/dark override (process-global in AppCompat). */
        fun applyNightMode(mode: Int) {
            androidx.appcompat.app.AppCompatDelegate.setDefaultNightMode(
                when (mode) {
                    Appearance.THEME_LIGHT -> androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_NO
                    Appearance.THEME_DARK -> androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_YES
                    else -> androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
                },
            )
        }

        fun isNight(activity: AppCompatActivity): Boolean =
            (activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
    }
}
