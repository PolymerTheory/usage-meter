import Foundation

public final class UsageMonitor: @unchecked Sendable {
    private let reader: LogUsageReader
    private let codexActivityReader: CodexActivityReader
    private let claudeActivityReader: ClaudeActivityReader
    private let claudeAPIReader: ClaudeAPIUsageReader
    private let codexAPIReader: CodexAPIUsageReader
    private let syncClient: SyncClient
    private let configLoader: UsageConfigLoader
    private let home: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        reader: LogUsageReader = LogUsageReader(),
        codexActivityReader: CodexActivityReader? = nil,
        claudeActivityReader: ClaudeActivityReader? = nil,
        claudeAPIReader: ClaudeAPIUsageReader = ClaudeAPIUsageReader(),
        codexAPIReader: CodexAPIUsageReader = CodexAPIUsageReader(),
        syncClient: SyncClient = SyncClient(),
        configLoader: UsageConfigLoader = UsageConfigLoader()
    ) {
        self.home = home
        self.reader = reader
        self.codexActivityReader = codexActivityReader ?? CodexActivityReader(home: home)
        self.claudeActivityReader = claudeActivityReader ?? ClaudeActivityReader(home: home)
        self.claudeAPIReader = claudeAPIReader
        self.codexAPIReader = codexAPIReader
        self.syncClient = syncClient
        self.configLoader = configLoader
    }

    /// Shared data older than this is still shown but flagged stale.
    private static let syncDisplayStaleAfter: TimeInterval = 5 * 60
    /// Even when nothing changed, refresh the shared blob at most this often so
    /// the phone view can tell "alive but stable" from "device went offline".
    /// Kept well above the poll interval to respect KV's 1,000 writes/day limit.
    private static let syncHeartbeat: TimeInterval = 30 * 60

    /// Local log activity remains a fallback when Claude hooks are not installed.
    private static let activityWindow: TimeInterval = 30

    public func snapshot(now: Date = Date()) -> UsageSnapshot {
        let config = configLoader.load(home: home)
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        let claudeLogsRoot = home.appendingPathComponent(".claude/projects")

        let codexActive = isCodexActive(codexRoot: codexRoot, now: now)
        let claudeActive = isClaudeActive(claudeLogsRoot: claudeLogsRoot, now: now)

        // Coordination fast-path: if another device polled the provider APIs
        // recently and published a complete reading, reuse it and skip our own
        // API calls entirely. This is what keeps the total provider-poll rate
        // independent of how many devices are running.
        if let sync = config.sync, sync.isActive, sync.coordinate,
           let reused = coordinatedReuse(sync: sync, now: now, codexActive: codexActive, claudeActive: claudeActive) {
            return reused
        }

        let codexEvents = reader.readCodexEvents(root: codexRoot, now: now)
        // Prefer the live ChatGPT usage API (exact, current). Fall back to
        // local rate_limit log snapshots (which may be stale) and finally to
        // token estimates when nothing else is available.
        var codexUsage = codexAPIReader.readUsage(home: home, now: now)
            ?? reader.readLatestCodexDatabaseRateLimit(home: home, now: now)
            ?? reader.readLatestCodexRateLimit(root: codexRoot, now: now)
            ?? reader.summarize(
                provider: .codex,
                events: codexEvents,
                now: now,
                shortLimit: config.codex.shortLimitTokens,
                longLimit: config.codex.longLimitTokens,
                shortWindowHours: config.codex.shortWindowHours,
                longWindowDays: config.codex.longWindowDays,
                source: "~/.codex/sessions"
            )
        codexUsage = ProviderUsage(
            provider: codexUsage.provider,
            shortWindow: codexUsage.shortWindow,
            longWindow: codexUsage.longWindow,
            detail: codexUsage.detail,
            source: codexUsage.source,
            lastUpdated: codexUsage.lastUpdated,
            isActive: codexActive
        )

        let claudeResult = claudeAPIReader.readUsage(home: home, now: now)
        var claudeUsage = claudeResult.usage
            ?? unavailableClaudeUsage(reason: claudeResult.failureReason, now: now)
        claudeUsage = ProviderUsage(
            provider: claudeUsage.provider,
            shortWindow: claudeUsage.shortWindow,
            longWindow: claudeUsage.longWindow,
            detail: claudeUsage.detail,
            source: claudeUsage.source,
            lastUpdated: claudeUsage.lastUpdated,
            isActive: claudeActive
        )

        if let sync = config.sync, sync.isActive {
            return applySync(codex: codexUsage, claude: claudeUsage, sync: sync, now: now)
        }
        return UsageSnapshot(providers: [codexUsage, claudeUsage], generatedAt: now)
    }

    /// Merge locally-fetched usage with the shared blob: fill any gap where this
    /// device's data is unavailable/stale from another device, and publish the
    /// providers this device fetched live so the others (and the phone) get them.
    private func applySync(
        codex: ProviderUsage,
        claude: ProviderUsage,
        sync: SyncConfig,
        now: Date
    ) -> UsageSnapshot {
        let shared = syncClient.read(config: sync)
        let host = Self.deviceName()

        func merged(_ local: ProviderUsage, _ key: String, _ provider: UsageProvider) -> ProviderUsage {
            // Use shared data only when our own reading isn't usable.
            guard !isLive(local),
                  let remote = shared?.providers[key], remote.isAvailable else {
                return local
            }
            return remote.toProviderUsage(provider: provider, now: now, staleAfter: Self.syncDisplayStaleAfter)
        }

        let displayCodex = merged(codex, "codex", .codex)
        let displayClaude = merged(claude, "claude", .claude)

        // Build the blob to publish, preserving other devices' contributions
        // for providers we couldn't fetch live.
        var providers = shared?.providers ?? [:]
        if isLive(codex) { providers["codex"] = SharedProvider(codex, at: now, by: host) }
        if isLive(claude) { providers["claude"] = SharedProvider(claude, at: now, by: host) }

        // Decide whether to write. With coordination on, we only reach here when
        // no fresh shared reading was available, so we just polled — refresh the
        // shared blob (and its lease timestamp) whenever we got live data.
        // Without coordination, write only on change or a periodic heartbeat, to
        // respect Cloudflare KV's 1,000 writes/day free tier.
        if !providers.isEmpty {
            let haveLive = isLive(codex) || isLive(claude)
            let shouldWrite: Bool
            if sync.coordinate {
                shouldWrite = haveLive
            } else {
                let changed = Self.providersDiffer(providers, shared?.providers ?? [:])
                let heartbeatDue = shared.map { now.timeIntervalSince($0.updatedAt) > Self.syncHeartbeat } ?? true
                shouldWrite = changed || heartbeatDue
            }
            if shouldWrite {
                syncClient.publish(SharedUsage(updatedAt: now, updatedBy: host, providers: providers), config: sync)
            }
        }

        return UsageSnapshot(providers: [displayCodex, displayClaude], generatedAt: now)
    }

    /// Returns a snapshot built from a fresh, complete shared reading — skipping
    /// this device's own provider API calls — or nil if we should poll ourselves
    /// (no blob, stale, incomplete, or endpoint unreachable). Local activity
    /// flags are still this device's own.
    private func coordinatedReuse(
        sync: SyncConfig,
        now: Date,
        codexActive: Bool,
        claudeActive: Bool
    ) -> UsageSnapshot? {
        guard let shared = syncClient.read(config: sync),
              now.timeIntervalSince(shared.updatedAt) < sync.freshnessSeconds,
              let codex = shared.providers["codex"], codex.isAvailable,
              let claude = shared.providers["claude"], claude.isAvailable else {
            return nil
        }
        let codexUsage = withActive(
            codex.toProviderUsage(provider: .codex, now: now, staleAfter: Self.syncDisplayStaleAfter),
            active: codexActive
        )
        let claudeUsage = withActive(
            claude.toProviderUsage(provider: .claude, now: now, staleAfter: Self.syncDisplayStaleAfter),
            active: claudeActive
        )
        return UsageSnapshot(providers: [codexUsage, claudeUsage], generatedAt: now)
    }

    private func withActive(_ usage: ProviderUsage, active: Bool) -> ProviderUsage {
        ProviderUsage(
            provider: usage.provider,
            shortWindow: usage.shortWindow,
            longWindow: usage.longWindow,
            detail: usage.detail,
            source: usage.source,
            lastUpdated: usage.lastUpdated,
            isActive: active
        )
    }

    /// Compare the meaningful usage fields (ignoring the updatedAt/updatedBy
    /// bookkeeping, which always changes) to decide whether a write is warranted.
    private static func providersDiffer(_ a: [String: SharedProvider], _ b: [String: SharedProvider]) -> Bool {
        guard Set(a.keys) == Set(b.keys) else { return true }
        for (key, av) in a {
            guard let bv = b[key] else { return true }
            if av.short != bv.short || av.long != bv.long || av.detail != bv.detail || av.source != bv.source {
                return true
            }
        }
        return false
    }

    /// A provider reading is "live" when it has real data that isn't stale — i.e.
    /// a fresh fetch this device just made, worth sharing.
    private func isLive(_ usage: ProviderUsage) -> Bool {
        !usage.isUnavailable && !usage.shortWindow.isStale && !usage.longWindow.isStale
    }

    private static func deviceName() -> String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.replacingOccurrences(of: ".local", with: "")
    }

    public func activityStates(now: Date = Date()) -> [UsageProvider: Bool] {
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        let claudeLogsRoot = home.appendingPathComponent(".claude/projects")
        return [
            .codex: isCodexActive(codexRoot: codexRoot, now: now),
            .claude: isClaudeActive(claudeLogsRoot: claudeLogsRoot, now: now)
        ]
    }

    private func isCodexActive(codexRoot: URL, now: Date) -> Bool {
        codexActivityReader.isActive(now: now)
            ?? reader.hasRecentActivity(in: codexRoot, within: Self.activityWindow, now: now)
    }

    private func isClaudeActive(claudeLogsRoot: URL, now: Date) -> Bool {
        claudeActivityReader.isActive(now: now)
            ?? reader.hasRecentActivity(in: claudeLogsRoot, within: Self.activityWindow, now: now)
    }

    private func unavailableClaudeUsage(
        reason: ClaudeAPIUsageReader.FailureReason?,
        now: Date
    ) -> ProviderUsage {
        let shortWindow = UsageWindow(
            label: "5h",
            usedUnits: 0,
            limitUnits: 100,
            resetDate: nil,
            isEstimated: false,
            usedPercent: nil,
            unitName: "unavailable"
        )
        let longWindow = UsageWindow(
            label: "7d",
            usedUnits: 0,
            limitUnits: 100,
            resetDate: nil,
            isEstimated: false,
            usedPercent: nil,
            unitName: "unavailable"
        )

        return ProviderUsage(
            provider: .claude,
            shortWindow: shortWindow,
            longWindow: longWindow,
            detail: reason?.message ?? "Claude OAuth usage unavailable",
            source: "Anthropic OAuth usage API",
            lastUpdated: now
        )
    }
}
