import Foundation

/// Claude usage fed by Claude Code itself, through its status line.
///
/// Why: Anthropic's `/api/oauth/usage` endpoint is rate limited per account, and
/// Claude Code calls it too (`at_wall`, `skip_spend`, … variants). With many
/// sessions running — e.g. research-group loops spawning `claude -p` — they use
/// up the shared allowance and UsageMeter's own polls get 429 with a ~1 h
/// Retry-After (measured 2026-11-12: 25 claude processes, every probe refused).
///
/// But Claude Code hands every status-line command a JSON blob that already
/// contains `rate_limits.five_hour` / `seven_day` (`used_percentage`,
/// `resets_at`). Registered as the status line (`UsageMeter --statusline`),
/// UsageMeter receives fresh numbers for free whenever any session redraws,
/// and only needs the API when no Claude Code session is running — exactly
/// when the API isn't contended.
///
/// Limits (checked 2026-11-12): only *terminal* sessions run status lines —
/// Claude desktop-app (Code tab) sessions never do — and hook input carries no
/// rate limits. So this is a free supplement; the usage API remains the main
/// source whenever no terminal session has reported in the last [maxAge].
public enum ClaudeStatusLineFeed {
    /// Status-line data younger than this is treated as live.
    public static let maxAge: TimeInterval = 3 * 60

    static func cacheURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/UsageMeter/claude-statusline.json")
    }

    /// Handles one status-line invocation: stores the rate limits (if any) and
    /// returns the text Claude Code should display, e.g. "5h 41% · 7d 91%".
    @discardableResult
    public static func ingest(
        _ input: Data,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else {
            return ""
        }
        var stored: [String: Any] = ["capturedAt": now.timeIntervalSince1970]
        var parts: [String] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
            guard let window = limits[key] as? [String: Any],
                  let pct = (window["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            var entry: [String: Any] = ["used_percentage": pct]
            if let reset = (window["resets_at"] as? NSNumber)?.doubleValue { entry["resets_at"] = reset }
            stored[key] = entry
            parts.append("\(label) \(Int(pct.rounded()))%")
        }
        guard !parts.isEmpty else { return "" }

        let url = cacheURL(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: stored) {
            try? data.write(to: url, options: .atomic)
        }
        return parts.joined(separator: " · ")
    }

    /// The most recent status-line reading, if it is younger than [maxAge].
    public static func latestUsage(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        maxAge: TimeInterval = ClaudeStatusLineFeed.maxAge
    ) -> ProviderUsage? {
        guard let data = try? Data(contentsOf: cacheURL(home: home)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let captured = json["capturedAt"] as? Double else { return nil }
        let capturedAt = Date(timeIntervalSince1970: captured)
        guard now.timeIntervalSince(capturedAt) <= maxAge else { return nil }

        func window(_ key: String, _ label: String) -> UsageWindow? {
            guard let w = json[key] as? [String: Any], let pct = w["used_percentage"] as? Double else { return nil }
            let reset = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            // A window that has reset since capture restarts from zero.
            let rolledOver = reset.map { $0 <= now } ?? false
            let percent = rolledOver ? 0 : pct
            return UsageWindow(
                label: label,
                usedUnits: Int(percent.rounded()),
                limitUnits: 100,
                resetDate: rolledOver ? nil : reset,
                isEstimated: false,
                usedPercent: percent,
                unitName: "quota"
            )
        }
        let short = window("five_hour", "5h")
        let long = window("seven_day", "7d")
        guard short != nil || long != nil else { return nil }
        let unavailable = { (label: String) in
            UsageWindow(label: label, usedUnits: 0, limitUnits: 100, resetDate: nil,
                        isEstimated: false, usedPercent: nil, unitName: "unavailable")
        }
        return ProviderUsage(
            provider: .claude,
            shortWindow: short ?? unavailable("5h"),
            longWindow: long ?? unavailable("7d"),
            detail: "Claude Code status line",
            source: "Claude Code",
            lastUpdated: capturedAt
        )
    }
}

/// Registers `UsageMeter --statusline` as Claude Code's status line, without
/// ever overwriting a status line the user configured themselves.
public enum ClaudeStatusLineInstaller {
    public enum Result: Equatable {
        case installed
        case alreadyInstalled
        /// The user has their own status line; left untouched.
        case keptExisting(String)
    }

    static func command(for executablePath: String) -> String {
        "'\(executablePath)' --statusline"
    }

    public static func isInstalled(
        executablePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let existing = (loadSettings(home: home)?["statusLine"] as? [String: Any])?["command"] as? String
        return existing == command(for: executablePath)
    }

    @discardableResult
    public static func install(
        executablePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Result {
        let url = home.appendingPathComponent(".claude/settings.json")
        // A settings file that exists but doesn't parse must never be replaced
        // by one holding only our status line — that would wipe the user's
        // Claude Code configuration.
        if FileManager.default.fileExists(atPath: url.path), loadSettings(home: home) == nil {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        var root = loadSettings(home: home) ?? [:]
        let ours = command(for: executablePath)
        if let existing = root["statusLine"] as? [String: Any] {
            let cmd = existing["command"] as? String ?? ""
            if cmd == ours { return .alreadyInstalled }
            // Replace only a stale UsageMeter entry (e.g. the app moved);
            // anything else is the user's own status line.
            guard cmd.contains("UsageMeter") && cmd.hasSuffix("--statusline") else {
                return .keptExisting(cmd)
            }
        }
        root["statusLine"] = ["type": "command", "command": ours, "padding": 0]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return .installed
    }

    private static func loadSettings(home: URL) -> [String: Any]? {
        let url = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
