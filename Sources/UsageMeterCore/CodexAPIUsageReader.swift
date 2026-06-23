import Foundation

/// Reads exact, current Codex usage from the ChatGPT backend usage endpoint
/// using the OAuth credentials Codex stores in `~/.codex/auth.json`.
///
/// This is the Codex analogue of `ClaudeAPIUsageReader`: it returns live
/// figures that match the Codex usage dashboard. Local `rate_limits` log
/// snapshots are only written while Codex is in use, so they go stale during
/// idle periods; the live endpoint does not. When the endpoint is unavailable
/// (offline, expired token) this returns `nil` so the caller can fall back to
/// the local-log reader.
public struct CodexAPIUsageReader {
    private let session: URLSession
    private let timeout: TimeInterval

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(session: URLSession = .shared, timeout: TimeInterval = 8) {
        self.session = session
        self.timeout = timeout
    }

    public func readUsage(home: URL, now: Date = Date()) -> ProviderUsage? {
        guard let credentials = loadCredentials(home: home) else {
            return cachedUsage(home: home)
        }

        guard let data = fetch(credentials: credentials) else {
            return cachedUsage(home: home)
        }

        guard let usage = Self.providerUsage(from: data, now: now, stale: false) else {
            return cachedUsage(home: home)
        }

        writeCache(data: data, home: home)
        return usage
    }

    /// Parse a usage response body into a `ProviderUsage`. Exposed for tests.
    public static func providerUsage(from data: Data, now: Date, stale: Bool) -> ProviderUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else {
            return nil
        }

        let primary = window(
            from: rateLimit["primary_window"] as? [String: Any],
            fallbackLabelSeconds: 5 * 60 * 60,
            stale: stale
        )
        let secondary = window(
            from: rateLimit["secondary_window"] as? [String: Any],
            fallbackLabelSeconds: 7 * 24 * 60 * 60,
            stale: stale
        )

        guard let primary, let secondary else { return nil }

        let plan = (root["plan_type"] as? String).map { " (\($0))" } ?? ""
        let detail = stale
            ? "Cached Codex usage\(plan)"
            : "Codex live usage\(plan)"

        return ProviderUsage(
            provider: .codex,
            shortWindow: primary,
            longWindow: secondary,
            detail: detail,
            source: "chatgpt.com usage API",
            lastUpdated: now
        )
    }

    private static func window(
        from object: [String: Any]?,
        fallbackLabelSeconds: Double,
        stale: Bool
    ) -> UsageWindow? {
        guard let object, let percent = numeric(object["used_percent"]) else {
            return nil
        }
        let windowSeconds = numeric(object["limit_window_seconds"]) ?? fallbackLabelSeconds
        let reset = numeric(object["reset_at"]).map { Date(timeIntervalSince1970: $0) }

        return UsageWindow(
            label: windowLabel(seconds: windowSeconds),
            usedUnits: Int(percent.rounded()),
            limitUnits: 100,
            resetDate: reset,
            isEstimated: false,
            usedPercent: percent,
            unitName: "quota",
            isStale: stale
        )
    }

    // MARK: - Credentials

    private struct Credentials {
        let accessToken: String
        let accountId: String?
    }

    private func loadCredentials(home: URL) -> Credentials? {
        let url = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Credentials(
            accessToken: token,
            accountId: tokens["account_id"] as? String
        )
    }

    // MARK: - Networking

    private func fetch(credentials: Credentials) -> Data? {
        var request = URLRequest(url: Self.usageURL, timeoutInterval: timeout)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data, !data.isEmpty else {
                return
            }
            result = data
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
        }
        return result
    }

    // MARK: - Cache

    private func cachedUsage(home: URL) -> ProviderUsage? {
        let url = cacheURL(home: home)
        guard let data = try? Data(contentsOf: url),
              let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return nil
        }
        // A cached live response is exact-but-old; surface it as stale.
        return Self.providerUsage(from: data, now: updated, stale: true)
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
        home.appendingPathComponent("Library/Caches/UsageMeter/codex-usage.json")
    }
}

// MARK: - Helpers

private func numeric(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? String { return Double(value) }
    return nil
}

private func windowLabel(seconds: Double) -> String {
    let minutes = seconds / 60
    if minutes >= 24 * 60 {
        let days = minutes / (24 * 60)
        return "\(formatWindowNumber(days))d"
    }
    if minutes >= 60 {
        return "\(formatWindowNumber(minutes / 60))h"
    }
    return "\(formatWindowNumber(minutes))m"
}

private func formatWindowNumber(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
}
