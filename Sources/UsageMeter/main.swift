import AppKit
import CoreImage
import Sparkle
import SwiftUI
import UsageMeterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = UsageViewModel()
    // Created in applicationDidFinishLaunching, after the one-time preference
    // migration, so Sparkle reads a clean opt-out default.
    private var updaterController: SPUStandardUpdaterController!
    /// Global mouse-down monitor installed while the popover is open so that
    /// clicking anywhere outside it dismisses it. (.transient behavior is
    /// unreliable for accessory-policy apps that never become the active app.)
    private var outsideClickMonitor: Any?
    /// Held for the app's lifetime to opt out of App Nap. Without it, macOS
    /// suspends the refresh timers when the app is idle and unfocused, freezing
    /// the displayed usage at a stale snapshot until the user interacts again.
    /// We allow idle system sleep so the Mac can still sleep normally.
    private var activityToken: NSObjectProtocol?
    /// Signature of the last icon we drew, so the 1-second activity timer does
    /// not re-render the menu-bar image when nothing visible has changed.
    private var lastRenderSignature: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchDiagnostics.write("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep AI usage meter current"
        )

        // Auto-update is opt-in. Build 0.2.11 briefly forced it and persisted
        // SUAutomaticallyUpdate=1; clear that once so the opt-out default applies.
        // Runs before the updater is created so Sparkle reads clean settings.
        // A later opt-in the user makes via the toggle is preserved.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "autoUpdateOptInMigration") {
            defaults.removeObject(forKey: "SUAutomaticallyUpdate")
            defaults.removeObject(forKey: "SUEnableAutomaticChecks")
            defaults.set(true, forKey: "autoUpdateOptInMigration")
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton(with: .empty)

        popover.behavior = .applicationDefined   // we manage dismissal manually
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 430)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(
                model: model,
                checkForUpdates: { [weak self] in
                    self?.updaterController.checkForUpdates(nil)
                },
                autoUpdate: Binding(
                    get: { [weak self] in
                        self?.updaterController.updater.automaticallyDownloadsUpdates ?? false
                    },
                    set: { [weak self] on in
                        // Downloading requires checking, so enable/disable both together.
                        self?.updaterController.updater.automaticallyChecksForUpdates = on
                        self?.updaterController.updater.automaticallyDownloadsUpdates = on
                    }
                )
            )
        )

        model.onSnapshot = { [weak self] snapshot in
            self?.configureStatusButton(with: snapshot)
        }
        model.refreshQuota()

        // Poll quota every 2 minutes. The Claude reader additionally throttles
        // its own live calls (see ClaudeAPIUsageReader.minLiveInterval) so this
        // cadence — plus popover-open refreshes — can't burst-hit that API.
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshQuota()
            }
        }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshActivity()
            }
        }
    }

    private func configureStatusButton(with snapshot: UsageSnapshot) {
        guard let button = statusItem.button else {
            LaunchDiagnostics.write("status item has no button")
            return
        }

        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "UsageMeter: Codex and Claude quota"
        statusItem.length = 28

        // Only re-render the icon (and log) when the visible state changes.
        // The 1-second activity timer calls this constantly; rebuilding the
        // NSImage and writing a log line every tick wastes CPU and floods the
        // diagnostics log.
        let signature = Self.renderSignature(for: snapshot)
        guard signature != lastRenderSignature else { return }
        lastRenderSignature = signature

        button.image = MeterIconRenderer.image(snapshot: snapshot)
        let activeProviders = snapshot.providers
            .filter(\.isActive)
            .map { $0.provider.rawValue }
            .joined(separator: ",")
        LaunchDiagnostics.write(
            "configured status button active=\(activeProviders) signature=\(signature)"
        )
    }

    /// Compact description of everything the menu-bar icon depends on:
    /// each window's integer percent (or "x" when unavailable) and the
    /// per-provider active flag.
    private static func renderSignature(for snapshot: UsageSnapshot) -> String {
        snapshot.providers.map { provider in
            func part(_ window: UsageWindow) -> String {
                window.unitName == "unavailable" ? "x" : String(Int(window.fractionUsed * 100))
            }
            return "\(provider.provider.rawValue):\(part(provider.shortWindow)):\(part(provider.longWindow)):\(provider.isActive)"
        }.joined(separator: "|")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            closePopover()
        } else {
            model.refreshQuota()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Delivered on the main thread; close only if still shown.
            guard let self, self.popover.isShown else { return }
            self.closePopover()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // NSPopoverDelegate: clean up the monitor if the popover closes for any
    // other reason (e.g. Escape key, programmatic close).
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.removeOutsideClickMonitor() }
    }
}

