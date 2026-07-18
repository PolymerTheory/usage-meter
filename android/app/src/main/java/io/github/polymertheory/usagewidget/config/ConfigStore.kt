package io.github.polymertheory.usagewidget.config

import android.content.Context
import java.net.URLDecoder

/** The sync endpoint URL + bearer token, persisted in app-private prefs. */
data class SyncConfig(val url: String, val token: String) {
    val isValid: Boolean get() = url.startsWith("http")
}

object ConfigStore {
    private const val PREFS = "usage_widget_prefs"
    private const val KEY_URL = "sync_url"
    private const val KEY_TOKEN = "sync_token"
    private const val KEY_ICON_STYLE = "icon_style"

    fun load(context: Context): SyncConfig? {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val url = p.getString(KEY_URL, null) ?: return null
        val token = p.getString(KEY_TOKEN, "") ?: ""
        val cfg = SyncConfig(url, token)
        return if (cfg.isValid) cfg else null
    }

    fun save(context: Context, config: SyncConfig) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_URL, config.url)
            .putString(KEY_TOKEN, config.token)
            .apply()
    }

    /** true = compact app-icon style, false = detailed card. */
    fun iconStyle(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ICON_STYLE, false)

    fun setIconStyle(context: Context, iconStyle: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_ICON_STYLE, iconStyle)
            .apply()
    }

    /**
     * Parses a UsageMeter pairing link of the form
     * `https://…/phone.html#u=<url-encoded sync url>&t=<url-encoded token>`
     * — the same fragment format docs/phone.html reads. Returns null if the
     * fragment has no `u` value.
     */
    fun fromPairingLink(link: String): SyncConfig? {
        val hash = link.trim().indexOf('#')
        if (hash < 0) return null
        val fragment = link.trim().substring(hash + 1)
        if (fragment.isEmpty()) return null
        var url: String? = null
        var token = ""
        for (pair in fragment.split("&")) {
            val i = pair.indexOf('=')
            if (i < 0) continue
            val k = pair.substring(0, i)
            val v = decode(pair.substring(i + 1))
            when (k) {
                "u" -> url = v
                "t" -> token = v
            }
        }
        val u = url ?: return null
        return SyncConfig(u, token).takeIf { it.isValid }
    }

    private fun decode(s: String): String = try {
        URLDecoder.decode(s, "UTF-8")
    } catch (_: Exception) {
        s
    }
}
