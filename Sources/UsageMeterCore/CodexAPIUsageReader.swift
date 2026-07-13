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

    // Windows at or under this length fill the "short" (5h) display slot;
    // longer ones fill the "long" (7d) slot.
    private static let shortWindowMaxSeconds: Double = 6 * 60 * 60

    /// Parse a usage response body into a `ProviderUsage`. Exposed for tests.
    ///
    /// The ChatGPT usage endpoint returns one or more windows under
    /// `rate_limit` (`primary_window`, `secondary_window`). The position→length
    /// mapping is NOT fixed and a window can be `null` (e.g. only the 7-day
    /// window is reported when the 5-hour one is idle), so classify each present
    /// window by its own `limit_window_seconds` and tolerate a missing slot.
    public static func providerUsage(from data: Data, now: Date, stale: Bool) -> ProviderUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else {
            return nil
        }

        // Scan every window-shaped object under rate_limit rather than relying
        // on the specific keys "primary_window"/"secondary_window", so a future
        // rename or an added window (OpenAI has changed this before) still maps
        // correctly. Each window is classified purely by its own declared
        // length, so it doesn't matter which slot it arrives in or in what order.
        var shortWindow: UsageWindow?
        var longWindow: UsageWindow?
        for (_, value) in rateLimit {
            guard let obj = value as? [String: Any],
                  let percent = numeric(obj["used_percent"]),
                  let seconds = numeric(obj["limit_window_seconds"]), seconds > 0 else {
                continue
            }
            let isShort = seconds <= shortWindowMaxSeconds
            let window = UsageWindow(
                label: windowLabel(seconds: seconds),
                usedUnits: Int(percent.rounded()),
                limitUnits: 100,
                resetDate: numeric(obj["reset_at"]).map { Date(timeIntervalSince1970: $0) },
                isEstimated: false,
                usedPercent: percent,
                unitName: "quota",
                isStale: stale
            )
            if isShort {
                shortWindow = mostConstrained(shortWindow, window)
            } else {
                longWindow = mostConstrained(longWindow, window)
            }
        }

        // Need at least one real window to consider this a usable reading.
        guard shortWindow != nil || longWindow != nil else { return nil }

        let plan = (root["plan_type"] as? String).map { " (\($0))" } ?? ""
        let detail = stale ? "Cached Codex usage\(plan)" : "Codex live usage\(plan)"

        return ProviderUsage(
            provider: .codex,
            shortWindow: shortWindow ?? unavailableWindow(label: "5h"),
            longWindow: longWindow ?? unavailableWindow(label: "7d"),
            detail: detail,
            source: "chatgpt.com usage API",
            lastUpdated: now
        )
    }

    private static func mostConstrained(_ a: UsageWindow?, _ b: UsageWindow) -> UsageWindow {
        guard let a else { return b }
        return (b.usedPercent ?? 0) > (a.usedPercent ?? 0) ? b : a
    }

    private static func unavailableWindow(label: String) -> UsageWindow {
        UsageWindow(
            label: label,
            usedUnits: 0,
            limitUnits: 100,
            resetDate: nil,
            isEstimated: false,
            usedPercent: nil,
            unitName: "unavailable"
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