enum LaunchDiagnostics {
    static func write(_ message: String) {
        let url = URL(fileURLWithPath: "/tmp/UsageMeter-launch.log")
        let line = "\(Date()) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

@main
enum UsageMeterMain {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        if handleCommandLineMode() {
            return
        }
        // If we weren't launched by our own LaunchAgent (e.g. first run after a
        // manual download or a Sparkle update relaunch), make sure the agent is
        // installed and let launchd own the process, then exit. launchd will
        // start the managed instance, which keeps the app alive across crashes
        // and logins on any machine — not just where the install script ran.
        // Only do this for a real installed bundle so a dev build run from a
        // checkout/dist directory doesn't hijack the managed LaunchAgent.
        if !LaunchAgentInstaller.isManagedInstance(),
           let executablePath = Bundle.main.executablePath,
           LaunchAgentInstaller.isInstalledLocation(executablePath) {
            LaunchAgentInstaller.ensureRunning(executablePath: executablePath)
            return
        }
        if !acquireSingleInstanceLock() {
            return
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func handleCommandLineMode() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 4, arguments[0] == "--activity-hook", arguments[1] == "claude" {
            try? ActivityStatusWriter.write(
                provider: .claude,
                state: arguments[2],
                event: arguments[3]
            )
            return true
        }

        if arguments == ["--install-claude-hooks"], let executablePath = Bundle.main.executablePath {
            do {
                try ClaudeHookInstaller.install(executablePath: executablePath)
                print("Claude activity hooks installed")
            } catch {
                fputs("Failed to install Claude activity hooks: \(error)\n", stderr)
            }
            return true
        }

        if arguments == ["--install-launch-agent"], let executablePath = Bundle.main.executablePath {
            do {
                try LaunchAgentInstaller.install(executablePath: executablePath)
                print("LaunchAgent installed; UsageMeter will run at login and auto-restart")
            } catch {
                fputs("Failed to install LaunchAgent: \(error)\n", stderr)
            }
            return true
        }

        if arguments == ["--diagnose"] {
            printDiagnostics()
            return true
        }

        return false
    }

    /// Held for the GUI process's lifetime once acquired, keeping the
    /// single-instance lock file descriptor open.
    private static var instanceLockDescriptor: Int32 = -1

    /// Acquire an exclusive lock so only one menu-bar instance runs at a time
    /// (e.g. launchd plus a leftover Login Item, or a Sparkle relaunch racing
    /// launchd). Uses an advisory file lock rather than NSRunningApplication so
    /// the short-lived `--activity-hook` / `--install-*` CLI processes — which
    /// share this bundle id — never count as "another instance".
    /// Returns true if this process already holds (or just acquired) the lock.
    private static func acquireSingleInstanceLock() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageMeter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent("instance.lock").path

        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }  // can't lock → don't block startup
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false  // another instance holds the lock
        }
        instanceLockDescriptor = fd  // keep open for the process lifetime
        return true
    }

    private static func printDiagnostics() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        print("UsageMeter diagnostics")
        print("executable: \(executablePath)")
        print("home: \(home.path)")

        let databases = CodexDataLocations.logDatabases(home: home)
        print("codex log databases: \(databases.isEmpty ? "none" : databases.map(\.path).joined(separator: ", "))")
        print("codex sessions: \(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/sessions").path) ? "present" : "missing")")
        print("claude project logs: \(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/projects").path) ? "present" : "missing")")
        print("claude hooks for this executable: \(ClaudeHookInstaller.isInstalled(executablePath: executablePath, home: home) ? "installed" : "missing")")
        print("launch agent: \(LaunchAgentInstaller.isInstalled(home: home) ? "installed" : "missing")")

        let now = Date()
        let monitor = UsageMonitor(home: home)
        print("codex account fingerprint: \(monitor.codexAccountFingerprint() ?? "unknown") (compare across your devices — should match)")
        let snapshot = monitor.snapshot(now: now)
        for provider in snapshot.providers {
            let availability = provider.isUnavailable ? "unavailable" : "available"
            print("\(provider.provider.rawValue.lowercased()) usage: \(availability)")
            print("  source: \(provider.source)")
            print("  detail: \(provider.detail)")
            print("  active: \(provider.isActive)")
            printWindow("short", provider.shortWindow, now: now)
            printWindow("long", provider.longWindow, now: now)
        }
    }

    private static func printWindow(_ label: String, _ window: UsageWindow, now: Date) {
        let pct = window.usedPercent.map { String(format: "%.1f%%", $0) } ?? "n/a"
        let reset = window.resetDate.map {
            String(format: "%+.0f min", $0.timeIntervalSince(now) / 60)
        } ?? "none"
        print("  \(label) [\(window.label)]: \(pct) (unit=\(window.unitName), stale=\(window.isStale), reset=\(reset))")
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var claudeHooksInstalled = false
    @Published var syncConfig: SyncConfig
    @Published var syncSaved = false
    @Published var syncTestResult: String?
    @Published var syncTesting = false
    var onSnapshot: ((UsageSnapshot) -> Void)?
    private let monitor = UsageMonitor()
    private let configLoader = UsageConfigLoader()

    init() {
        syncConfig = UsageConfigLoader().load().sync ?? SyncConfig()
        refreshClaudeHookStatus()
    }

    /// Persist the sync section (clearing it entirely when disabled and empty),
    /// then refresh so the change takes effect immediately.
    func saveSyncConfig() {
        let trimmed = syncConfig.url.trimmingCharacters(in: .whitespacesAndNewlines)
        syncConfig.url = trimmed
        let toSave: SyncConfig? = (syncConfig.enabled || !trimmed.isEmpty) ? syncConfig : nil
        try? configLoader.saveSync(toSave)
        syncSaved = true
        syncTestResult = nil
        refreshQuota()
    }

    /// Read-only reachability check so the user gets real feedback instead of
    /// silence. Never writes, so it can't overwrite shared data.
    func testSyncConnection() {
        let config = syncConfig
        syncTesting = true
        syncTestResult = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                SyncClient().probe(config: config)
            }.value
            self.syncTesting = false
            self.syncTestResult = (result.isSuccess ? "✓ " : "✕ ") + result.message
        }
    }

    func installClaudeHooks() {
        guard let executablePath = Bundle.main.executablePath else { return }
        do {
            try ClaudeHookInstaller.install(executablePath: executablePath)
            refreshClaudeHookStatus()
        } catch {
            claudeHooksInstalled = false
        }
    }

    private func refreshClaudeHookStatus() {
        guard let executablePath = Bundle.main.executablePath else { return }
        claudeHooksInstalled = ClaudeHookInstaller.isInstalled(executablePath: executablePath)
    }

    func refreshQuota() {
        Task {
            let monitor = self.monitor
            let snapshot = await Task.detached(priority: .utility) {
                monitor.snapshot()
            }.value
            self.snapshot = snapshot
            self.onSnapshot?(snapshot)
        }
    }

    func refreshActivity() {
        guard !snapshot.providers.isEmpty else { return }
        Task {
            let monitor = self.monitor
            let states = await Task.detached(priority: .utility) {
                monitor.activityStates()
            }.value
            let updatedProviders = self.snapshot.providers.map { provider in
                ProviderUsage(
                    provider: provider.provider,
                    shortWindow: provider.shortWindow,
                    longWindow: provider.longWindow,
                    detail: provider.detail,
                    source: provider.source,
                    lastUpdated: provider.lastUpdated,
                    isActive: states[provider.provider] ?? provider.isActive
                )
            }
            let updatedSnapshot = UsageSnapshot(providers: updatedProviders, generatedAt: self.snapshot.generatedAt)
            self.snapshot = updatedSnapshot
            self.onSnapshot?(updatedSnapshot)
        }
    }
}

