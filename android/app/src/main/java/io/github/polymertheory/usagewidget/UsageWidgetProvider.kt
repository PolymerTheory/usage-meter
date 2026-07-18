package io.github.polymertheory.usagewidget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.widget.RemoteViews
import io.github.polymertheory.usagewidget.config.ConfigActivity
import io.github.polymertheory.usagewidget.config.ConfigStore
import io.github.polymertheory.usagewidget.work.RefreshScheduler
import kotlin.math.roundToInt

class UsageWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) renderWidget(context, mgr, id)
        // Repaint from cache immediately, then pull a fresh reading in the background.
        RefreshScheduler.requestNow(context)
        RefreshScheduler.ensurePeriodic(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        mgr: AppWidgetManager,
        id: Int,
        newOptions: Bundle,
    ) {
        renderWidget(context, mgr, id)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) {
            RefreshScheduler.requestNow(context)
        }
    }

    override fun onEnabled(context: Context) {
        RefreshScheduler.ensurePeriodic(context)
    }

    override fun onDisabled(context: Context) {
        RefreshScheduler.cancelPeriodic(context)
    }

    companion object {
        const val ACTION_REFRESH = "io.github.polymertheory.usagewidget.ACTION_REFRESH"

        /** Repaint every placed widget from the cached usage blob. */
        fun updateAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, UsageWidgetProvider::class.java))
            for (id in ids) renderWidget(context, mgr, id)
        }

        private fun renderWidget(context: Context, mgr: AppWidgetManager, id: Int) {
            val density = context.resources.displayMetrics.density
            val opts = mgr.getAppWidgetOptions(id)
            val (wPx, hPx) = widgetSizePx(opts, density)
            val dark = (context.resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

            val config = ConfigStore.load(context)
            val usage = if (config == null) null else UsageRepository.cached(context)
            val status = when {
                config == null -> "Tap to set up"
                usage == null -> "Tap to refresh"
                else -> null
            }

            val style = if (ConfigStore.iconStyle(context)) WidgetStyle.ICON else WidgetStyle.CARD
            val bitmap = WidgetRenderer.render(usage, wPx, hPx, density, dark, style, status)

            val views = RemoteViews(context.packageName, R.layout.widget_usage)
            views.setImageViewBitmap(R.id.widget_image, bitmap)
            views.setOnClickPendingIntent(R.id.widget_image, tapIntent(context))
            mgr.updateAppWidget(id, views)
        }

        /** Tap opens the app (which shows the detailed view and refreshes). */
        private fun tapIntent(context: Context): PendingIntent {
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val intent = Intent(context, ConfigActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            return PendingIntent.getActivity(context, 1, intent, flags)
        }

        private fun widgetSizePx(opts: Bundle, density: Float): Pair<Int, Int> {
            // Portrait width + portrait height give the most reliable cell size.
            val minWDp = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
            val maxHDp = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
            val wDp = if (minWDp > 0) minWDp else 110
            val hDp = if (maxHDp > 0) maxHDp else 40
            val w = (wDp * density).roundToInt().coerceIn(40, 720)
            val h = (hDp * density).roundToInt().coerceIn(40, 480)
            return w to h
        }
    }
}
