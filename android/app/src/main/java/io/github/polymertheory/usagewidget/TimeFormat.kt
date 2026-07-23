package io.github.polymertheory.usagewidget

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Relative/absolute time strings shared by the widget bitmap and the in-app
 * detail view. Mirrors the Mac app's WindowRow.resetLabel / relativeDate
 * (Sources/UsageMeter/main.swift) so phone and desktop read the same way.
 */
object TimeFormat {
    private val resetTimeFormatter = DateTimeFormatter.ofPattern("H:mm")
    private val resetDayFormatter = DateTimeFormatter.ofPattern("EEE")

    /** "updated just now" / "updated 5m ago" / "updated 3h ago" / "updated 2d ago". */
    fun agoText(epochMs: Long): String {
        val now = System.currentTimeMillis()
        val s = (now - epochMs) / 1000
        return when {
            s < 90 -> "updated just now"
            s < 3600 -> "updated ${Math.round(s / 60.0)}m ago"
            s < 86400 -> "updated ${Math.round(s / 3600.0)}h ago"
            else -> "updated ${Math.round(s / 86400.0)}d ago"
        }
    }

    /** "resets 9:05 (2h 15m)" / "resets Mon 9:05 (3d 2h)" / "resetting…" / "reset unknown". */
    fun resetLabel(resetAtEpochMs: Long?): String {
        if (resetAtEpochMs == null) return "reset unknown"
        val seconds = (resetAtEpochMs - System.currentTimeMillis()) / 1000
        if (seconds <= 0) return "resetting…"

        val totalMinutes = seconds / 60
        val hours = seconds / 3600
        val days = hours / 24
        val countdown = when {
            days >= 1 -> "${days}d ${hours - days * 24}h"
            hours >= 1 -> "${hours}h ${totalMinutes - hours * 60}m"
            else -> "${totalMinutes}m"
        }

        val zone = ZoneId.systemDefault()
        val resetZdt = Instant.ofEpochMilli(resetAtEpochMs).atZone(zone)
        val nowZdt = Instant.now().atZone(zone)
        val timeStr = resetZdt.format(resetTimeFormatter)
        return if (resetZdt.toLocalDate() == nowZdt.toLocalDate()) {
            "resets $timeStr ($countdown)"
        } else {
            "resets ${resetZdt.format(resetDayFormatter)} $timeStr ($countdown)"
        }
    }
}
