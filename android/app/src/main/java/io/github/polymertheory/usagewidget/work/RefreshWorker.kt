package io.github.polymertheory.usagewidget.work

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.github.polymertheory.usagewidget.FetchResult
import io.github.polymertheory.usagewidget.UsageRepository
import io.github.polymertheory.usagewidget.UsageWidgetProvider
import java.util.concurrent.TimeUnit

/** Fetches fresh usage and repaints every widget. */
class RefreshWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val result = UsageRepository.fetch(applicationContext)
        // Always repaint — on success with fresh data, on failure with the last
        // cached blob so the widget never goes blank.
        UsageWidgetProvider.updateAll(applicationContext)
        return when (result) {
            is FetchResult.Ok -> Result.success()
            is FetchResult.Error -> Result.retry()
        }
    }
}

object RefreshScheduler {
    private const val PERIODIC = "usage_refresh_periodic"
    private const val ONE_SHOT = "usage_refresh_now"

    /** Immediate one-off refresh (e.g. widget tap or placement). */
    fun requestNow(context: Context) {
        val work = OneTimeWorkRequestBuilder<RefreshWorker>()
            .setConstraints(networkConstraint())
            .build()
        WorkManager.getInstance(context)
            .enqueueUniqueWork(ONE_SHOT, ExistingWorkPolicy.REPLACE, work)
    }

    /** Background freshness. 15 min is WorkManager's minimum period. */
    fun ensurePeriodic(context: Context) {
        val work = PeriodicWorkRequestBuilder<RefreshWorker>(15, TimeUnit.MINUTES)
            .setConstraints(networkConstraint())
            .build()
        WorkManager.getInstance(context)
            .enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, work)
    }

    fun cancelPeriodic(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(PERIODIC)
    }

    private fun networkConstraint() = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()
}
