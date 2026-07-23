import Foundation

public struct ClaudeAPIUsageReader {
    public enum FailureReason: Equatable, Sendable {
        case missingCredentials
        case desktopTokenCacheOnly
        case credentialsExpired
        case rateLimited
        case requestFailed(String)
        case decodeFailed

        var message: String {
            switch self {
            case .missingCredentials:
                return "Claude OAuth credentials unavailable"
            case .desktopTokenCacheOnly:
                return "Claude desktop token cache found, but Claude Code CLI OAuth credentials are unavailable"
            case .credentialsExpired:
                return "Claude Code sign-in expired — run 'claude login' to refresh"
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
    private static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let scopes = "user:profile user:inference user:sessions:claude_code"
    private static let keychainService = "Claude Code-credentials"
    private static let refreshBuffer: TimeInterval = 5 * 60
    /// Minimum spacing between live usage-endpoint calls. Within this window a
    /// recent cached response is served as current, so rapid popover opens (and
    /// other frequent snapshot calls) can't burst-hit the API and earn a 429.
    private static let minLiveInterval: TimeInterval = 60

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 8
    ) {
        self.session = session
        self.timeout = timeout
    }

    /// - Parameter force: set for a user-initiated refresh, which skips the
    ///   short-lived cache so the call actually goes to the API. The rate-limit
    ///   backoff is still respected — forcing through a 429 would only extend it.
    public func readUsage(home: URL, now: Date = Date(), force: Bool = false) -> ReadResult {
        // Serve a very recent cached response as current instead of calling the
        // live API again, so bursts of snapshot() calls don't hammer the endpoint.
        if !force, let fresh = freshCachedUsage(home: home, now: now, maxAge: Self.minLiveInterval) {
            return fresh
        }

        guard var credentials = loadCredentials(home: home, now: now) else {
            let reason: FailureReason = hasClaudeDesktopTokenCache(home: home)
                ? .desktopTokenCacheOnly
                : .missingCredentials
            return cachedUsage(home: home, now: now, fallbackReason: reason)
                ?? .failure(reason)
        }

        if let rateLimit = activeRateLimit(home: home, now: now) {
            return cachedUsage(home: home, now: now, fallbackReason: .rateLimited)
                ?? .failure(.requestFailed("Claude OAuth usage API rate limited until \(rateLimit)"))
        }

        if credentials.needsRefresh(now: now, refreshBuffer: Self.refreshBuffer) {
            let outcome = refreshCredentials(credentials, home: home, now: now)
            if case let .refreshed(creds) = outcome {
                credentials = creds
            } else {
                // Refresh didn't work — either the endpoint rejected us
                // (`.expired`) or it was unreachable (`.failed`). Neither is
                // proof that the *access* token is unusable: Claude Code stamps
                // a conservative expiry and keeps its own token fresh, so the
                // one we hold is very often still good. Try it before drawing
                // any conclusion — only the API rejecting it means the user
                // genuinely has to sign in again. Giving up here instead is
                // what used to freeze Claude for as long as the refresh
                // endpoint stayed unhappy.
                let fallbackResponse = fetchUsage(credentials: credentials)
                switch fallbackResponse {
                case let .success(data):
                    guard let decoded = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data),
                          let usage = Self.providerUsage(from: decoded, lastUpdated: now, now: now) else {
                        return .failure(.decodeFailed)
                    }
                    writeCache(data: data, home: home)
                    return .success(usage)
                case let .rateLimited(retryAfter):
                    recordRateLimit(home: home, now: now, retryAfter: retryAfter)
                    return cachedUsage(home: home, now: now, fallbackReason: .rateLimited)
                        ?? .failure(.rateLimited)
                case let .failure(message):
                    // The token itself was refused and refresh can't fix it:
                    // this is the one case where re-running `claude login` is
                    // the actual remedy.
                    let refreshRejected: Bool = { if case .expired = outcome { return true }; return false }()
                    if refreshRejected, message.contains("401") || message.contains("403") {
                        return .failure(.credentialsExpired)
                    }
                    let detail = hasClaudeDesktopTokenCache(home: home)
                        ? "legacy OAuth token is expired and Claude's modern desktop token cache is unsupported; access token fetch failed: \(message)"
                        : "token refresh unavailable; access token fetch failed: \(message)"
                    return cachedUsage(home: home, now: now, fallbackReason: .requestFailed(detail))
                        ?? .failure(.requestFailed(detail))
                }
            }
        }

        let response = fetchUsage(credentials: credentials)
        switch response {
        case let .success(data):
            guard let decoded = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data),
                  let usage = Self.providerUsage(from: decoded, lastUpdated: now, now: now) else {
                return .failure(.decodeFailed)
            }
            writeCache(data: data, home: home)
            return .success(usage)
        case let .rateLimited(retryAfter):
            recordRateLimit(home: home, now: now, retryAfter: retryAfter)
            return cachedUsage(home: home, now: now, fallbackReason: .rateLimited)
                ?? .failure(.rateLimited)
        case let .failure(message):
            if message == "HTTP 401" || message == "HTTP 403" {
                switch refreshCredentials(credentials, home: home, now: now) {
                case let .refreshed(creds):
                    return fetchUsageAfterRefresh(creds, home: home, now: now)
                case .expired:
                    return .failure(.credentialsExpired)
                case .failed:
                    break
                }
            }
            return cachedUsage(home: home, now: now, fallbackReason: .requestFailed(message))
                ?? .failure(.requestFailed(message))
        }
    }

