package io.github.polymertheory.usagewidget

import io.github.polymertheory.usagewidget.config.Appearance
import io.github.polymertheory.usagewidget.databinding.ViewProviderCardBinding
import io.github.polymertheory.usagewidget.databinding.ViewUsageWindowRowBinding
import io.github.polymertheory.usagewidget.model.UsageProvider
import io.github.polymertheory.usagewidget.model.UsageWindow
import kotlin.math.roundToInt

/**
 * Fills the Codex/Claude provider cards on the in-app detail screen — same
 * fields, in the same order, as the Mac app's ProviderView/WindowRow
 * (Sources/UsageMeter/main.swift): bars, percentages, reset countdowns, and
 * a last-updated footer. Colours/thresholds come from the user's [Appearance].
 */
object UsageDetailRenderer {

    fun bind(
        binding: ViewProviderCardBinding,
        name: String,
        provider: UsageProvider?,
        appearance: Appearance = Appearance(),
    ) {
        binding.name.text = name
        binding.source.text = provider?.source.orEmpty()

        bindWindow(binding.shortRow, provider?.short, fallbackLabel = "5h", appearance)
        bindWindow(binding.longRow, provider?.long, fallbackLabel = "7d", appearance)

        binding.detail.text = provider?.detail?.takeIf { it.isNotBlank() } ?: "No data yet"
        binding.updated.text = provider?.updatedAtEpochMs?.let { TimeFormat.agoText(it) }.orEmpty()
    }

    private fun bindWindow(
        binding: ViewUsageWindowRowBinding,
        window: UsageWindow?,
        fallbackLabel: String,
        appearance: Appearance,
    ) {
        binding.label.text = window?.label?.takeIf { it.isNotBlank() } ?: fallbackLabel

        // After the reset time passes, show 0 rather than the pre-reset reading.
        val pct = window?.displayPercent()
        val color = appearance.colorFor(pct)
        binding.bar.setIndicatorColor(color)
        binding.bar.progress = (pct ?: 0.0).coerceIn(0.0, 100.0).roundToInt()
        binding.percent.text = if (pct == null) "–" else "${pct.roundToInt()}%"
        binding.percent.setTextColor(color)
        binding.reset.text = TimeFormat.resetLabel(window?.resetAtEpochMs)
    }
}
