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
)

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