    public static func providerUsage(
        from response: ClaudeUsageResponse,
        lastUpdated: Date,
        now: Date? = nil,
        stale: Bool = false
    ) -> ProviderUsage? {
        let short = response.mergedWindow(for: "five_hour")
        let long = response.mergedWindow(for: "seven_day")

        guard short != nil || long != nil else {
            return nil
        }

        let shortWindow = usageWindow(
            label: "5h",
            data: short,
            fallbackPercent: long?.utilization ?? 0,
            now: now,
            stale: stale
        )
        let longWindow = usageWindow(
            label: "7d",
            data: long,
            fallbackPercent: short?.utilization ?? 0,
            now: now,
            stale: stale
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

    private func loadCredentials(home: URL, now: Date) -> ClaudeCredentials? {
        loadCredentialsFromUsageMeterKeychain(now: now)
            ?? loadCredentialsFromFile(home: home)
            ?? loadCredentialsFromKeychain()
    }

    private func loadCredentialsFromUsageMeterKeychain(now: Date) -> ClaudeCredentials? {
        guard let data = ClaudeHookCredentialCapture.load(),
              let credentials = Self.credentials(from: data, source: .usageMeterKeychain),
              let expiresAt = credentials.expiresAt,
              expiresAt > now else {
            return nil
        }
        return credentials
    }

    private func loadCredentialsFromFile(home: URL) -> ClaudeCredentials? {
        let url = home.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return Self.credentials(from: data, source: .file)
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
        return Self.credentials(from: data, source: .keychain)
    }

    private func fetchUsage(credentials: ClaudeCredentials) -> FetchResult {
        var request = URLRequest(url: Self.usageURL, timeoutInterval: timeout)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return fetch(request: request)
    }

    private func fetchUsageAfterRefresh(_ credentials: ClaudeCredentials, home: URL, now: Date) -> ReadResult {
        switch fetchUsage(credentials: credentials) {
        case let .success(data):
            guard let decoded = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data),
                  let usage = Self.providerUsage(from: decoded, lastUpdated: now, now: now) else {
                return .failure(.decodeFailed)
            }
            writeCache(data: data, home: home)
            return .success(usage)
        case let .rateLimited(retryAfter):
            recordRateLimit(home: home, now: now, retryAfter: retryAfter)
            return cachedUsage(home: home, now: now, fallbackReason: .rateLimited)
                ?? .failure(.rateLimited)
        case let .failure(message):
            return cachedUsage(home: home, now: now, fallbackReason: .requestFailed(message))
                ?? .failure(.requestFailed(message))
        }
    }

    private enum RefreshOutcome {
        case refreshed(ClaudeCredentials)
        /// The refresh token itself was rejected — the user must sign in again.
        case expired
        /// Transient failure (network / rate limit / 5xx) — worth retrying later.
        case failed
    }

    private func refreshCredentials(_ credentials: ClaudeCredentials, home: URL, now: Date) -> RefreshOutcome {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            // No refresh token to work with: the sign-in can only be renewed
            // by re-authenticating Claude Code.
            return .expired
        }

        var request = URLRequest(url: Self.refreshURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scopes
        ])

