package io.github.polymertheory.usagewidget.config

import android.content.Context

/**
 * User-customisable look, shared by the in-app detail screen and the home-screen
 * widget. Bar colours and the thresholds where they switch apply everywhere, so
 * the app and the widget always agree. Defaults reproduce the original palette
 * (and the Mac app's defaults): green < 55%, yellow < 80%, red >= 80%.
 *
 * Background colours are nullable: null means "use the built-in default for that
 * mode", so an untouched install looks exactly as before.
 */
data class Appearance(
    val lowColor: Int = DEFAULT_LOW,
    val midColor: Int = DEFAULT_MID,
    val highColor: Int = DEFAULT_HIGH,
    /** Below this percent the bar is [lowColor]; at/above it becomes [midColor]. */
    val midThreshold: Int = DEFAULT_MID_THRESHOLD,
    /** At/above this percent the bar becomes [highColor]. */
    val highThreshold: Int = DEFAULT_HIGH_THRESHOLD,
    val appBgLight: Int? = null,
    val appBgDark: Int? = null,
    val widgetBgLight: Int? = null,
    val widgetBgDark: Int? = null,
    val iconBg: Int? = null,
    /** [THEME_SYSTEM] follows the phone; [THEME_LIGHT]/[THEME_DARK] force one. */
    val themeMode: Int = THEME_SYSTEM,
) {
    /** Whether to draw dark, given what the system currently says. */
    fun resolveDark(systemDark: Boolean): Boolean = when (themeMode) {
        THEME_LIGHT -> false
        THEME_DARK -> true
        else -> systemDark
    }

    fun colorFor(percent: Double?): Int = when {
        percent == null -> UNAVAILABLE
        percent < midThreshold -> lowColor
        percent < highThreshold -> midColor
        else -> highColor
    }

    fun appBackground(dark: Boolean): Int? = if (dark) appBgDark else appBgLight
    fun widgetBackground(dark: Boolean): Int =
        (if (dark) widgetBgDark else widgetBgLight) ?: if (dark) DEFAULT_CARD_DARK else DEFAULT_CARD_LIGHT
    fun iconBackground(): Int = iconBg ?: DEFAULT_ICON_BG

    val isDefault: Boolean get() = this == Appearance()

    companion object {
        const val DEFAULT_LOW = 0xFF34C759.toInt()
        const val DEFAULT_MID = 0xFFFFCC00.toInt()
        const val DEFAULT_HIGH = 0xFFFF3B30.toInt()
        const val DEFAULT_MID_THRESHOLD = 55
        const val DEFAULT_HIGH_THRESHOLD = 80
        const val UNAVAILABLE = 0xFF5B6673.toInt()
        const val DEFAULT_CARD_LIGHT = 0xFFFFFFFF.toInt()
        const val DEFAULT_CARD_DARK = 0xFF151B23.toInt()
        const val DEFAULT_ICON_BG = 0xFF0B0F14.toInt()
        const val THEME_SYSTEM = 0
        const val THEME_LIGHT = 1
        const val THEME_DARK = 2

        /** Keep thresholds in 1..99 and strictly ordered so the UI can't wedge them. */
        fun clampThresholds(mid: Int, high: Int): Pair<Int, Int> {
            val m = mid.coerceIn(1, 98)
            val h = high.coerceIn(m + 1, 99)
            return m to h
        }

        /** True when text drawn on [color] should be light (i.e. the colour is dark). */
        fun isDark(color: Int): Boolean {
            val r = ((color shr 16) and 0xFF) / 255.0
            val g = ((color shr 8) and 0xFF) / 255.0
            val b = (color and 0xFF) / 255.0
            return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5
        }
    }
}

/**
 * Persists [Appearance] in its own prefs file, separate from the sync URL/token,
 * so backup rules can keep the look while excluding the credential.
 */
object AppearanceStore {
    private const val PREFS = "appearance_prefs"

    fun load(context: Context): Appearance {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        fun opt(key: String): Int? = if (p.contains(key)) p.getInt(key, 0) else null
        val d = Appearance()
        val (mid, high) = Appearance.clampThresholds(
            p.getInt("mid_threshold", d.midThreshold),
            p.getInt("high_threshold", d.highThreshold),
        )
        return Appearance(
            lowColor = p.getInt("low_color", d.lowColor),
            midColor = p.getInt("mid_color", d.midColor),
            highColor = p.getInt("high_color", d.highColor),
            midThreshold = mid,
            highThreshold = high,
            appBgLight = opt("app_bg_light"),
            appBgDark = opt("app_bg_dark"),
            widgetBgLight = opt("widget_bg_light"),
            widgetBgDark = opt("widget_bg_dark"),
            iconBg = opt("icon_bg"),
            themeMode = p.getInt("theme_mode", Appearance.THEME_SYSTEM).coerceIn(0, 2),
        )
    }

    fun save(context: Context, a: Appearance) {
        val e = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear()
        e.putInt("low_color", a.lowColor)
        e.putInt("mid_color", a.midColor)
        e.putInt("high_color", a.highColor)
        e.putInt("mid_threshold", a.midThreshold)
        e.putInt("high_threshold", a.highThreshold)
        a.appBgLight?.let { e.putInt("app_bg_light", it) }
        a.appBgDark?.let { e.putInt("app_bg_dark", it) }
        a.widgetBgLight?.let { e.putInt("widget_bg_light", it) }
        a.widgetBgDark?.let { e.putInt("widget_bg_dark", it) }
        a.iconBg?.let { e.putInt("icon_bg", it) }
        e.putInt("theme_mode", a.themeMode)
        e.apply()
    }
}
