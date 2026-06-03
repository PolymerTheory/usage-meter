import Foundation

public struct ClaudeAPIUsageReader {
    public enum FailureReason: Equatable, Sendable {
        case missingCredentials
        case rateLimited
        case requestFailed(String)
        case decodeFailed

        var message: String {
            switch self {
            case .missingCredentials:
                return "Claude OAuth credentials unavailable"
            case .rateLimited:
                return "Claude OAuth usage API rate limited"
            case let .requestFailed(message):
                return "Claude OAuth usage API failed: \(message)"
            case .decodeFailed:
                return "Claude OAuth usage API returned unexpected data"
            }
        }
    }

    public struct ReadResult: Sendable {
        public let usage: ProviderUsage?
        public let failureReason: FailureReason?

        static func success(_ usage: ProviderUsage) -> ReadResult {
            ReadResult(usage: usage, failureReason: nil)
        }

        static func failure(_ reason: FailureReason) -> ReadResult {
            ReadResult(usage: nil, failureReason: reason)
        }
    }

    private let session: URLSession
    private let timeout: TimeInterval

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 8
    ) {
        self.session = session
        self.timeout = timeout
    }

    public func readUsage(home: URL, now: Date = Date()) -> ReadResult {
        guard let credentials = loadCredentials(home: home) else {
            return cachedUsage(home: home, now: now)
                ?? .failure(.missingCredentials)
        }

        var request = URLRequest(url: Self.usageURL, timeoutInterval: timeout)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let response = fetch(request: request)
        switch response {
        case let .success(data):
            guard let decoded = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data),
                  let usage = Self.providerUsage(from: decoded, lastUpdated: now) else {
                return .failure(.decodeFailed)
            }
            writeCache(data: data, home: home)
            return .success(usage)
        case .rateLimited:
            return cachedUsage(home: home, now: now)
                ?? .failure(.rateLimited)
        case let .failure(message):
            return cachedUsage(home: home, now: now)
                ?? .failure(.requestFailed(message))
        }
    }

    public static func providerUsage(from response: ClaudeUsageResponse, lastUpdated: Date) -> ProviderUsage? {
        let short = response.mergedWindow(for: "five_hour")
        let long = response.mergedWindow(for: "seven_day")

        guard short != nil || long != nil else {
            return nil
        }

        let shortWindow = usageWindow(
            label: "5h",
            data: short,
            fallbackPercent: long?.utilization ?? 0
        )
        let longWindow = usageWindow(
            label: "7d",
            data: long,
            fallbackPercent: short?.utilization ?? 0
        )

        return ProviderUsage(
            provider: .claude,
            shortWindow: shortWindow,
            longWindow: longWindow,
            detail: "Claude OAuth usage snapshot",
            source: "Anthropic OAuth usage API",
            lastUpdated: lastUpdated
        )
    }

    private func loadCredentials(home: URL) -> ClaudeCredentials? {
        loadCredentialsFromFile(home: home) ?? loadCredentialsFromKeychain()
    }

    private func loadCredentialsFromFile(home: URL) -> ClaudeCredentials? {
        let url = home.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return Self.credentials(from: data)
    }

    private func loadCredentialsFromKeychain() -> ClaudeCredentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", Self.keychainService, "-w"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let wait = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            wait.signal()
        }

        guard wait.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return Self.credentials(from: data)
    }

    private func fetch(request: URLRequest) -> FetchResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: FetchResult = .failure("request timed out")

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error.localizedDescription)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure("invalid response")
                return
            }
            if httpResponse.statusCode == 429 {
                result = .rateLimited
                return
            }
            guard (200..<300).contains(httpResponse.statusCode), let data else {
                result = .failure("HTTP \(httpResponse.statusCode)")
                return
            }
            result = .success(data)
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    private func cachedUsage(home: URL, now: Date) -> ReadResult? {
        let url = cacheURL(home: home)
        guard let data = try? Data(contentsOf: url),
              let response = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data),
              let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let usage = Self.providerUsage(from: response, lastUpdated: updated) else {
            return nil
        }

        return .success(
            ProviderUsage(
                provider: usage.provider,
                shortWindow: usage.shortWindow,
                longWindow: usage.longWindow,
                detail: "Cached \(usage.detail)",
                source: usage.source,
                lastUpdated: usage.lastUpdated
            )
        )
    }

    private func writeCache(data: Data, home: URL) {
        let url = cacheURL(home: home)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    private func cacheURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/UsageMeter/claude-usage.json")
    }

    private static func credentials(from data: Data) -> ClaudeCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return ClaudeCredentials(accessToken: trimmed)
    }

    private static func usageWindow(
        label: String,
        data: ClaudeUsageWindow?,
        fallbackPercent: Double
    ) -> UsageWindow {
        let percent = data?.utilization ?? fallbackPercent
        return UsageWindow(
            label: label,
            usedUnits: Int(percent.rounded()),
            limitUnits: 100,
            resetDate: data?.resetDate,
            isEstimated: false,
            usedPercent: percent,
            unitName: "quota"
        )
    }
}

private struct ClaudeCredentials: Equatable, Sendable {
    let accessToken: String
}

private enum FetchResult: Equatable, Sendable {
    case success(Data)
    case rateLimited
    case failure(String)
}

public struct ClaudeUsageResponse: Decodable, Equatable, Sendable {
    private let windows: [String: ClaudeUsageWindow]

    public init(windows: [String: ClaudeUsageWindow]) {
        self.windows = windows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var windows: [String: ClaudeUsageWindow] = [:]

        for key in container.allKeys {
            if let window = try? container.decode(ClaudeUsageWindow.self, forKey: key) {
                windows[key.stringValue] = window
            }
        }

        self.windows = windows
    }

    public func mergedWindow(for baseKey: String) -> ClaudeUsageWindow? {
        if let exact = windows[baseKey] {
            return exact
        }

        let prefix = "\(baseKey)_"
        let candidates = windows
            .filter { $0.key.hasPrefix(prefix) }
            .map(\.value)

        guard !candidates.isEmpty else {
            return nil
        }

        let utilization = candidates.map(\.utilization).max() ?? 0
        let reset = candidates.compactMap(\.resetDate).min()

        return ClaudeUsageWindow(utilization: utilization, resetsAt: reset?.iso8601String)
    }
}

public struct ClaudeUsageWindow: Decodable, Equatable, Sendable {
    public let utilization: Double
    public let resetsAt: String?

    public init(utilization: Double, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetDate: Date? {
        guard let resetsAt else {
            return nil
        }
        return Self.dateFormatters.lazy.compactMap { $0.date(from: resetsAt) }.first
    }

    private static let dateFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: self)
    }
}
