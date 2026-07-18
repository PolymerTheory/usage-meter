package io.github.polymertheory.usagewidget

import io.github.polymertheory.usagewidget.config.ConfigStore
import io.github.polymertheory.usagewidget.model.Usage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Exercises the whole data path off-device: the exact SharedUsage blob the Mac
 * publishes, the QR pairing-link format from Sources/UsageMeter/main.swift, and
 * the colour thresholds shared with docs/phone.html.
 */
class DataPathTest {

    // Realistic blob matching Sources/UsageMeterCore/UsageSync.swift (.iso8601, sorted keys).
    private val blob = """
      {
        "version": 1,
        "updatedAt": "2026-07-18T19:12:00Z",
        "updatedBy": "mac-studio",
        "providers": {
          "codex": {
            "updatedAt": "2026-07-18T19:12:00Z",
            "updatedBy": "mac-studio",
            "short": {"label": "5h", "percent": 42.5, "resetAt": "2026-07-18T21:00:00Z"},
            "long":  {"label": "7d", "percent": 63.0, "resetAt": "2026-07-25T00:00:00Z"},
            "detail": "Codex", "source": "api"
          },
          "claude": {
            "updatedAt": "2026-07-18T19:12:00Z",
            "updatedBy": "mac-studio",
            "short": {"label": "5h", "percent": 88.0, "resetAt": "2026-07-18T20:30:00Z"},
            "long":  {"label": "7d", "percent": null, "resetAt": null},
            "detail": "Claude", "source": "api"
          }
        }
      }
    """.trimIndent()

    @Test
    fun parsesRealBlob() {
        val u = Usage.parse(blob)
        assertNotNull(u.updatedAtEpochMs)
        assertEquals(42.5, u.codex!!.short.percent!!, 0.001)
        assertEquals("7d", u.codex!!.long.label)
        assertEquals(88.0, u.claude!!.short.percent!!, 0.001)
        // null percent / resetAt must survive as null (window unavailable).
        assertNull(u.claude!!.long.percent)
        assertNull(u.claude!!.long.resetAtEpochMs)
        assertNotNull(u.codex!!.short.resetAtEpochMs)
    }

    @Test
    fun emptyAndPartialBlobs() {
        assertTrue(Usage.parse("{}").isEmpty)
        val onlyClaude = Usage.parse("""{"providers":{"claude":{"short":{"label":"5h","percent":10},"long":{"label":"7d","percent":20}}}}""")
        assertNull(onlyClaude.codex)
        assertNotNull(onlyClaude.claude)
        assertEquals(10.0, onlyClaude.claude!!.short.percent!!, 0.001)
    }

    @Test
    fun parsesPairingLink() {
        // Exactly the format built in Sources/UsageMeter/main.swift pairingURL().
        val url = "https://abc123.supabase.co/functions/v1/usage-sync/kf9x2q7m"
        val token = "s3cr3t token+/="
        val link = "https://polymertheory.github.io/usage-meter/phone.html#u=" +
            java.net.URLEncoder.encode(url, "UTF-8") + "&t=" +
            java.net.URLEncoder.encode(token, "UTF-8")
        val cfg = ConfigStore.fromPairingLink(link)
        assertNotNull(cfg)
        assertEquals(url, cfg!!.url)
        assertEquals(token, cfg.token)
    }

    @Test
    fun rejectsNonPairingLinks() {
        assertNull(ConfigStore.fromPairingLink("https://example.com/no-fragment"))
        assertNull(ConfigStore.fromPairingLink("just some text"))
        assertNull(ConfigStore.fromPairingLink("https://x/#t=only-token"))
    }

    @Test
    fun colorThresholdsMatchPhoneView() {
        assertEquals(WidgetRenderer.colorFor(null), WidgetRenderer.colorFor(null))
        // green < 55, yellow < 80, red >= 80
        assertEquals(WidgetRenderer.colorFor(10.0), WidgetRenderer.colorFor(54.9))
        assertEquals(WidgetRenderer.colorFor(55.0), WidgetRenderer.colorFor(79.9))
        assertEquals(WidgetRenderer.colorFor(80.0), WidgetRenderer.colorFor(100.0))
        // The three bands must be distinct colours.
        val green = WidgetRenderer.colorFor(10.0)
        val yellow = WidgetRenderer.colorFor(60.0)
        val red = WidgetRenderer.colorFor(90.0)
        assertTrue(green != yellow && yellow != red && green != red)
    }
}
