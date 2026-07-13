import Foundation

public struct UsageMeterConfig: Codable, Equatable, Sendable {
    public var codex: ProviderConfig
    public var claude: ProviderConfig
    /// Optional cross-device sync. Absent/disabled by default.
    public var sync: SyncConfig?

    public init(
        codex: ProviderConfig = .codexDefault,
        claude: ProviderConfig = .claudeDefault,
        sync: SyncConfig? = nil
    ) {
        self.codex = codex
        self.claude = claude
        self.sync = sync
    }

    public static var `default`: UsageMeterConfig {
        UsageMeterConfig()
    }

    enum CodingKeys: String, CodingKey {
        case codex, claude, sync
    }

    // Decode each section independently so a partial config (e.g. only a sync
    // block) still loads, falling back to defaults for anything omitted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.codex = try c.decodeIfPresent(ProviderConfig.self, forKey: .codex) ?? .codexDefault
        self.claude = try c.decodeIfPresent(ProviderConfig.self, forKey: .claude) ?? .claudeDefault
        self.sync = try c.decodeIfPresent(SyncConfig.self, forKey: .sync)
    }
}

/// Optional sync backend: the app publishes its usage to `url` and reads it
/// back, so a user's other installs (and a read-only phone view) can share one
/// account's data. Bring-your-own endpoint — the app never ships a default host.
/// The `url` must be a per-user, key-scoped endpoint that stores the JSON body
/// on PUT and returns it on GET; `token` is sent as a bearer credential.
public struct SyncConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var url: String
    public var token: String?
    /// A blob newer than this many seconds is treated as fresh enough to reuse
    /// without every device re-fetching from the provider APIs.
    public var freshnessSeconds: Double

    public init(enabled: Bool = false, url: String = "", token: String? = nil, freshnessSeconds: Double = 90) {
        self.enabled = enabled
        self.url = url
        self.token = token
        self.freshnessSeconds = freshnessSeconds
    }

    public var isActive: Bool {
        enabled && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case enabled, url, token, freshnessSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.token = try c.decodeIfPresent(String.self, forKey: .token)
        self.freshnessSeconds = try c.decodeIfPresent(Double.self, forKey: .freshnessSeconds) ?? 90
    }
}

public struct ProviderConfig: Codable, Equatable, Sendable {
    public var shortWindowHours: Double
    public var longWindowDays: Double
    public var shortLimitTokens: Int
    public var longLimitTokens: Int

    public init(shortWindowHours: Double, longWindowDays: Double, shortLimitTokens: Int, longLimitTokens: Int) {
        self.shortWindowHours = shortWindowHours
        self.longWindowDays = longWindowDays
        self.shortLimitTokens = shortLimitTokens
        self.longLimitTokens = longLimitTokens
    }

    public static var codexDefault: ProviderConfig {
        ProviderConfig(shortWindowHours: 5, longWindowDays: 7, shortLimitTokens: 100_000, longLimitTokens: 500_000)
    }

    public static var claudeDefault: ProviderConfig {
        ProviderConfig(shortWindowHours: 5, longWindowDays: 7, shortLimitTokens: 300_000, longLimitTokens: 1_500_000)
    }
}

public struct UsageConfigLoader {
    private let fileManager: FileManager
    private let decoder = JSONDecoder()

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> UsageMeterConfig {
        let url = home.appendingPathComponent(".usage-meter.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let config = try? decoder.decode(UsageMeterConfig.self, from: data) else {
            return .default
        }
        return config
    }
}
