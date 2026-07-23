package io.github.polymertheory.usagewidget

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
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
 * Colours and thresholds match docs/phone.html so the phone matches the Mac.
 *   green < 55%, yellow < 80%, red >= 80%, grey = unavailable.
 * Small cells show bars only (icon-like); larger cells add percentages,
 * window labels, and an "updated" line.
 */
object WidgetRenderer {

    private data class Bar(val group: String, val label: String, val window: UsageWindow?)

    private const val CARD_DARK = 0xFF151B23.toInt()
    private const val CARD_LIGHT = 0xFFFFFFFF.toInt()
    private const val TEXT_DARK = 0xFFE7EDF3.toInt()
    private const val TEXT_LIGHT = 0xFF1A2230.toInt()
    private const val MUTED_DARK = 0xFF8B97A5.toInt()
    private const val MUTED_LIGHT = 0xFF66707D.toInt()
    private const val TRACK_DARK = 0xFF263140.toInt()
    private const val TRACK_LIGHT = 0xFFE3E8EE.toInt()

    private const val GREEN = 0xFF34C759.toInt()
    private const val YELLOW = 0xFFFFCC00.toInt()
    private const val RED = 0xFFFF3B30.toInt()
    private const val GRAY = 0xFF5B6673.toInt()

    fun colorFor(percent: Double?): Int = when {
        percent == null -> GRAY
        percent < 55 -> GREEN
        percent < 80 -> YELLOW
        else -> RED
    }