struct UsagePopoverView: View {
    @ObservedObject var model: UsageViewModel
    let checkForUpdates: () -> Void
    let autoUpdate: Binding<Bool>
    @State private var showingSync = false

    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    var body: some View {
        Group {
            if showingSync {
                SyncSettingsView(model: model, onClose: { showingSync = false })
            } else {
                usageView
            }
        }
        .padding(16)
        .frame(width: 380, height: 430)
    }

    private var usageView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("AI Usage")
                    .font(.headline)
                Text("v\(Self.appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showingSync = true }) {
                    Image(systemName: model.syncConfig.isActive ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                }
                .buttonStyle(.borderless)
                .help("Sync across devices")
                Button(action: checkForUpdates) {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("Check for Updates")
                Button(action: model.refreshQuota) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            if !model.claudeHooksInstalled {
                Divider()
                Button("Enable Claude activity", action: model.installClaudeHooks)
                    .buttonStyle(.link)
            }

            ForEach(model.snapshot.providers, id: \.provider.rawValue) { provider in
                ProviderView(provider: provider)
            }

            Text("Codex uses logged rate-limit snapshots when available. Claude uses Anthropic OAuth usage data when available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Toggle(isOn: autoUpdate) {
                Text("Update automatically").font(.caption2).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Off by default. When on, UsageMeter checks every few hours and installs updates silently. Otherwise use the ↓ button to update manually.")
        }
    }
}

/// Bring-your-own sync configuration + a QR to pair a read-only phone view.
struct SyncSettingsView: View {
    @ObservedObject var model: UsageViewModel
    let onClose: () -> Void

