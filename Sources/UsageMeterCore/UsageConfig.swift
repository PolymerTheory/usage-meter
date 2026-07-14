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

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(codex, forKey: .codex)
        try c.encode(claude, forKey: .claude)
        try c.encodeIfPresent(sync, forKey: .sync)
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
    /// When `coordinate` is on, a shared reading newer than this many seconds is
    /// reused instead of hitting the provider APIs. Must exceed the poll
    /// interval or no poll is ever skipped. Also sets the effective total
    /// provider-poll rate: about 3600/freshnessSeconds per hour, regardless of
    /// how many devices are running.
    public var freshnessSeconds: Double
    /// Opt-in cross-device coordination: only one device polls Claude/Codex per
    /// freshness window; the others reuse the shared reading. Writes the shared
    /// blob every poll, so it suits a write-tolerant backend (e.g. Supabase).
    public var coordinate: Bool

    public init(
        enabled: Bool = false,
        url: String = "",
        token: String? = nil,
        freshnessSeconds: Double = 150,
        coordinate: Bool = false
    ) {
        self.enabled = enabled
        self.url = url
        self.token = token
        self.freshnessSeconds = freshnessSeconds
        self.coordinate = coordinate
    }

    public var isActive: Bool {
        enabled && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case enabled, url, token, freshnessSeconds, coordinate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.token = try c.decodeIfPresent(String.self, forKey: .token)
        self.freshnessSeconds = try c.decodeIfPresent(Double.self, forKey: .freshnessSeconds) ?? 150
        self.coordinate = try c.decodeIfPresent(Bool.self, forKey: .coordinate) ?? false
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
        var config = readMain(home: home)

        // Sync credentials are hard to re-enter, so they're mirrored to a backup
        // outside the main config file. If the main file is missing or lost its
        // sync section (e.g. hand-edited, or clobbered), restore it from the
        // backup and heal the main file. If the main file has sync but no backup
        // exists yet, seed the backup.
        if config.sync == nil, let backup = readSyncBackup(home: home), !backup.url.isEmpty {
            config.sync = backup
            try? writeMain(config, home: home)
        } else if let sync = config.sync, !sync.url.isEmpty, readSyncBackup(home: home) == nil {
            writeSyncBackup(sync, home: home)
        }
        return config
    }

    /// Update only the sync section, preserving everything else in the file, and
    /// mirror it to the backup.
    public func saveSync(_ sync: SyncConfig?, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        var config = readMain(home: home)
        config.sync = sync
        try writeMain(config, home: home)
        writeSyncBackup(sync, home: home)
    }

    // MARK: - File helpers

    private func readMain(home: URL) -> UsageMeterConfig {
        let url = home.appendingPathComponent(".usage-meter.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let config = try? decoder.decode(UsageMeterConfig.self, from: data) else {
            return .default
        }
        return config
    }

    private func writeMain(_ config: UsageMeterConfig, home: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: home.appendingPathComponent(".usage-meter.json"), options: .atomic)
    }

    private func syncBackupURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/UsageMeter/sync-backup.json")
    }

    private func readSyncBackup(home: URL) -> SyncConfig? {
        let url = syncBackupURL(home: home)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SyncConfig.self, from: data)
    }

    /// Mirror the sync section to the backup (or remove it when sync is cleared,
    /// so a deliberate disable isn't silently resurrected).
    private func writeSyncBackup(_ sync: SyncConfig?, home: URL) {
        let url = syncBackupURL(home: home)
        guard let sync, !sync.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? fileManager.removeItem(at: url)
            return
        }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sync) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
