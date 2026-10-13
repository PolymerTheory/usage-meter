package io.github.polymertheory.usagewidget

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import io.github.polymertheory.usagewidget.config.Appearance
import io.github.polymertheory.usagewidget.model.Usage
import io.github.polymertheory.usagewidget.model.UsageWindow
import kotlin.math.max
import kotlin.math.min

/** How the widget presents itself on the home screen. */
enum class WidgetStyle {
    /** Full rounded card with bars, percentages, labels — the detailed look. */
    CARD,

    /** App-icon-sized squircle of bars + label, blends into the icon grid. */
    ICON,
}

/**
 * Draws the UsageMeter four-bar glyph into a bitmap sized to the widget cell.
 * Bar colours, thresholds and backgrounds come from the user's [Appearance]
 * (defaults match the Mac app: green < 55%, yellow < 80%, red >= 80%).
 * Small cells show bars only; larger cells add percentages, window labels,
 * reset countdowns and an "updated" line.
 */
object WidgetRenderer {

    private data class Bar(val label: String, val window: UsageWindow?, val updatedAtMs: Long?)

    private const val TEXT_ON_DARK = 0xFFE7EDF3.toInt()
    private const val TEXT_ON_LIGHT = 0xFF1A2230.toInt()
    private const val MUTED_ON_DARK = 0xFF8B97A5.toInt()
    private const val MUTED_ON_LIGHT = 0xFF66707D.toInt()
    private const val TRACK_ON_DARK = 0xFF263140.toInt()
    private const val TRACK_ON_LIGHT = 0xFFE3E8EE.toInt()

    /** Readings older than this are drawn dimmed: the Mac may be asleep/offline. */
    private const val STALE_AFTER_MS = 3 * 60 * 60 * 1000L
    private const val STALE_ALPHA = 0x66

    /** Kept for callers that only need the default palette. */
    fun colorFor(percent: Double?): Int = Appearance().colorFor(percent)

