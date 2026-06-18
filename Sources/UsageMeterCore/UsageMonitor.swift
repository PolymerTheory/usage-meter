import Foundation

public final class UsageMonitor: @unchecked Sendable {
    private let reader: LogUsageReader
    private let codexActivityReader: CodexActivityReader
    private let claudeActivityReader: ClaudeActivityReader
    private let claudeAPIReader: ClaudeAPIUsageReader
    private let configLoader: UsageConfigLoader
    private let home: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        reader: LogUsageReader = LogUsageReader(),
        codexActivityReader: CodexActivityReader? = nil,
        claudeActivityReader: ClaudeActivityReader? = nil,
        claudeAPIReader: ClaudeAPIUsageReader = ClaudeAPIUsageReader(),
        configLoader: UsageConfigLoader = UsageConfigLoader()
    ) {
        self.home = home
        self.reader = reader
        self.codexActivityReader = codexActivityReader ?? CodexActivityReader(home: home)
        self.claudeActivityReader = claudeActivityReader ?? ClaudeActivityReader(home: home)
        self.claudeAPIReader = claudeAPIReader
        self.configLoader = configLoader
    }

    /// Local log activity remains a fallback when Claude hooks are not installed.
    private static let activityWindow: TimeInterval = 30

    public func snapshot(now: Date = Date()) -> UsageSnapshot {
        let config = configLoader.load(home: home)
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        let claudeLogsRoot = home.appendingPathComponent(".claude/projects")

        let codexActive = isCodexActive(codexRoot: codexRoot, now: now)
        let claudeActive = isClaudeActive(claudeLogsRoot: claudeLogsRoot, now: now)

        let codexEvents = reader.readCodexEvents(root: codexRoot, now: now)
        var codexUsage = reader.readLatestCodexDatabaseRateLimit(home: home, now: now)
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

        return UsageSnapshot(providers: [codexUsage, claudeUsage], generatedAt: now)
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
