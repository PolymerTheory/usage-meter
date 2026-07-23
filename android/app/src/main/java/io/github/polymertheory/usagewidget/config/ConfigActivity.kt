package io.github.polymertheory.usagewidget.config

import android.appwidget.AppWidgetManager
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import io.github.polymertheory.usagewidget.FetchResult
import io.github.polymertheory.usagewidget.R
import io.github.polymertheory.usagewidget.UsageDetailRenderer
import io.github.polymertheory.usagewidget.UsageRepository
import io.github.polymertheory.usagewidget.UsageWidgetProvider
import io.github.polymertheory.usagewidget.databinding.ActivityConfigBinding
import io.github.polymertheory.usagewidget.model.Usage
import io.github.polymertheory.usagewidget.work.RefreshScheduler
import kotlinx.coroutines.launch

/**
 * Setup screen: scan the UsageMeter QR (easiest) or paste the sync URL + token.
 * Also serves as the widget's placement-time configuration activity.
 */
class ConfigActivity : AppCompatActivity() {

    private lateinit var binding: ActivityConfigBinding
    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    private val scan = registerForActivityResult(ScanContract()) { result ->
        val contents = result.contents ?: return@registerForActivityResult
        val cfg = ConfigStore.fromPairingLink(contents)
        if (cfg != null) {
            binding.urlField.setText(cfg.url)
            binding.tokenField.setText(cfg.token)
            binding.linkField.setText("")
            testConnection(cfg)
        } else {
            binding.status.text = "That QR isn’t a UsageMeter pairing code."
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityConfigBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // targetSdk 35 draws edge-to-edge; pad the scroll view clear of the
        // status and navigation bars so nothing is hidden behind them.
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            v.setPadding(v.paddingLeft, bars.top, v.paddingRight, bars.bottom)
            insets
        }

        appWidgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID
        // If the user backs out of widget placement, leave the widget uncreated.
        if (appWidgetId != AppWidgetManager.INVALID_APPWIDGET_ID) setResult(RESULT_CANCELED)

        ConfigStore.load(this)?.let {
            binding.urlField.setText(it.url)
            binding.tokenField.setText(it.token)
            binding.status.text = getString(R.string.saved)
        }

        binding.scanButton.setOnClickListener {
            scan.launch(
                ScanOptions()
                    .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                    .setPrompt(getString(R.string.scan_prompt))
                    .setBeepEnabled(false)
                    .setOrientationLocked(false),
            )
        }
        binding.testButton.setOnClickListener { currentConfig()?.let(::testConnection) }
        binding.saveButton.setOnClickListener { save() }

        binding.iconStyleSwitch.isChecked = ConfigStore.iconStyle(this)
        binding.iconStyleSwitch.setOnCheckedChangeListener { _, checked ->
            // Only affects the home-screen widget; the in-app view stays detailed.
            ConfigStore.setIconStyle(this, checked)
            UsageWidgetProvider.updateAll(this)
        }

        renderUsage()
    }

    override fun onResume() {
        super.onResume()
        // Refresh whenever the app is opened (e.g. by tapping the widget).
        val cfg = ConfigStore.load(this) ?: return
        lifecycleScope.launch {
            when (val r = UsageRepository.fetch(this@ConfigActivity, cfg)) {
                is FetchResult.Ok -> {
                    renderUsage(r.usage)
                    UsageWidgetProvider.updateAll(this@ConfigActivity)
                }
                is FetchResult.Error -> { /* keep showing cached usage */ }
            }
        }
    }

    /** Config from the manual fields, or from a pasted pairing link if present. */
    private fun currentConfig(): SyncConfig? {
        val link = binding.linkField.text?.toString()?.trim().orEmpty()
        if (link.isNotEmpty()) {
            val parsed = ConfigStore.fromPairingLink(link)
            if (parsed != null) return parsed
            binding.status.text = "Couldn’t read that link."
            return null
        }
        val url = binding.urlField.text?.toString()?.trim().orEmpty()
        val token = binding.tokenField.text?.toString()?.trim().orEmpty()
        val cfg = SyncConfig(url, token)
        if (!cfg.isValid) {
            binding.status.text = getString(R.string.not_configured)
            return null
        }
        return cfg
    }

    private fun testConnection(cfg: SyncConfig) {
        binding.status.text = getString(R.string.testing)
        lifecycleScope.launch {
            when (val r = UsageRepository.fetch(this@ConfigActivity, cfg)) {
                is FetchResult.Ok -> {
                    binding.status.text = if (r.usage.isEmpty) {
                        "✓ Connected, but nothing published yet — keep a Mac with sync running."
                    } else {
                        getString(R.string.connected)
                    }
                    renderUsage(r.usage)
                }
                is FetchResult.Error -> binding.status.text = "✕ ${r.message}"
            }
        }
    }

    private fun save() {
        val cfg = currentConfig() ?: return
        ConfigStore.save(this, cfg)
        binding.status.text = getString(R.string.saved)
        RefreshScheduler.ensurePeriodic(this)
        RefreshScheduler.requestNow(this)
        UsageWidgetProvider.updateAll(this)

        if (appWidgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
            val result = android.content.Intent()
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            setResult(RESULT_OK, result)
            finish()
        }
    }

    private fun renderUsage(usage: Usage? = UsageRepository.cached(this)) {
        UsageDetailRenderer.bind(binding.codexCard, "Codex", usage?.codex)
        UsageDetailRenderer.bind(binding.claudeCard, "Claude", usage?.claude)
    }
}