    fun render(
        usage: Usage?,
        widthPx: Int,
        heightPx: Int,
        density: Float,
        dark: Boolean,
        style: WidgetStyle = WidgetStyle.CARD,
        statusText: String? = null,
        appearance: Appearance = Appearance(),
        nowMs: Long = System.currentTimeMillis(),
    ): Bitmap {
        val w = max(widthPx, 1)
        val h = max(heightPx, 1)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        fun dp(v: Float) = v * density

        val codexAt = usage?.codex?.updatedAtEpochMs ?: usage?.updatedAtEpochMs
        val claudeAt = usage?.claude?.updatedAtEpochMs ?: usage?.updatedAtEpochMs
        val bars = listOf(
            Bar("5h", usage?.codex?.short, codexAt),
            Bar("7d", usage?.codex?.long, codexAt),
            Bar("5h", usage?.claude?.short, claudeAt),
            Bar("7d", usage?.claude?.long, claudeAt),
        )

        if (style == WidgetStyle.ICON) {
            drawIcon(canvas, bars, w, h, density, appearance, nowMs)
            return bmp
        }

        val card = appearance.widgetBackground(dark)
        // Pick text colours from the background itself, not the system mode, so a
        // custom light card in dark mode (or vice versa) stays readable.
        val onDark = Appearance.isDark(card)
        val textColor = if (onDark) TEXT_ON_DARK else TEXT_ON_LIGHT
        val muted = if (onDark) MUTED_ON_DARK else MUTED_ON_LIGHT
        val track = if (onDark) TRACK_ON_DARK else TRACK_ON_LIGHT

        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = card }
        val radius = dp(18f)
        canvas.drawRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), radius, radius, bg)

        // Decide layout richness from available space.
        val compact = h < dp(96f) || w < dp(130f)
        val anyReset = bars.any { it.window?.resetAtEpochMs != null }
        val showReset = !compact && anyReset && h >= dp(112f)
        val showUpdated = !compact && h >= dp(if (showReset) 140f else 120f)

        val pad = dp(if (compact) 10f else 14f)
        val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = muted }

        val top = pad
        var bottom = h - pad

        // Optional footer: "updated Xm ago" (or a setup hint).
        val footer = when {
            showUpdated && usage?.updatedAtEpochMs != null -> TimeFormat.agoText(usage.updatedAtEpochMs)
            statusText != null && !compact -> statusText
            else -> null
        }
        if (footer != null) {
            labelPaint.textSize = dp(10f)
            labelPaint.textAlign = Paint.Align.CENTER
            canvas.drawText(footer, w / 2f, bottom, labelPaint)
            bottom -= dp(14f)
        }

        val pctSize = dp(11f)
        val labelSize = dp(10f)
        val resetSize = dp(9f)
        val pctRow = if (compact) 0f else pctSize + dp(4f)
        val labelRow = if (compact) 0f else labelSize + dp(4f)
        val resetRow = if (showReset) resetSize + dp(3f) else 0f

        val barsTop = top + pctRow
        val barsBottom = bottom - labelRow - resetRow
        val barsHeight = max(barsBottom - barsTop, dp(8f))

        val n = bars.size
        val gap = dp(if (compact) 6f else 9f)
        val innerW = w - 2 * pad
        val barW = (innerW - gap * (n - 1)) / n
        val barRadius = min(barW / 2f, dp(4f))

        val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        val pctPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textSize = pctSize
            textAlign = Paint.Align.CENTER
        }
        val winPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = labelSize
            textAlign = Paint.Align.CENTER
        }
        val resetPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = resetSize
            textAlign = Paint.Align.CENTER
        }

        for (i in 0 until n) {
            val bar = bars[i]
            val left = pad + i * (barW + gap)
            val right = left + barW
            val cx = (left + right) / 2f
            val pct = bar.window?.displayPercent(nowMs)
            val stale = bar.updatedAtMs != null && nowMs - bar.updatedAtMs > STALE_AFTER_MS
            fun dim(c: Int) = if (stale) withAlpha(c, STALE_ALPHA) else c

            trackPaint.color = dim(track)
            canvas.drawRoundRect(RectF(left, barsTop, right, barsBottom), barRadius, barRadius, trackPaint)

            if (pct != null) {
                val frac = (pct / 100.0).coerceIn(0.0, 1.0).toFloat()
                val minVisible = min(barsHeight, dp(4f))
                val fillH = max(barsHeight * frac, if (frac > 0f) minVisible else 0f)
                if (fillH > 0f) {
                    fillPaint.color = dim(appearance.colorFor(pct))
                    canvas.drawRoundRect(
                        RectF(left, barsBottom - fillH, right, barsBottom),
                        barRadius, barRadius, fillPaint,
                    )
                }
            }

            if (!compact) {
                pctPaint.color = dim(appearance.colorFor(pct))
                val pctText = if (pct == null) "–" else "${Math.round(pct)}"
                canvas.drawText(pctText, cx, barsTop - dp(4f), pctPaint)
                winPaint.color = dim(muted)
                val labelY = barsBottom + labelSize + dp(2f)
                canvas.drawText(bar.label, cx, labelY, winPaint)

                if (showReset) {
                    val maxW = barW + gap * 0.8f
                    var text = TimeFormat.shortCountdown(bar.window?.resetAtEpochMs)
                    if (text != null && resetPaint.measureText(text) > maxW) {
                        text = TimeFormat.shortCountdown(bar.window?.resetAtEpochMs, coarse = true)
                    }
                    if (text != null) {
                        resetPaint.color = dim(if (text == "reset") appearance.lowColor else textColor)
                        canvas.drawText(text, cx, labelY + resetSize + dp(3f), resetPaint)
                    }
                }
            }
        }

        return bmp
    }

    /**
     * Draws the four bars inside an app-icon-sized squircle with a label below,
     * transparent everywhere else — so the widget sits in the icon grid like a
     * live version of the launcher icon.
     */
    private fun drawIcon(
        canvas: Canvas,
        bars: List<Bar>,
        w: Int,
        h: Int,
        density: Float,
        appearance: Appearance,
        nowMs: Long,
    ) {
        fun dp(v: Float) = v * density
        val unit = min(w, h).toFloat()
        val side = unit * 0.72f
        val labelReserve = unit * 0.22f
        val left = (w - side) / 2f
        val top = max(unit * 0.04f, (h - labelReserve - side) / 2f)
        val squircleRadius = side * 0.235f

        val iconBg = appearance.iconBackground()
        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = iconBg }
        canvas.drawRoundRect(RectF(left, top, left + side, top + side), squircleRadius, squircleRadius, bgPaint)

        val padIn = side * 0.17f
        val n = bars.size
        val bLeft = left + padIn
        val bTop = top + padIn
        val bRight = left + side - padIn
        val bBottom = top + side - padIn
        val gap = side * 0.06f
        val barW = ((bRight - bLeft) - gap * (n - 1)) / n
        val barRadius = min(barW / 2f, dp(3f))
        val height = bBottom - bTop
        val trackColor = if (Appearance.isDark(iconBg)) TRACK_ON_DARK else TRACK_ON_LIGHT
        val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        for (i in 0 until n) {
            val bar = bars[i]
            val stale = bar.updatedAtMs != null && nowMs - bar.updatedAtMs > STALE_AFTER_MS
            fun dim(c: Int) = if (stale) withAlpha(c, STALE_ALPHA) else c
            val bl = bLeft + i * (barW + gap)
            val br = bl + barW
            trackPaint.color = dim(trackColor)
            canvas.drawRoundRect(RectF(bl, bTop, br, bBottom), barRadius, barRadius, trackPaint)
            val pct = bar.window?.displayPercent(nowMs) ?: continue
            val frac = (pct / 100.0).coerceIn(0.0, 1.0).toFloat()
            val minVisible = min(height, barRadius * 2f)
            val fillH = max(height * frac, if (frac > 0f) minVisible else 0f)
            if (fillH > 0f) {
                fillPaint.color = dim(appearance.colorFor(pct))
                canvas.drawRoundRect(RectF(bl, bBottom - fillH, br, bBottom), barRadius, barRadius, fillPaint)
            }
        }

        // Label below the squircle, styled like a launcher icon label.
        val labelSize = unit * 0.13f
        val labelY = top + side + labelSize + dp(3f)
        if (labelY <= h) {
            val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                textSize = labelSize
                textAlign = Paint.Align.CENTER
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
                setShadowLayer(dp(2f), 0f, dp(1f), 0x99000000.toInt())
            }
            canvas.drawText("AI Usage", w / 2f, labelY, label)
        }
    }

    private fun withAlpha(color: Int, alpha: Int): Int =
        (color and 0x00FFFFFF) or ((alpha * Color.alpha(color) / 255) shl 24)
}
