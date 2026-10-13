package io.github.polymertheory.usagewidget.model

import org.json.JSONObject
import java.time.Instant

/**
 * Mirrors the `SharedUsage` blob that the Mac UsageMeter app publishes to the
 * sync endpoint (see 32-usage_meter Sources/UsageMeterCore/UsageSync.swift and
 * docs/phone.html). Only percentages + reset times are transmitted — never
 * tokens. `percent` is null when a window is unavailable.
 */
data class UsageWindow(
    val label: String,
    val percent: Double?,
    val resetAtEpochMs: Long?,
) {
    /**
     * True once the window's reset time has passed. The blob is only as fresh as
     * the Mac's last publish, so a reading like "Claude 5h 93%" is meaningless
     * after that window has rolled over — usage has restarted from zero.
     */
    fun hasReset(nowMs: Long = System.currentTimeMillis()): Boolean =
        resetAtEpochMs != null && nowMs >= resetAtEpochMs

    /** The percent to display: 0 after a reset we haven't been told about yet. */
    fun displayPercent(nowMs: Long = System.currentTimeMillis()): Double? =
        if (percent != null && hasReset(nowMs)) 0.0 else percent
}

data class UsageProvider(
    val short: UsageWindow,
    val long: UsageWindow,
    val detail: String,
    val source: String,
    val updatedAtEpochMs: Long?,
)

data class Usage(
    val updatedAtEpochMs: Long?,
    val codex: UsageProvider?,
    val claude: UsageProvider?,
) {
    val isEmpty: Boolean get() = codex == null && claude == null

    companion object {
        fun parse(json: String): Usage {
            val root = JSONObject(json)
            val providers = root.optJSONObject("providers")
            return Usage(
                updatedAtEpochMs = root.optIsoDate("updatedAt"),
                codex = providers?.optProvider("codex"),
                claude = providers?.optProvider("claude"),
            )
        }
    }
}

private fun JSONObject.optProvider(key: String): UsageProvider? {
    val p = optJSONObject(key) ?: return null
    val short = p.optJSONObject("short") ?: return null
    val long = p.optJSONObject("long") ?: return null
    return UsageProvider(
        short = short.toWindow(),
        long = long.toWindow(),
        detail = p.optString("detail", ""),
        source = p.optString("source", ""),
        updatedAtEpochMs = p.optIsoDate("updatedAt"),
    )
}

private fun JSONObject.toWindow(): UsageWindow = UsageWindow(
    label = optString("label", ""),
    // A JSON null or missing key both mean "unavailable".
    percent = if (isNull("percent")) null else optDouble("percent").takeIf { !it.isNaN() },
    resetAtEpochMs = optIsoDate("resetAt"),
)

private fun JSONObject.optIsoDate(key: String): Long? {
    if (!has(key) || isNull(key)) return null
    val s = optString(key, "")
    if (s.isEmpty()) return null
    return try {
        Instant.parse(s).toEpochMilli()
    } catch (_: Exception) {
        null
    }
}
