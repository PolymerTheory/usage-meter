import Foundation

public enum UsageProvider: String, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
}

public struct UsageWindow: Equatable, Sendable {
    public let label: String
    public let usedUnits: Int
    public let limitUnits: Int
    public let resetDate: Date?
    public let isEstimated: Bool
    public let usedPercent: Double?
    public let unitName: String
    /// True when the underlying snapshot is old enough that the displayed
    /// figure may no longer match the provider's live dashboard. Exact
    /// snapshots (e.g. Codex rate limits) are only refreshed while the tool
    /// is in use, so an idle period leaves the value frozen and increasingly
    /// approximate.
    public let isStale: Bool

    public init(
        label: String,
        usedUnits: Int,
        limitUnits: Int,
        resetDate: Date?,
        isEstimated: Bool,
        usedPercent: Double? = nil,
        unitName: String = "tokens",
        isStale: Bool = false
    ) {
        self.label = label
        self.usedUnits = usedUnits
        self.limitUnits = max(limitUnits, 1)
        self.resetDate = resetDate
        self.isEstimated = isEstimated
        self.usedPercent = usedPercent
        self.unitName = unitName
        self.isStale = isStale
    }

    public var fractionUsed: Double {
        if let usedPercent {
            return min(1.0, max(0.0, usedPercent / 100.0))
        }
        return min(1.0, max(0.0, Double(usedUnits) / Double(limitUnits)))
    }

    public var displayPercent: Double {
        usedPercent ?? fractionUsed * 100.0
    }
}

public struct ProviderUsage: Equatable, Sendable {
    public let provider: UsageProvider
    public let shortWindow: UsageWindow
    public let longWindow: UsageWindow
    public let detail: String
    public let source: String
    public let lastUpdated: Date
    /// True when this provider appears to be actively processing a turn.
    public let isActive: Bool

    public init(
        provider: UsageProvider,
        shortWindow: UsageWindow,
        longWindow: UsageWindow,
        detail: String,
        source: String,
        lastUpdated: Date,
        isActive: Bool = false
    ) {
        self.provider = provider
        self.shortWindow = shortWindow
        self.longWindow = longWindow
        self.detail = detail
        self.source = source
        self.lastUpdated = lastUpdated
        self.isActive = isActive
    }

    public var isUnavailable: Bool {
        shortWindow.unitName == "unavailable" || longWindow.unitName == "unavailable"
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let providers: [ProviderUsage]
    public let generatedAt: Date

    public init(providers: [ProviderUsage], generatedAt: Date) {
        self.providers = providers
        self.generatedAt = generatedAt
    }

    public static var empty: UsageSnapshot {
        UsageSnapshot(providers: [], generatedAt: Date())
    }
}

public struct UsageEvent: Equatable, Sendable {
    public let timestamp: Date
    public let tokens: Int

    public init(timestamp: Date, tokens: Int) {
        self.timestamp = timestamp
        self.tokens = max(tokens, 1)
    }
}
