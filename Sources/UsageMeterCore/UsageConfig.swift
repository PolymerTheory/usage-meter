import Foundation

public struct UsageMeterConfig: Codable, Equatable, Sendable {
    public var codex: ProviderConfig
    public var claude: ProviderConfig

    public init(codex: ProviderConfig = .codexDefault, claude: ProviderConfig = .claudeDefault) {
        self.codex = codex
        self.claude = claude
    }

    public static var `default`: UsageMeterConfig {
        UsageMeterConfig()
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
