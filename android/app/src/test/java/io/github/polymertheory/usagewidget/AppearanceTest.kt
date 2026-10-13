package io.github.polymertheory.usagewidget

import io.github.polymertheory.usagewidget.config.Appearance
import io.github.polymertheory.usagewidget.config.AppearanceSettings
import io.github.polymertheory.usagewidget.model.UsageWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppearanceTest {

    @Test fun defaultThresholdsMatchMacApp() {
        val a = Appearance()
        assertEquals(a.lowColor, a.colorFor(54.9))
        assertEquals(a.midColor, a.colorFor(55.0))   // boundary is medium
        assertEquals(a.midColor, a.colorFor(79.9))
        assertEquals(a.highColor, a.colorFor(80.0))  // boundary is high
        assertEquals(Appearance.UNAVAILABLE, a.colorFor(null))
    }

    @Test fun customThresholdsAndColorsApply() {
        val a = Appearance(lowColor = 1, midColor = 2, highColor = 3, midThreshold = 30, highThreshold = 90)
        assertEquals(1, a.colorFor(29.0))
        assertEquals(2, a.colorFor(30.0))
        assertEquals(3, a.colorFor(95.0))
    }

    @Test fun thresholdsAreClampedAndOrdered() {
        assertEquals(1 to 2, Appearance.clampThresholds(0, 0))
        assertEquals(98 to 99, Appearance.clampThresholds(150, 10))
        assertEquals(40 to 41, Appearance.clampThresholds(40, 40))
    }

    @Test fun hexParsing() {
        assertEquals(0xFF34C759.toInt(), AppearanceSettings.parseHex("#34c759"))
        assertEquals(0xFF000000.toInt(), AppearanceSettings.parseHex("000000"))
        assertNull(AppearanceSettings.parseHex("#12345"))
        assertNull(AppearanceSettings.parseHex("zzzzzz"))
        assertEquals("#34C759", AppearanceSettings.toHex(0xFF34C759.toInt()))
    }

    @Test fun backgroundLuminance() {
        assertTrue(Appearance.isDark(Appearance.DEFAULT_CARD_DARK))
        assertFalse(Appearance.isDark(Appearance.DEFAULT_CARD_LIGHT))
    }

    @Test fun windowPastResetShowsZero() {
        val now = 1_000_000L
        val stale = UsageWindow("5h", 93.0, resetAtEpochMs = now - 1)
        assertTrue(stale.hasReset(now))
        assertEquals(0.0, stale.displayPercent(now)!!, 0.0)

        val live = UsageWindow("5h", 93.0, resetAtEpochMs = now + 60_000)
        assertFalse(live.hasReset(now))
        assertEquals(93.0, live.displayPercent(now)!!, 0.0)

        // Unavailable stays unavailable; unknown reset never flips to zero.
        assertNull(UsageWindow("5h", null, now - 1).displayPercent(now))
        assertEquals(50.0, UsageWindow("7d", 50.0, null).displayPercent(now)!!, 0.0)
    }

    @Test fun shortCountdownFormats() {
        val now = System.currentTimeMillis()
        assertNull(TimeFormat.shortCountdown(null))
        assertEquals("reset", TimeFormat.shortCountdown(now - 1000))
        assertEquals("45m", TimeFormat.shortCountdown(now + 45 * 60_000 + 30_000))
        assertEquals("3h12m", TimeFormat.shortCountdown(now + (3 * 60 + 12) * 60_000L + 30_000))
        assertEquals("3h", TimeFormat.shortCountdown(now + (3 * 60 + 12) * 60_000L + 30_000, coarse = true))
        assertEquals("2d4h", TimeFormat.shortCountdown(now + (52 * 60) * 60_000L + 30_000))
    }
}