    fun render(
        usage: Usage?,
        widthPx: Int,
        heightPx: Int,
        density: Float,
        dark: Boolean,
        style: WidgetStyle = WidgetStyle.CARD,
        statusText: String? = null,
    ): Bitmap {
        val w = max(widthPx, 1)
        val h = max(heightPx, 1)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        fun dp(v: Float) = v * density

        val bars = listOf(
            Bar("Codex", "5h", usage?.codex?.short),
            Bar("Codex", "7d", usage?.codex?.long),
            Bar("Claude", "5h", usage?.claude?.short),
            Bar("Claude", "7d", usage?.claude?.long),
        )

        if (style == WidgetStyle.ICON) {
            drawIcon(canvas, bars, w, h, density)
            return bmp
        }

        val card = if (dark) CARD_DARK else CARD_LIGHT
        val textColor = if (dark) TEXT_DARK else TEXT_LIGHT
        val muted = if (dark) MUTED_DARK else MUTED_LIGHT
        val track = if (dark) TRACK_DARK else TRACK_LIGHT

        // Rounded card background.
        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = card }
        val radius = dp(18f)
        canvas.drawRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), radius, radius, bg)

        // Decide layout richness from available space.
        val compact = h < dp(96f) || w < dp(130f)
        val showUpdated = !compact && h >= dp(120f)

        val pad = dp(if (compact) 10f else 14f)
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = textColor
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = muted }

        var top = pad
        var bottom = h - pad

        // Optional footer: "updated Xm ago".
        if (showUpdated && usage?.updatedAtEpochMs != null) {
            labelPaint.textSize = dp(10f)
            labelPaint.textAlign = Paint.Align.CENTER
            val ago = TimeFormat.agoText(usage.updatedAtEpochMs)
            canvas.drawText(ago, w / 2f, bottom, labelPaint)
            bottom -= dp(14f)
        } else if (statusText != null && !compact) {
            labelPaint.textSize = dp(10f)
            labelPaint.textAlign = Paint.Align.CENTER
            canvas.drawText(statusText, w / 2f, bottom, labelPaint)
            bottom -= dp(14f)
        }

        // Percentage row above bars (expanded only).
        val pctSize = dp(11f)
        val labelSize = dp(10f)
        val pctRow = if (compact) 0f else pctSize + dp(4f)
        val labelRow = if (compact) 0f else labelSize + dp(4f)

        val barsTop = top + pctRow
        val barsBottom = bottom - labelRow
        val barsHeight = max(barsBottom - barsTop, dp(8f))

        // Bar geometry: four bars evenly spaced across the width.
        val n = bars.size
        val gap = dp(if (compact) 6f else 9f)
        val innerW = w - 2 * pad
        val barW = (innerW - gap * (n - 1)) / n
        val barRadius = min(barW / 2f, dp(4f))

        val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = track }
        val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        val pctPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textSize = pctSize
            textAlign = Paint.Align.CENTER
        }
        val winPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = muted
            textSize = labelSize
            textAlign = Paint.Align.CENTER
        }

        for (i in 0 until n) {
            val bar = bars[i]
            val left = pad + i * (barW + gap)
            val right = left + barW
            val cx = (left + right) / 2f
            val pct = bar.window?.percent

            // Track (full height, rounded).
            canvas.drawRoundRect(RectF(left, barsTop, right, barsBottom), barRadius, barRadius, trackPaint)

            // Fill from the bottom up.
            if (pct != null) {
                val frac = (pct / 100.0).coerceIn(0.0, 1.0).toFloat()
                val minVisible = min(barsHeight, dp(4f))
                val fillH = max(barsHeight * frac, if (frac > 0f) minVisible else 0f)
                if (fillH > 0f) {
                    fillPaint.color = colorFor(pct)
                    canvas.drawRoundRect(
                        RectF(left, barsBottom - fillH, right, barsBottom),
                        barRadius, barRadius, fillPaint,
                    )
                }
            }

            if (!compact) {
                pctPaint.color = colorFor(pct)
                val pctText = if (pct == null) "–" else "${Math.round(pct)}"
                canvas.drawText(pctText, cx, barsTop - dp(4f), pctPaint)
                canvas.drawText(bar.label, cx, barsBottom + labelSize + dp(2f), winPaint)
            }
        }

        return bmp
    }

    /**
     * Draws the four bars inside an app-icon-sized dark squircle with a label
     * below, transparent everywhere else — so the widget sits in the icon grid
     * like a live version of the launcher icon.
     */
    private fun drawIcon(canvas: Canvas, bars: List<Bar>, w: Int, h: Int, density: Float) {
        fun dp(v: Float) = v * density
        val unit = min(w, h).toFloat()
        // Match a launcher icon: ~72% of the cell, sitting in the upper area with
        // its label beneath, so the widget lines up with adjacent app icons.
        val side = unit * 0.72f
        val labelReserve = unit * 0.22f
        val left = (w - side) / 2f
        val top = max(unit * 0.04f, (h - labelReserve - side) / 2f)
        val squircleRadius = side * 0.235f

        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF0B0F14.toInt() }
        canvas.drawRoundRect(RectF(left, top, left + side, top + side), squircleRadius, squircleRadius, bgPaint)

        val padIn = side * 0.17f
        drawBars(
            canvas, bars,
            left = left + padIn,
            top = top + padIn,
            right = left + side - padIn,
            bottom = top + side - padIn,
            gap = side * 0.06f,
            maxRadius = dp(3f),
            trackColor = TRACK_DARK,
        )

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

    /** Draws n track+fill bars filling the given rect. No text. */
    private fun drawBars(
        canvas: Canvas,
        bars: List<Bar>,
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        gap: Float,
        maxRadius: Float,
        trackColor: Int,
    ) {
        val n = bars.size
        val innerW = right - left
        val barW = (innerW - gap * (n - 1)) / n
        val barRadius = min(barW / 2f, maxRadius)
        val height = bottom - top
        val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = trackColor }
        val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        for (i in 0 until n) {
            val bl = left + i * (barW + gap)
            val br = bl + barW
            canvas.drawRoundRect(RectF(bl, top, br, bottom), barRadius, barRadius, trackPaint)
            val pct = bars[i].window?.percent ?: continue
            val frac = (pct / 100.0).coerceIn(0.0, 1.0).toFloat()
            val minVisible = min(height, barRadius * 2f)
            val fillH = max(height * frac, if (frac > 0f) minVisible else 0f)
            if (fillH > 0f) {
                fillPaint.color = colorFor(pct)
                canvas.drawRoundRect(RectF(bl, bottom - fillH, br, bottom), barRadius, barRadius, fillPaint)
            }
        }
    }

}
