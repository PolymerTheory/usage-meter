package io.github.polymertheory.usagewidget

import android.content.Context
import io.github.polymertheory.usagewidget.config.ConfigStore
import io.github.polymertheory.usagewidget.config.SyncConfig
import io.github.polymertheory.usagewidget.model.Usage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

sealed class FetchResult {
    data class Ok(val usage: Usage) : FetchResult()
    data class Error(val message: String) : FetchResult()
}

/**
 * Reads the published usage blob from the user's sync endpoint. This is the
 * only network call the app makes — a GET with `Authorization: Bearer <token>`,
 * exactly like docs/phone.html. The last good blob is cached to disk so the
 * widget can still draw while offline or between refreshes.
 */
object UsageRepository {
    private const val CACHE_FILE = "last_usage.json"
    private const val TIMEOUT_MS = 12_000

    /** Fetches and parses fresh usage. On success also refreshes the disk cache. */
    suspend fun fetch(context: Context, config: SyncConfig): FetchResult =
        withContext(Dispatchers.IO) {
            var conn: HttpURLConnection? = null
            try {
                conn = (URL(config.url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    setRequestProperty("Accept", "application/json")
                    if (config.token.isNotEmpty()) {
                        setRequestProperty("Authorization", "Bearer ${config.token}")
                    }
                }
                val code = conn.responseCode
                if (code == 401 || code == 403) {
                    return@withContext FetchResult.Error("token rejected ($code)")
                }
                if (code !in 200..299) {
                    return@withContext FetchResult.Error("HTTP $code")
                }
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                val usage = Usage.parse(body)
                if (!usage.isEmpty) writeCache(context, body)
                FetchResult.Ok(usage)
            } catch (e: Exception) {
                FetchResult.Error(e.message ?: e.javaClass.simpleName)
            } finally {
                conn?.disconnect()
            }
        }

    /** Convenience: load config from prefs then fetch. */
    suspend fun fetch(context: Context): FetchResult {
        val cfg = ConfigStore.load(context)
            ?: return FetchResult.Error("not configured")
        return fetch(context, cfg)
    }

    /** Last successfully fetched usage, or null if none cached yet. */
    fun cached(context: Context): Usage? = try {
        val f = cacheFile(context)
        if (f.exists()) Usage.parse(f.readText()) else null
    } catch (_: Exception) {
        null
    }

    private fun writeCache(context: Context, body: String) {
        try {
            cacheFile(context).writeText(body)
        } catch (_: Exception) {
            // Cache is best-effort.
        }
    }

    private fun cacheFile(context: Context) = File(context.filesDir, CACHE_FILE)
}