        switch fetch(request: request) {
        case let .rateLimited(retryAfter):
            recordRateLimit(home: home, now: now, retryAfter: retryAfter)
            return .failed
        case let .failure(message):
            // A 4xx from the token endpoint means the refresh token is rejected
            // (e.g. "invalid_grant: Refresh token expired"); re-login required.
            if message == "HTTP 400" || message == "HTTP 401" || message == "HTTP 403" {
                return .expired
            }
            return .failed
        case let .success(data):
            guard let refresh = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data),
                  let accessToken = refresh.accessToken,
                  !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed
            }
            var updated = credentials
            updated.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if let refreshToken = refresh.refreshToken, !refreshToken.isEmpty {
                updated.refreshToken = refreshToken
            }
            if let expiresIn = refresh.expiresIn {
                updated.expiresAt = now.addingTimeInterval(TimeInterval(expiresIn))
            }
            saveCredentials(updated, home: home)
            return .refreshed(updated)
        }
    }

    private func saveCredentials(_ credentials: ClaudeCredentials, home: URL) {
        var data = credentials.fullData
        var oauth = data["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = credentials.accessToken
        if let refreshToken = credentials.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = credentials.expiresAt {
            oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
        }
        if let subscriptionType = credentials.subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }
        data["claudeAiOauth"] = oauth

        switch credentials.source {
        case .usageMeterKeychain:
            if let encoded = try? JSONSerialization.data(withJSONObject: data) {
                ClaudeHookCredentialCapture.save(data: encoded)
            }
        case .file:
            let url = home.appendingPathComponent(".claude/.credentials.json")
            if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
                try? encoded.write(to: url, options: [.atomic])
            }
        case .keychain:
            saveCredentialsToKeychain(data, service: Self.keychainService)
        }
    }

    private func saveCredentialsToKeychain(_ data: [String: Any], service: String) {
        guard let encoded = try? JSONSerialization.data(withJSONObject: data),
              let password = String(data: encoded, encoding: .utf8) else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password",
            "-s", service,
            "-a", NSUserName(),
            "-w", password,
            "-U"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
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
                let header = httpResponse.value(forHTTPHeaderField: "Retry-After")
                result = .rateLimited(retryAfter: header.flatMap(TimeInterval.init))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode), let data, !data.isEmpty else {
                result = .failure("HTTP \(httpResponse.statusCode)")
                return
            }
            result = .success(data)
        }
        task.resume()

        // Wait slightly longer than the request's own timeout so the URLSession
        // error path reports the real failure; only fall back to a hard cancel
        // if the callback never fires.
        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
        }
        return result
    }

    /// Returns the cached response as a current (non-stale) reading when it is
    /// younger than `maxAge`, otherwise nil so the caller performs a live fetch.
    private func freshCachedUsage(home: URL, now: Date, maxAge: TimeInterval) -> ReadResult? {
        let url = cacheURL(home: home)
        guard let data = try? Data(contentsOf: url),
              let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(updated) >= 0,
              now.timeIntervalSince(updated) < maxAge,
              let response = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data),
              let usage = Self.providerUsage(from: response, lastUpdated: updated, now: now) else {
            return nil
        }
        return .success(usage)
    }

    private func cachedUsage(home: URL, now: Date, fallbackReason: FailureReason?) -> ReadResult? {
        let url = cacheURL(home: home)
        guard let data = try? Data(contentsOf: url),
              let response = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data),
              let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let usage = Self.providerUsage(from: response, lastUpdated: updated, now: now, stale: true) else {
            return nil
        }

        let detail = [
            "Cached Claude OAuth usage snapshot",
            fallbackReason.map { "live API unavailable: \($0.message)" }
        ].compactMap { $0 }.joined(separator: "; ")

        return .success(
            ProviderUsage(
                provider: usage.provider,
                shortWindow: usage.shortWindow,
                longWindow: usage.longWindow,
                detail: detail,
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

    private func rateLimitURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/UsageMeter/claude-rate-limit.json")
    }

    private func hasClaudeDesktopTokenCache(home: URL) -> Bool {
        let url = home.appendingPathComponent("Library/Application Support/Claude/config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["oauth:tokenCacheV2"] != nil || json["oauth:tokenCache"] != nil
    }

    private func activeRateLimit(home: URL, now: Date) -> Date? {
        let url = rateLimitURL(home: home)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let until = json["until"] as? Double else {
            return nil
        }
        let date = Date(timeIntervalSince1970: until)
        return date > now ? date : nil
    }

    private func recordRateLimit(home: URL, now: Date, retryAfter: TimeInterval?) {
        let url = rateLimitURL(home: home)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Honor the server's Retry-After when present: polling again before it
        // expires just earns another 429 and can extend the ban. Without a
        // header, back off one refresh cycle. Clamp to a sane range and add a
        // small buffer so we don't retry a hair too early.
        let base = retryAfter ?? (5 * 60)
        let backoff = min(max(base, 5 * 60), 2 * 60 * 60) + 15
        let payload = ["until": now.addingTimeInterval(backoff).timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private static func credentials(from data: Data, source: CredentialSource) -> ClaudeCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return ClaudeCredentials(
            accessToken: trimmed,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt(oauth["expiresAt"]),
            subscriptionType: oauth["subscriptionType"] as? String,
            source: source,
            fullData: json
        )
    }

    private static func expiresAt(_ value: Any?) -> Date? {
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value / 1000)
        }
        if let value = value as? Int {
            return Date(timeIntervalSince1970: Double(value) / 1000)
        }
        if let value = value as? String, let milliseconds = Double(value) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return nil
    }

    private static func usageWindow(
        label: String,
        data: ClaudeUsageWindow?,
        fallbackPercent: Double,
        now: Date?,
        stale: Bool
    ) -> UsageWindow {
        let resetDate = data?.resetDate
        let isStale = now.map { current in resetDate.map { $0 <= current } ?? false } ?? false
        let percent = isStale ? 0 : (data?.utilization ?? fallbackPercent)
        return UsageWindow(
            label: label,
            usedUnits: Int(percent.rounded()),
            limitUnits: 100,
            resetDate: isStale ? nil : resetDate,
            isEstimated: false,
            usedPercent: percent,
            unitName: "quota",
            isStale: stale
        )
    }
}