    /// Static page (host anywhere) that reads the sync data and renders it.
    static let phonePageURL = "https://polymertheory.github.io/usage-meter/phone.html"
    static let setupDocsURL = "https://github.com/PolymerTheory/usage-meter/blob/main/docs/sync.md"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("Device Sync")
                    .font(.headline)
                Spacer()
                Link("Setup guide", destination: URL(string: Self.setupDocsURL)!)
                    .font(.caption)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
            Text("Optional. Publishes your usage to a URL you control so your other installs — and a phone view — can share it. Off by default; no data leaves your machine unless enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable sync", isOn: $model.syncConfig.enabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 3) {
                Text("Sync URL").font(.caption2).foregroundStyle(.secondary)
                TextField("https://your-endpoint.example/u/KEY", text: Binding(
                    get: { model.syncConfig.url },
                    set: { model.syncConfig.url = $0; model.syncSaved = false; model.syncTestResult = nil }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Token (optional)").font(.caption2).foregroundStyle(.secondary)
                TextField("bearer token", text: Binding(
                    get: { model.syncConfig.token ?? "" },
                    set: { model.syncConfig.token = $0.isEmpty ? nil : $0; model.syncSaved = false }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Reduce cross-device polling", isOn: Binding(
                    get: { model.syncConfig.coordinate },
                    set: { model.syncConfig.coordinate = $0; model.syncSaved = false }
                ))
                .toggleStyle(.switch)
                Text("With 2+ devices, only one polls Claude/Codex per interval and the others reuse the shared reading. Best with a write-tolerant backend like Supabase.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Save", action: model.saveSyncConfig)
                    .keyboardShortcut(.defaultAction)
                Button(model.syncTesting ? "Testing…" : "Test connection", action: model.testSyncConnection)
                    .disabled(model.syncTesting || urlLooksEmpty)
                if model.syncSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }

            statusLine

            if model.syncConfig.isActive {
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    if let qr = QRCode.image(from: Self.pairingURL(model.syncConfig), size: 120) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 120, height: 120)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Phone view").font(.subheadline.weight(.semibold))
                        Text("Scan to open a live page on your phone, then Add to Home Screen. The token stays in the link fragment and never reaches the page host.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var urlLooksEmpty: Bool {
        model.syncConfig.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One line telling the user exactly where they stand.
    @ViewBuilder private var statusLine: some View {
        if let result = model.syncTestResult {
            Text(result)
                .font(.caption)
                .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.syncConfig.enabled && urlLooksEmpty {
            Text("Enter a Sync URL above, then Save. See the setup guide to create one.")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.syncConfig.isActive {
            Text("Configured. Use Test connection to verify it works, then scan the code below on your phone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Disabled — the app runs locally only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func pairingURL(_ sync: SyncConfig) -> String {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        return "\(phonePageURL)#u=\(enc(sync.url))&t=\(enc(sync.token ?? ""))"
    }
}

enum QRCode {
    static func image(from string: String, size: CGFloat) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct ProviderView: View {
    let provider: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.provider.rawValue)
                    .font(.subheadline.weight(.semibold))
                if provider.isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Text(provider.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if provider.isUnavailable {
                UnavailableProviderView(provider: provider)
            } else {
                WindowRow(window: provider.shortWindow)
                WindowRow(window: provider.longWindow)
            }

            HStack(spacing: 8) {
                Text(provider.detail)
                Spacer(minLength: 0)
                // Give "Updated" priority so it never truncates; detail gets
                // whatever space remains and truncates gracefully if needed.
                Text("Updated \(relativeDate(provider.lastUpdated))")
                    .fixedSize()
                    .layoutPriority(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct UnavailableProviderView: View {
    let provider: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Open Claude Settings > Usage for the current exact quota.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// A simple horizontal progress bar drawn with explicit colors, bypassing
/// the unreliable `.tint()` modifier on macOS ProgressView.
struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: max(0, geo.size.width * CGFloat(min(fraction, 1.0))))
            }
        }
        .frame(height: 6)
    }
}

struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(window.label)
                    .frame(width: 32, alignment: .leading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                UsageBar(fraction: window.fractionUsed, color: color)
                Text(percentLabel)
                    .frame(width: 76, alignment: .trailing)
                    .font(.caption.monospacedDigit())
            }
            HStack {
                Text(unitLabel)
                Spacer()
                Text(resetLabel)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var percentLabel: String {
        if window.unitName == "unavailable" {
            return "n/a"
        }
        // "~" marks a value carried over from an old snapshot — it may no
        // longer match the provider's live dashboard.
        let prefix = window.isStale ? "~" : ""
        let suffix = window.isEstimated ? " est" : ""
        return "\(prefix)\(formatPercent(window.displayPercent))%\(suffix)"
    }

    private var unitLabel: String {
        if window.unitName == "unavailable" {
            return "quota unavailable"
        }
        if window.unitName == "quota" {
            return "quota snapshot"
        }
        return "\(formatCount(window.usedUnits)) / \(formatCount(window.limitUnits)) \(window.unitName)"
    }

    private var resetLabel: String {
        guard let resetDate = window.resetDate else {
            return "reset unknown"
        }
        let now = Date()
        let seconds = resetDate.timeIntervalSince(now)
        guard seconds > 0 else { return "resetting…" }

        // Compact countdown: "47m", "1h 57m", "6d 2h"
        let totalMinutes = Int(seconds / 60)
        let hours        = Int(seconds / 3600)
        let days         = hours / 24
        let countdown: String
        if days >= 1 {
            countdown = "\(days)d \(hours - days * 24)h"
        } else if hours >= 1 {
            countdown = "\(hours)h \(totalMinutes - hours * 60)m"
        } else {
            countdown = "\(totalMinutes)m"
        }

        // Absolute clock time, plus day name when the reset is on a different day
        let timeStr = Self.resetTimeFormatter.string(from: resetDate)
        if Calendar.current.isDateInToday(resetDate) {
            return "resets \(timeStr) (\(countdown))"
        } else {
            let dayStr = Self.resetDayFormatter.string(from: resetDate)
            return "resets \(dayStr) \(timeStr) (\(countdown))"
        }
    }

    // Formatters are reused across redraws — DateFormatter init is expensive.
    private static let resetTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"   // "9:05" not "09:05"
        return f
    }()
    private static let resetDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"    // "Mon", "Fri", …
        return f
    }()

    private var color: Color {
        switch window.fractionUsed {
        case 0..<0.55: return .green
        case 0..<0.80: return .yellow
        default: return .red
        }
    }
}

private func formatPercent(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.1f", value)
}

private func formatCount(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

enum MeterIconRenderer {
    static func image(snapshot: UsageSnapshot) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let values = iconValues(snapshot: snapshot)
        let barWidth: CGFloat = 3.5
        let gap: CGFloat = 2.0
        let baseline: CGFloat = 2.0
        let maxHeight: CGFloat = 14.0

        for (index, value) in values.enumerated() {
            let x = 2 + CGFloat(index) * (barWidth + gap)
            // An unknown window (nil) renders as a short gray stub so the user
            // can tell quota data is missing rather than reading it as "empty".
            let height = value.map { max(2, maxHeight * CGFloat($0)) } ?? 3
            let rect = NSRect(x: x, y: baseline, width: barWidth, height: height)
            color(for: value).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }

        // Activity dots: a small filled circle at the base of each provider's
        // bar pair when that provider has written session logs in the last 2 min.
        let codex  = snapshot.providers.first { $0.provider == .codex }
        let claude = snapshot.providers.first { $0.provider == .claude }
        let dotY: CGFloat = 0.4
        let dotR: CGFloat = 1.25
        // Codex bars are at indices 0 and 1; Claude at 2 and 3.
        for (isActive, barIndex) in [(codex?.isActive == true, 0), (claude?.isActive == true, 2)] {
            guard isActive else { continue }
            let x0 = 2 + CGFloat(barIndex) * (barWidth + gap)
            let x1 = 2 + CGFloat(barIndex + 1) * (barWidth + gap) + barWidth
            let cx  = (x0 + x1) / 2
            let dotRect = NSRect(x: cx - dotR, y: dotY, width: dotR * 2, height: dotR * 2)
            let dot = NSBezierPath(ovalIn: dotRect)
            // White fill with a dark outline so the dot stays visible on ANY
            // menu-bar background — light, dark, or a live/changing wallpaper —
            // without the app needing to sample the pixels behind it.
            NSColor.white.setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.7).setStroke()
            dot.lineWidth = 0.75
            dot.stroke()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Returns the fraction used for each bar, or nil when the value is unknown
    /// (provider missing or quota unavailable) so the icon can distinguish
    /// "unknown" from a genuine zero.
    private static func iconValues(snapshot: UsageSnapshot) -> [Double?] {
        let codex = snapshot.providers.first { $0.provider == .codex }
        let claude = snapshot.providers.first { $0.provider == .claude }
        return [
            value(codex?.shortWindow),
            value(codex?.longWindow),
            value(claude?.shortWindow),
            value(claude?.longWindow)
        ]
    }

    private static func value(_ window: UsageWindow?) -> Double? {
        guard let window, window.unitName != "unavailable" else {
            return nil
        }
        return window.fractionUsed
    }

    private static func color(for value: Double?) -> NSColor {
        guard let value else {
            return NSColor.systemGray
        }
        switch value {
        case 0..<0.55:
            return NSColor.systemGreen
        case 0..<0.80:
            return NSColor.systemYellow
        default:
            return NSColor.systemRed
        }
    }
}
