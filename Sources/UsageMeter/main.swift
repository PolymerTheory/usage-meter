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
    /// Captures a stack sample if the main thread ever hangs (the intermittent
    /// "can't close the popover / app frozen" symptom).
    private let watchdog = MainThreadWatchdog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchDiagnostics.write("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        // Raise the open-file-descriptor soft limit well above the 256 default.
        // Belt-and-suspenders with the keychain-subprocess leak fix: even if
        // some future path leaks descriptors slowly, the app has huge headroom
        // before it could become unresponsive, and it stays diagnosable.
        var fdLimit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &fdLimit) == 0 {
            fdLimit.rlim_cur = min(rlim_t(8192), fdLimit.rlim_max)
            _ = setrlimit(RLIMIT_NOFILE, &fdLimit)
        }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep AI usage meter current"
        )

        watchdog.start()

        // Extra dismissal path: if the app resigns active (user clicks another
        // app or the menu bar) close the popover, so it can't get stuck open
        // even if the global outside-click monitor misses an event.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appResignedActive),
            name: NSApplication.didResignActiveNotification, object: nil
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
        // Added in .common run-loop modes so they keep firing while a popover or
        // menu is in tracking mode (a .default-mode timer pauses during that).
        let quotaTimer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refreshQuota() }
        }
        RunLoop.main.add(quotaTimer, forMode: .common)

        let activityTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refreshActivity() }
        }
        RunLoop.main.add(activityTimer, forMode: .common)
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

        // Only re-render the icon (and log) when the visible state changes.
        // The 1-second activity timer calls this constantly; rebuilding the
        // NSImage and writing a log line every tick wastes CPU and floods the
        // diagnostics log.
        let colors = model.colors
        let signature = Self.renderSignature(for: snapshot, colors: colors)
        guard signature != lastRenderSignature else { return }
        lastRenderSignature = signature

        let icon = MeterIconRenderer.image(snapshot: snapshot, colors: colors)
        button.image = icon
        // Size the menu-bar item to the icon so it shrinks when only one
        // provider is shown (2 bars) rather than reserving room for four.
        statusItem.length = icon.size.width + 6
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
    private static func renderSignature(for snapshot: UsageSnapshot, colors: MeterColors) -> String {
        let providerPart = snapshot.providers.map { provider in
            func part(_ window: UsageWindow) -> String {
                window.unitName == "unavailable" ? "x" : String(Int(window.fractionUsed * 100))
            }
            return "\(provider.provider.rawValue):\(part(provider.shortWindow)):\(part(provider.longWindow)):\(provider.isActive)"
        }.joined(separator: "|")
        // Include colors so the icon re-renders when the scheme changes even if
        // the usage numbers didn't.
        let colorPart = "\(colors.lowHex)\(colors.midHex)\(colors.highHex)\(colors.midThreshold)\(colors.highThreshold)"
        return providerPart + "#" + colorPart
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

    @objc private func appResignedActive() {
        if popover.isShown { closePopover() }
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
    // Serialize writes off the main thread — this is called on every icon
    // re-render, and synchronous file I/O on the main thread is exactly the kind
    // of thing that can contribute to a UI stall.
    private static let queue = DispatchQueue(label: "io.github.PolymerTheory.UsageMeter.diag")

    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        queue.async {
            let url = URL(fileURLWithPath: "/tmp/UsageMeter-launch.log")
            guard let data = line.data(using: .utf8) else { return }
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

/// Detects a hung main thread and captures a stack sample the moment it happens.
/// The UI freeze users hit is intermittent and can't be reproduced on demand, so
/// this leaves hard evidence (a `sample` of every thread) in
/// `~/Library/Logs/UsageMeter/` for the next occurrence instead of guesswork.
final class MainThreadWatchdog: @unchecked Sendable {
    static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/UsageMeter")

    private let checkQueue = DispatchQueue(label: "io.github.PolymerTheory.UsageMeter.watchdog")
    private let lock = NSLock()
    private var lastBeat = Date()
    private var mainTimer: Timer?
    private var checkTimer: DispatchSourceTimer?
    private var stalled = false
    private var stallStarted = Date()
    private var lastCheck = Date()
    private var checkTick = 0
    private var fdWarned = false
    private let threshold: TimeInterval

    init(stallThreshold: TimeInterval = 6) { self.threshold = stallThreshold }

    func start() {
        try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)

        // Heartbeat on the main run loop (common modes so it keeps ticking even
        // during menu/popover tracking). If the main thread hangs, this stops.
        let beat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.lastBeat = Date(); self.lock.unlock()
        }
        RunLoop.main.add(beat, forMode: .common)
        mainTimer = beat

        // Independent checker on a background queue — unaffected by a main hang.
        let timer = DispatchSource.makeTimerSource(queue: checkQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        checkTimer = timer
        append("watchdog started (threshold \(Int(threshold))s)")
    }

    private func check() {
        let now = Date()
        // If this background checker was itself suspended (its own interval ran
        // long), the whole system was likely asleep — not a main-thread hang.
        // Reset and skip so we don't log a false stall on wake.
        let checkGap = now.timeIntervalSince(lastCheck)
        lastCheck = now
        if checkGap > threshold {
            lock.lock(); lastBeat = now; lock.unlock()
            stalled = false
            return
        }

        lock.lock(); let beat = lastBeat; lock.unlock()
        let gap = now.timeIntervalSince(beat)
        if gap > threshold {
            if !stalled {
                stalled = true
                stallStarted = Date().addingTimeInterval(-gap)
                append("MAIN THREAD STALL: unresponsive ~\(Int(gap))s — capturing sample")
                captureSample()
            }
        } else if stalled {
            stalled = false
            append("main thread RECOVERED after ~\(Int(Date().timeIntervalSince(stallStarted)))s")
        }

        // ~ every minute, watch the open file-descriptor count. A slow leak
        // (like the keychain-subprocess one that froze the app after ~19 days)
        // shows up here long before it becomes fatal.
        checkTick += 1
        if checkTick % 30 == 0 { checkFileDescriptors() }
    }

    private func checkFileDescriptors() {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else { return }
        let count = entries.count
        if count > 200, !fdWarned {
            fdWarned = true
            append("FD LEAK WARNING: \(count) open descriptors — capturing sample")
            captureSample()
        } else if count < 150 {
            fdWarned = false   // re-arm once it recovers
        }
    }

    private func captureSample() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let out = Self.logDir.appendingPathComponent("hang-\(Self.fileStamp()).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // Sampling reads all threads via the kernel, so it works even while the
        // main thread is wedged; run from this bg queue and don't block on it.
        p.arguments = [String(pid), "4", "-file", out.path, "-mayDie"]
        try? p.run()
    }

    private func append(_ line: String) {
        let url = Self.logDir.appendingPathComponent("hangs.log")
        guard let data = "\(Self.fileStamp()) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
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
        // The un-merged local Claude read. The provider blocks below can show a
        // *shared* reading from another device, which hides whether this machine
        // can talk to the API at all — this line answers that directly.
        let rawClaude = ClaudeAPIUsageReader().readUsage(home: home, now: now, force: true)
        if let reason = rawClaude.failureReason {
            print("claude live fetch: FAILED — \(String(describing: reason))")
        } else if let usage = rawClaude.usage {
            let pct = usage.longWindow.usedPercent.map { String(format: "%.1f%%", $0) } ?? "n/a"
            print("claude live fetch: ok (\(usage.longWindow.label) \(pct))")
        }

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

        // With coordination on, the displayed values may be another device's
        // reading. Show what a forced (live) poll returns so the two can be
        // compared — this is what the popover's refresh button now does.
        if UsageConfigLoader().load(home: home).sync?.coordinate == true {
            print("--- forced live poll (what the refresh button fetches) ---")
            for provider in monitor.snapshot(now: Date(), force: true).providers {
                print("\(provider.provider.rawValue.lowercased()): \(provider.detail)")
                printWindow("  long", provider.longWindow, now: now)
            }
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
    /// True while a user-initiated refresh is in flight (drives the spinner).
    @Published private(set) var isRefreshing = false
    /// Set after a forced refresh that couldn't get live data, so the user sees why.
    @Published private(set) var refreshStatus: String?
    /// Per-provider display toggles. The backend still polls both; these only
    /// control what appears in the icon and popover.
    @Published private(set) var codexEnabled = true
    @Published private(set) var claudeEnabled = true
    /// Bar colors and thresholds, editable in Settings.
    @Published private(set) var colors: MeterColors = .default
    var onSnapshot: ((UsageSnapshot) -> Void)?
    private let monitor = UsageMonitor()
    private let configLoader = UsageConfigLoader()
    /// The unfiltered reading from the monitor. `snapshot` is this filtered to
    /// the enabled providers; keeping both lets a toggle re-filter instantly
    /// without re-polling.
    private var fullSnapshot: UsageSnapshot = .empty

    init() {
        let config = UsageConfigLoader().load()
        syncConfig = config.sync ?? SyncConfig()
        colors = config.colors

        // Resolve the display toggles. When a provider's flag is unset (first
        // run), auto-detect it from whether its credentials exist and persist a
        // concrete value the user can flip later.
        if config.codex.enabled == nil || config.claude.enabled == nil {
            let avail = monitor.providerAvailability()
            if !avail.codex && !avail.claude {
                // Not signed into either yet — show both rather than a blank
                // icon; the unavailable bars prompt the user to sign in.
                codexEnabled = config.codex.enabled ?? true
                claudeEnabled = config.claude.enabled ?? true
            } else {
                codexEnabled = config.codex.enabled ?? avail.codex
                claudeEnabled = config.claude.enabled ?? avail.claude
            }
            try? configLoader.saveProviderEnablement(codex: codexEnabled, claude: claudeEnabled)
        } else {
            codexEnabled = config.codex.enabled ?? true
            claudeEnabled = config.claude.enabled ?? true
        }

        refreshClaudeHookStatus()
    }

    /// Names of the providers currently shown, in display order — drives the
    /// loading placeholders and the "nothing enabled" hint.
    var enabledProviderNames: [String] {
        var names: [String] = []
        if codexEnabled { names.append("Codex") }
        if claudeEnabled { names.append("Claude") }
        return names
    }

    func isEnabled(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .codex: return codexEnabled
        case .claude: return claudeEnabled
        }
    }

    /// Flip a provider's display toggle, persist it, and re-filter immediately
    /// (no re-poll needed — the data for both providers is already in hand).
    func setEnabled(_ provider: UsageProvider, _ on: Bool) {
        switch provider {
        case .codex: codexEnabled = on
        case .claude: claudeEnabled = on
        }
        try? configLoader.saveProviderEnablement(codex: codexEnabled, claude: claudeEnabled)
        applyDisplayFilter()
    }

    /// Update the color scheme, persist it, and re-render the icon immediately
    /// (the popover re-renders on its own since `colors` is @Published).
    func setColors(_ newColors: MeterColors) {
        colors = newColors
        try? configLoader.saveColors(newColors)
        applyDisplayFilter()
    }

    func restoreDefaultColors() {
        setColors(.default)
    }

    private func filtered(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        UsageSnapshot(
            providers: snapshot.providers.filter { isEnabled($0.provider) },
            generatedAt: snapshot.generatedAt
        )
    }

    /// Recompute the displayed snapshot from `fullSnapshot` and push it to the
    /// icon. Called after a poll, an activity update, or a toggle change.
    private func applyDisplayFilter() {
        let display = filtered(fullSnapshot)
        snapshot = display
        onSnapshot?(display)
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

    /// - Parameter force: user-initiated. Bypasses the coordination fast-path and
    ///   the readers' short caches so it really re-queries, shows a spinner, and
    ///   reports why if a provider comes back unusable.
    func refreshQuota(force: Bool = false) {
        if force {
            guard !isRefreshing else { return }
            isRefreshing = true
            refreshStatus = nil
        }
        Task {
            let monitor = self.monitor
            let snapshot = await Task.detached(priority: .utility) {
                monitor.snapshot(force: force)
            }.value
            self.fullSnapshot = snapshot
            self.applyDisplayFilter()
            if force {
                self.isRefreshing = false
                // Only report problems for providers the user actually shows.
                self.refreshStatus = Self.refreshProblem(in: self.snapshot)
            }
        }
    }

    /// A short, human explanation when a forced refresh didn't yield live data
    /// for some provider — nil when everything came back fresh.
    private static func refreshProblem(in snapshot: UsageSnapshot) -> String? {
        for provider in snapshot.providers {
            let name = provider.provider.rawValue
            if provider.isUnavailable {
                return "\(name): \(provider.detail)"
            }
            if provider.shortWindow.isStale || provider.longWindow.isStale {
                return "\(name): couldn't refresh — showing last known. \(provider.detail)"
            }
        }
        return nil
    }

    func refreshActivity() {
        guard !fullSnapshot.providers.isEmpty else { return }
        Task {
            let monitor = self.monitor
            let states = await Task.detached(priority: .utility) {
                monitor.activityStates()
            }.value
            let updatedProviders = self.fullSnapshot.providers.map { provider in
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
            self.fullSnapshot = UsageSnapshot(providers: updatedProviders, generatedAt: self.fullSnapshot.generatedAt)
            self.applyDisplayFilter()
        }
    }
}

struct UsagePopoverView: View {
    @ObservedObject var model: UsageViewModel
    let checkForUpdates: () -> Void
    let autoUpdate: Binding<Bool>
    @State private var showingSync = false
    @State private var showingSettings = false

    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    var body: some View {
        Group {
            if showingSync {
                SyncSettingsView(model: model, onClose: { showingSync = false })
            } else if showingSettings {
                SettingsView(model: model, autoUpdate: autoUpdate, onClose: { showingSettings = false })
            } else {
                // Tick every second so the reset countdown and "Updated Xm ago"
                // stay live while the popover is open. Deriving them only from
                // the snapshot object meant they froze at whatever time the last
                // snapshot arrived (or the popover opened) — a run-loop timer in
                // .default mode doesn't fire during popover tracking, so an open
                // popover could show a badly stale countdown.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    usageView(now: context.date)
                }
            }
        }
        .padding(16)
        .frame(width: 380, height: 430)
    }

    private func usageView(now: Date) -> some View {
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
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                Button(action: checkForUpdates) {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("Check for Updates")
                Button(action: { model.refreshQuota(force: true) }) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help("Refresh now (queries the provider APIs directly)")
            }

            if let status = model.refreshStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.claudeHooksInstalled {
                Divider()
                Button("Enable Claude activity", action: model.installClaudeHooks)
                    .buttonStyle(.link)
            }

            if model.enabledProviderNames.isEmpty {
                Text("No providers shown — turn on Codex or Claude in Settings (the gear icon above).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.snapshot.providers.isEmpty {
                // Cold start (or a fresh relaunch) before the first fetch lands:
                // show named placeholders with a spinner rather than an empty
                // box, so the popover reads as "loading" instead of "broken".
                ForEach(model.enabledProviderNames, id: \.self) { name in
                    LoadingProviderView(name: name)
                }
            } else {
                ForEach(model.snapshot.providers, id: \.provider.rawValue) { provider in
                    ProviderView(provider: provider, now: now, colors: model.colors)
                }
            }

            Text("Codex uses logged rate-limit snapshots when available. Claude uses Anthropic OAuth usage data when available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

/// Small settings sheet reached via the gear — keeps set-and-forget options out
/// of the glanceable main popover.
struct SettingsView: View {
    @ObservedObject var model: UsageViewModel
    let autoUpdate: Binding<Bool>
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("Settings")
                    .font(.headline)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Show").font(.subheadline.weight(.semibold))
                        Text("Which tools appear in the menu-bar icon and this popover. Auto-detected on first run from which you're signed into.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Codex", isOn: Binding(
                            get: { model.codexEnabled },
                            set: { model.setEnabled(.codex, $0) }
                        ))
                        Toggle("Claude", isOn: Binding(
                            get: { model.claudeEnabled },
                            set: { model.setEnabled(.claude, $0) }
                        ))
                    }
                    .toggleStyle(.checkbox)

                    Divider()

                    colorsSection

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Updates").font(.subheadline.weight(.semibold))
                        Toggle("Update automatically", isOn: autoUpdate)
                            .toggleStyle(.checkbox)
                        Text("Off by default. When on, UsageMeter checks every few hours and installs updates silently. Otherwise use the ↓ button on the main screen to update manually.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var colorsSection: some View {
        let midPct = Int((model.colors.midThreshold * 100).rounded())
        let highPct = Int((model.colors.highThreshold * 100).rounded())
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Colors").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Restore defaults") { model.restoreDefaultColors() }
                    .font(.caption)
                    .buttonStyle(.link)
                    .disabled(model.colors == .default)
            }
            Text("The bar color at each usage level, and the thresholds where it switches.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ColorPicker(selection: colorBinding(\.lowHex), supportsOpacity: false) {
                Text("Low — under \(midPct)%").font(.caption)
            }
            ColorPicker(selection: colorBinding(\.midHex), supportsOpacity: false) {
                Text("Medium — \(midPct)–\(highPct)%").font(.caption)
            }
            ColorPicker(selection: colorBinding(\.highHex), supportsOpacity: false) {
                Text("High — \(highPct)% and up").font(.caption)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Medium starts at \(midPct)%").font(.caption2).foregroundStyle(.secondary)
                Slider(value: midThresholdBinding, in: 1...98, step: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("High starts at \(highPct)%").font(.caption2).foregroundStyle(.secondary)
                Slider(value: highThresholdBinding, in: 2...99, step: 1)
            }
        }
    }

    /// A ColorPicker binding onto one hex field of the scheme.
    private func colorBinding(_ keyPath: WritableKeyPath<MeterColors, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: model.colors[keyPath: keyPath]) },
            set: { newColor in
                var c = model.colors
                c[keyPath: keyPath] = newColor.hexString
                model.setColors(c)
            }
        )
    }

    // Threshold sliders, kept ordered so Medium can never cross above High.
    private var midThresholdBinding: Binding<Double> {
        Binding(
            get: { model.colors.midThreshold * 100 },
            set: { pct in
                var c = model.colors
                c.midThreshold = min(max(pct / 100, 0.01), 0.98)
                if c.highThreshold <= c.midThreshold {
                    c.highThreshold = min(c.midThreshold + 0.01, 0.99)
                }
                model.setColors(c)
            }
        )
    }

    private var highThresholdBinding: Binding<Double> {
        Binding(
            get: { model.colors.highThreshold * 100 },
            set: { pct in
                var c = model.colors
                c.highThreshold = min(max(pct / 100, 0.02), 0.99)
                if c.midThreshold >= c.highThreshold {
                    c.midThreshold = max(c.highThreshold - 0.01, 0.01)
                }
                model.setColors(c)
            }
        )
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
    /// Live clock, ticked by the popover's TimelineView, so relative labels
    /// ("Updated Xm ago", the reset countdown) stay current instead of frozen.
    var now: Date = Date()
    var colors: MeterColors = .default

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
                WindowRow(window: provider.shortWindow, now: now, colors: colors)
                WindowRow(window: provider.longWindow, now: now, colors: colors)
            }

            HStack(spacing: 8) {
                Text(provider.detail)
                Spacer(minLength: 0)
                // Give "Updated" priority so it never truncates; detail gets
                // whatever space remains and truncates gracefully if needed.
                Text("Updated \(relativeDate(provider.lastUpdated, now: now))")
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

/// Placeholder card shown for each provider before the first snapshot lands,
/// so a cold start looks like it's loading rather than blank.
struct LoadingProviderView: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                ProgressView().controlSize(.small)
            }
            Text("Loading usage…")
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
    /// Live clock from the popover's TimelineView so the reset countdown ticks.
    var now: Date = Date()
    var colors: MeterColors = .default

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
        Color(hex: colors.hex(forFraction: window.fractionUsed))
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

private func relativeDate(_ date: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: now)
}

// MARK: - Hex color helpers

extension NSColor {
    /// Parse "#RRGGBB" (or "RRGGBB"); falls back to gray on malformed input.
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var v: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&v) else {
            self.init(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1); return
        }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
    var hexString: String { NSColor(self).hexString }
}

enum MeterIconRenderer {
    private static let barWidth: CGFloat = 3.5
    private static let gap: CGFloat = 2.0
    private static let leftPad: CGFloat = 2.0
    private static let rightPad: CGFloat = 2.0

    /// Icon width for the given number of bars, so the menu-bar item shrinks to
    /// fit when only one provider is shown (2 bars) instead of two (4 bars).
    static func width(forBars bars: Int) -> CGFloat {
        let n = max(bars, 1)
        return leftPad + CGFloat(n) * barWidth + CGFloat(n - 1) * gap + rightPad
    }

    static func image(snapshot: UsageSnapshot, colors: MeterColors = .default) -> NSImage {
        // Only providers present in the snapshot are drawn, in a stable order,
        // two bars each — so a display filtered to one provider yields 2 bars.
        let order: [UsageProvider] = [.codex, .claude]
        let providers = order.compactMap { p in snapshot.providers.first { $0.provider == p } }
        let barCount = max(providers.count * 2, 1)

        let size = NSSize(width: width(forBars: barCount), height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let baseline: CGFloat = 2.0
        let maxHeight: CGFloat = 14.0

        func barX(_ index: Int) -> CGFloat { leftPad + CGFloat(index) * (barWidth + gap) }

        // Nothing enabled: draw a single neutral stub so the item stays visible
        // and clickable; the popover explains how to turn a provider back on.
        if providers.isEmpty {
            let rect = NSRect(x: barX(0), y: baseline, width: barWidth, height: 3)
            NSColor.systemGray.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            image.unlockFocus()
            image.isTemplate = false
            return image
        }

        var barIndex = 0
        for provider in providers {
            for window in [provider.shortWindow, provider.longWindow] {
                let v = value(window)
                // An unknown window (nil) renders as a short gray stub so the
                // user can tell quota data is missing rather than reading it as
                // "empty".
                let height = v.map { max(2, maxHeight * CGFloat($0)) } ?? 3
                let rect = NSRect(x: barX(barIndex), y: baseline, width: barWidth, height: height)
                color(for: v, colors: colors).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                barIndex += 1
            }
        }

        // Activity dots: a small filled circle at the base of each provider's
        // bar pair when that provider has written session logs recently.
        let dotY: CGFloat = 0.4
        let dotR: CGFloat = 1.25
        for (p, provider) in providers.enumerated() where provider.isActive {
            let x0 = barX(p * 2)
            let x1 = barX(p * 2 + 1) + barWidth
            let cx = (x0 + x1) / 2
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

    private static func value(_ window: UsageWindow?) -> Double? {
        guard let window, window.unitName != "unavailable" else {
            return nil
        }
        return window.fractionUsed
    }

    private static func color(for value: Double?, colors: MeterColors) -> NSColor {
        guard let value else {
            return NSColor.systemGray  // unknown/unavailable stays a neutral stub
        }
        return NSColor(hex: colors.hex(forFraction: value))
    }
}
