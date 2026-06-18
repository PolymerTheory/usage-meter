import Foundation

public struct LogUsageReader {
    public let fileManager: FileManager
    public let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.decoder = JSONDecoder()
    }

    /// Returns true when any regular file under `root` was modified within
    /// `seconds` of `now`. Stops on the first match.
    ///
    /// Note: directory mtime only changes when files are added/removed, NOT
    /// when existing files are modified. Skipping directories by mtime would
    /// miss active sessions that append to existing log files, so we check
    /// every file's mtime directly (metadata-only — no content reads).
    public func hasRecentActivity(in root: URL, within seconds: TimeInterval, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-seconds)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let url as URL in enumerator {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                  rv.isRegularFile == true,
                  let mtime = rv.contentModificationDate else { continue }
            if mtime >= cutoff { return true }
        }
        return false
    }

    public func readCodexEvents(root: URL, now: Date = Date()) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return readJSONLines(root: root, newerThan: cutoff) { object in
            guard let timestamp = parseDate(object["timestamp"]) else {
                return nil
            }

            let payload = object["payload"] as? [String: Any]
            let type = object["type"] as? String
            let role = payload?["role"] as? String
            let itemType = payload?["type"] as? String

            if type == "event_msg",
               itemType == "token_count",
               let info = payload?["info"] as? [String: Any],
               let lastUsage = info["last_token_usage"] as? [String: Any] {
                return UsageEvent(timestamp: timestamp, tokens: tokenCount(from: lastUsage))
            }

            if type == "event_msg",
               let message = payload?["message"] as? String {
                return UsageEvent(timestamp: timestamp, tokens: max(1, message.count / 4))
            }

            if type == "response_item", role == "user" {
                return UsageEvent(timestamp: timestamp, tokens: inferredTokens(from: payload ?? object))
            }

            if type == "turn_context" {
                return UsageEvent(timestamp: timestamp, tokens: 1)
            }

            return nil
        }
    }

    public func readLatestCodexRateLimit(root: URL, now: Date = Date()) -> ProviderUsage? {
        // Read newest files first and stop after the first file that contains
        // any rate_limits snapshot — we only need the single most recent one.
        let snapshots: [CodexRateLimitEvent] = readJSONLines(
            root: root,
            newerThan: nil,
            sortNewestFirst: true,
            stopAfterFirstFile: true
        ) { object in
            guard let timestamp = parseDate(object["timestamp"]),
                  let payload = object["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any],
                  let primary = rateLimits["primary"] as? [String: Any],
                  let secondary = rateLimits["secondary"] as? [String: Any] else {
                return nil
            }

            let primaryPercent = numeric(primary["used_percent"])
            let secondaryPercent = numeric(secondary["used_percent"])
            guard let primaryPercent, let secondaryPercent else {
                return nil
            }

            let primaryMinutes = numeric(primary["window_minutes"]) ?? 300
            let secondaryMinutes = numeric(secondary["window_minutes"]) ?? 10080
            let planType = rateLimits["plan_type"] as? String

            return CodexRateLimitEvent(
                timestamp: timestamp,
                primaryPercent: primaryPercent,
                primaryMinutes: primaryMinutes,
                primaryResetDate: resetDate(primary["resets_at"]),
                secondaryPercent: secondaryPercent,
                secondaryMinutes: secondaryMinutes,
                secondaryResetDate: resetDate(secondary["resets_at"]),
                planType: planType
            )
        }

        guard let latest = snapshots.max(by: { $0.timestamp < $1.timestamp }) else {
            return nil
        }

        return codexUsage(
            from: latest,
            source: "~/.codex/sessions rate_limits",
            now: now
        )
    }

    public func readLatestCodexDatabaseRateLimit(home: URL, now: Date = Date()) -> ProviderUsage? {
        for database in CodexDataLocations.logDatabases(home: home) {
            let sql = """
            select ts, feedback_log_body
            from logs
            where (
                target = 'codex_api::endpoint::responses_websocket'
                and feedback_log_body like '%websocket event: {"type":"codex.rate_limits"%'
              ) or (
                target = 'log'
                and feedback_log_body like 'Received message {"type":"codex.rate_limits"%'
              )
            order by id desc
            limit 1;
            """
            guard let output = runSQLite(database: database, sql: sql),
                  let separator = output.firstIndex(of: "\t"),
                  let timestamp = TimeInterval(output[..<separator]) else {
                continue
            }

            let body = String(output[output.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let marker = body.range(of: #"{"type":"codex.rate_limits""#),
                  let data = String(body[marker.lowerBound...]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rateLimits = object["rate_limits"] as? [String: Any],
                  let primary = rateLimits["primary"] as? [String: Any],
                  let secondary = rateLimits["secondary"] as? [String: Any],
                  let primaryPercent = numeric(primary["used_percent"]),
                  let secondaryPercent = numeric(secondary["used_percent"]) else {
                continue
            }

            let event = CodexRateLimitEvent(
                timestamp: Date(timeIntervalSince1970: timestamp),
                primaryPercent: primaryPercent,
                primaryMinutes: numeric(primary["window_minutes"]) ?? 300,
                primaryResetDate: resetDate(primary["reset_at"] ?? primary["resets_at"]),
                secondaryPercent: secondaryPercent,
                secondaryMinutes: numeric(secondary["window_minutes"]) ?? 10080,
                secondaryResetDate: resetDate(secondary["reset_at"] ?? secondary["resets_at"]),
                planType: object["plan_type"] as? String
            )
            return codexUsage(
                from: event,
                source: database.path.hasSuffix("/sqlite/logs_2.sqlite")
                    ? "~/.codex/sqlite/logs_2.sqlite"
                    : "~/.codex/logs_2.sqlite",
                now: now
            )
        }

        return nil
    }

    private func codexUsage(
        from latest: CodexRateLimitEvent,
        source: String,
        now: Date
    ) -> ProviderUsage {

        let primaryWindow = resolvedRateLimitWindow(
            usedPercent: latest.primaryPercent,
            resetDate: latest.primaryResetDate,
            windowMinutes: latest.primaryMinutes,
            now: now
        )
        let secondaryWindow = resolvedRateLimitWindow(
            usedPercent: latest.secondaryPercent,
            resetDate: latest.secondaryResetDate,
            windowMinutes: latest.secondaryMinutes,
            now: now
        )

        return ProviderUsage(
            provider: .codex,
            shortWindow: UsageWindow(
                label: windowLabel(minutes: latest.primaryMinutes),
                usedUnits: Int(primaryWindow.usedPercent.rounded()),
                limitUnits: 100,
                resetDate: primaryWindow.resetDate,
                isEstimated: false,
                usedPercent: primaryWindow.usedPercent,
                unitName: "quota"
            ),
            longWindow: UsageWindow(
                label: windowLabel(minutes: latest.secondaryMinutes),
                usedUnits: Int(secondaryWindow.usedPercent.rounded()),
                limitUnits: 100,
                resetDate: secondaryWindow.resetDate,
                isEstimated: false,
                usedPercent: secondaryWindow.usedPercent,
                unitName: "quota"
            ),
            detail: "Codex rate-limit snapshot\(latest.planType.map { " (\($0))" } ?? "") • log \(relativeAge(of: latest.timestamp, now: now))",
            source: source,
            lastUpdated: now
        )
    }

    private func runSQLite(database: URL, sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-separator", "\t", database.path, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    public func readClaudeEvents(root: URL, now: Date = Date()) -> [UsageEvent] {
        readJSONLines(root: root) { object in
            let timestamp = parseDate(object["timestamp"])
                ?? parseDate((object["message"] as? [String: Any])?["timestamp"])

            guard let timestamp else {
                return nil
            }

            if let message = object["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let tokens = tokenCount(from: usage)
                return UsageEvent(timestamp: timestamp, tokens: max(tokens, 1))
            }

            if object["type"] as? String == "user" {
                return UsageEvent(timestamp: timestamp, tokens: 1)
            }

            return nil
        }
    }

    public func summarize(
        provider: UsageProvider,
        events: [UsageEvent],
        now: Date,
        shortLimit: Int,
        longLimit: Int,
        shortWindowHours: Double = 5,
        longWindowDays: Double = 7,
        source: String
    ) -> ProviderUsage {
        let shortInterval = shortWindowHours * 60 * 60
        let longInterval = longWindowDays * 24 * 60 * 60
        let shortStart = now.addingTimeInterval(-shortInterval)
        let longStart = now.addingTimeInterval(-longInterval)
        let shortEvents = events.filter { $0.timestamp >= shortStart }
        let longEvents = events.filter { $0.timestamp >= longStart }
        let shortUsed = shortEvents.reduce(0) { $0 + $1.tokens }
        let longUsed = longEvents.reduce(0) { $0 + $1.tokens }

        return ProviderUsage(
            provider: provider,
            shortWindow: UsageWindow(
                label: shortWindowLabel(hours: shortWindowHours),
                usedUnits: shortUsed,
                limitUnits: shortLimit,
                resetDate: shortEvents.map(\.timestamp).min()?.addingTimeInterval(shortInterval),
                isEstimated: true,
                unitName: "tokens"
            ),
            longWindow: UsageWindow(
                label: longWindowLabel(days: longWindowDays),
                usedUnits: longUsed,
                limitUnits: longLimit,
                resetDate: longEvents.map(\.timestamp).min()?.addingTimeInterval(longInterval),
                isEstimated: true,
                unitName: "tokens"
            ),
            detail: "\(events.count) local events, \(longUsed) estimated token units in 7 days",
            source: source,
            lastUpdated: now
        )
    }

    /// Enumerate JSONL/JSON files under `root`, parse each line, and map it
    /// to an event.
    ///
    /// - Parameters:
    ///   - newerThan: Skip files (and entire directories) whose modification
    ///     time is before this date. Pass `nil` to read everything.
    ///   - sortNewestFirst: Sort collected files by mtime descending before
    ///     reading them. Combined with `stopAfterFirstFile` this lets callers
    ///     that only need the most-recent result avoid reading old files at all.
    ///   - stopAfterFirstFile: Stop reading as soon as the first file that
    ///     produces at least one event has been processed.
    private func readJSONLines<Event>(
        root: URL,
        newerThan: Date? = nil,
        sortNewestFirst: Bool = false,
        stopAfterFirstFile: Bool = false,
        map: ([String: Any]) -> Event?
    ) -> [Event] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            let mtime = rv.contentModificationDate ?? Date.distantPast

            if rv.isDirectory == true {
                // Skip the entire subtree when the directory hasn't been
                // touched since before our cutoff — no new files can live there.
                if let newerThan, mtime < newerThan {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard rv.isRegularFile == true,
                  url.pathExtension == "jsonl" || url.pathExtension == "json" else {
                continue
            }

            if let newerThan, mtime < newerThan {
                continue
            }

            files.append((url, mtime))
        }

        if sortNewestFirst {
            files.sort { $0.mtime > $1.mtime }
        }

        var events: [Event] = []
        for (fileURL, _) in files {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }

            var fileEvents: [Event] = []
            for line in text.split(separator: "\n") {
                guard let lineData = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let event = map(object) else {
                    continue
                }
                fileEvents.append(event)
            }

            events.append(contentsOf: fileEvents)
            if stopAfterFirstFile, !fileEvents.isEmpty {
                break
            }
        }

        return events
    }
}

private struct CodexRateLimitEvent {
    let timestamp: Date
    let primaryPercent: Double
    let primaryMinutes: Double
    let primaryResetDate: Date?
    let secondaryPercent: Double
    let secondaryMinutes: Double
    let secondaryResetDate: Date?
    let planType: String?
}

private let dateFormatters: [ISO8601DateFormatter] = {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return [withFraction, plain]
}()

private func parseDate(_ value: Any?) -> Date? {
    guard let string = value as? String else {
        return nil
    }
    for formatter in dateFormatters {
        if let date = formatter.date(from: string) {
            return date
        }
    }
    return nil
}

private func tokenCount(from usage: [String: Any]) -> Int {
    var total = 0
    for key in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
        if let value = usage[key] as? Int {
            total += value
        } else if let value = usage[key] as? Double {
            total += Int(value)
        }
    }
    return total
}

private func numeric(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? String {
        return Double(value)
    }
    return nil
}

private func resetDate(_ value: Any?) -> Date? {
    guard let seconds = numeric(value) else {
        return nil
    }
    return Date(timeIntervalSince1970: seconds)
}

private func resolvedRateLimitWindow(
    usedPercent: Double,
    resetDate: Date?,
    windowMinutes: Double,
    now: Date
) -> (usedPercent: Double, resetDate: Date?) {
    guard var resetDate else {
        return (usedPercent, nil)
    }

    if resetDate > now {
        return (usedPercent, resetDate)
    }

    guard windowMinutes > 0 else {
        return (0, nil)
    }

    let windowSeconds = windowMinutes * 60
    while resetDate <= now {
        resetDate = resetDate.addingTimeInterval(windowSeconds)
    }

    return (0, resetDate)
}

private func windowLabel(minutes: Double) -> String {
    if minutes >= 24 * 60 {
        let days = minutes / (24 * 60)
        return "\(formatNumber(days))d"
    }
    if minutes >= 60 {
        return "\(formatNumber(minutes / 60))h"
    }
    return "\(formatNumber(minutes))m"
}

private func shortWindowLabel(hours: Double) -> String {
    "\(formatNumber(hours))h"
}

private func longWindowLabel(days: Double) -> String {
    "\(formatNumber(days))d"
}

private func formatNumber(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.1f", value)
}

private func relativeAge(of date: Date, now: Date) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 90 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    let hours = Int(seconds / 3600)
    return "\(hours)h ago"
}

private func inferredTokens(from object: [String: Any]) -> Int {
    if let usage = object["usage"] as? [String: Any] {
        return tokenCount(from: usage)
    }

    if let content = object["content"] as? [[String: Any]] {
        let chars = content.compactMap { $0["text"] as? String }.joined(separator: "\n").count
        return max(1, chars / 4)
    }

    return 1
}