private struct ClaudeCredentials {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var subscriptionType: String?
    var source: CredentialSource
    var fullData: [String: Any]

    func needsRefresh(now: Date, refreshBuffer: TimeInterval) -> Bool {
        guard let expiresAt else {
            return false
        }
        return now.addingTimeInterval(refreshBuffer) >= expiresAt
    }
}

private enum CredentialSource: Sendable {
    case usageMeterKeychain
    case file
    case keychain
}

private enum FetchResult: Equatable, Sendable {
    case success(Data)
    /// 429 from the server; `retryAfter` is the server-requested cooldown in
    /// seconds when a `Retry-After` header was present.
    case rateLimited(retryAfter: TimeInterval?)
    case failure(String)
}

private struct TokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
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

    /// Feature-specific 7-day buckets that are not part of the Claude Code
    /// subscription quota the meter cares about. They are excluded from the
    /// merge so an unrelated bucket cannot drive the displayed percentage.
    private static let ignoredWindowSuffixes = ["oauth_apps", "cowork", "omelette", "promotional"]

    /// Combine the base window (e.g. `seven_day`) with any model-specific
    /// variants (e.g. `seven_day_opus`, `seven_day_sonnet`) and report the
    /// most-constrained one. The Anthropic usage endpoint returns *both* the
    /// aggregate window and the per-model windows simultaneously; on Max/Pro
    /// plans the per-model (often Opus) window is usually the binding limit,
    /// so taking the base value alone under-reports real usage.
    public func mergedWindow(for baseKey: String) -> ClaudeUsageWindow? {
        let prefix = "\(baseKey)_"
        var candidates: [ClaudeUsageWindow] = []

        if let exact = windows[baseKey] {
            candidates.append(exact)
        }

        for (key, window) in windows where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            if Self.ignoredWindowSuffixes.contains(where: { suffix.contains($0) }) {
                continue
            }
            candidates.append(window)
        }

        guard !candidates.isEmpty else {
            return nil
        }

        // The binding window is the one closest to its limit. Prefer its own
        // reset time; fall back to the earliest future reset if it lacks one.
        let binding = candidates.max(by: { $0.utilization < $1.utilization })
        let utilization = binding?.utilization ?? 0
        let reset = binding?.resetDate ?? candidates.compactMap(\.resetDate).min()

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
