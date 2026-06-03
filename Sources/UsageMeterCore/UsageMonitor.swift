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

    public func snapshot(now: Date = Date()) -> UsageSnapshot {
        let config = configLoader.load(home: home)
        let codexRoot = home.appendingPathComponent(".codex/sessions")

        let codexEvents = reader.readCodexEvents(root: codexRoot, now: now)
        let codexUsage = reader.readLatestCodexRateLimit(root: codexRoot, now: now)
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

        let claudeResult = claudeAPIReader.readUsage(home: home, now: now)
        let claudeUsage = claudeResult.usage
            ?? unavailableClaudeUsage(reason: claudeResult.failureReason, now: now)

        let providers = [
            codexUsage,
            claudeUsage
        ]

        return UsageSnapshot(providers: providers, generatedAt: now)
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
