import Foundation

public final class UsageMonitor {
    private let reader: LogUsageReader
    private let claudeAPIReader: ClaudeAPIUsageReader
    private let configLoader: UsageConfigLoader
    private let home: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        reader: LogUsageReader = LogUsageReader(),
        claudeAPIReader: ClaudeAPIUsageReader = ClaudeAPIUsageReader(),
        configLoader: UsageConfigLoader = UsageConfigLoader()
    ) {
        self.home = home
        self.reader = reader
        self.claudeAPIReader = claudeAPIReader
        self.configLoader = configLoader
    }

    /// A session log file modified within this window is treated as an
    /// active session. Long enough to cover the gap between the start of
    /// an API request and the first response/tool-call log write (~30s
    /// typical), short enough to clear promptly once the task finishes.
    private static let activityWindow: TimeInterval = 90

    public func snapshot(now: Date = Date()) -> UsageSnapshot {
        let config = configLoader.load(home: home)
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        let claudeLogsRoot = home.appendingPathComponent(".claude/projects")

        // Activity check: look for log files modified within the last 2 minutes.
        let codexActive  = reader.hasRecentActivity(in: codexRoot,      within: Self.activityWindow, now: now)
        let claudeActive = reader.hasRecentActivity(in: claudeLogsRoot, within: Self.activityWindow, now: now)

        let codexEvents = reader.readCodexEvents(root: codexRoot, now: now)
        var codexUsage = reader.readLatestCodexRateLimit(root: codexRoot, now: now)
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

        return UsageSnapshot(providers: [codexUsage, claudeUsage], generatedAt: now)
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
