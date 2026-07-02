import Foundation
import XCTest
@testable import UsageMeterCore

final class LogUsageReaderTests: XCTestCase {
    func testClaudeUsageTokensAreSummed() throws {
        let root = try temporaryLogRoot()
        let log = root.appendingPathComponent("session.jsonl")
        let line = #"{"timestamp":"2026-06-01T10:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":25,"cache_read_input_tokens":10}}}"#
        try line.write(to: log, atomically: true, encoding: .utf8)

        let events = LogUsageReader().readClaudeEvents(root: root)

        XCTAssertEqual(events, [UsageEvent(timestamp: iso("2026-06-01T10:00:00.000Z"), tokens: 185)])
    }

    func testSummaryUsesFiveHourAndSevenDayWindows() throws {
        let reader = LogUsageReader()
        let now = iso("2026-06-02T12:00:00.000Z")
        let events = [
            UsageEvent(timestamp: iso("2026-06-02T11:00:00.000Z"), tokens: 10),
            UsageEvent(timestamp: iso("2026-06-01T11:00:00.000Z"), tokens: 20),
            UsageEvent(timestamp: iso("2026-05-20T11:00:00.000Z"), tokens: 30)
        ]

        let usage = reader.summarize(
            provider: .codex,
            events: events,
            now: now,
            shortLimit: 100,
            longLimit: 100,
            source: "test"
        )

        XCTAssertEqual(usage.shortWindow.usedUnits, 10)
        XCTAssertEqual(usage.longWindow.usedUnits, 30)
        XCTAssertEqual(usage.shortWindow.fractionUsed, 0.1)
        XCTAssertEqual(usage.longWindow.fractionUsed, 0.3)
    }

    func testCodexRateLimitSnapshotIsPreferredWhenPresent() throws {
        let root = try temporaryLogRoot()
        let log = root.appendingPathComponent("session.jsonl")
        let line = #"{"timestamp":"2026-06-01T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}},"rate_limits":{"primary":{"used_percent":17.5,"window_minutes":300,"resets_at":1780318800},"secondary":{"used_percent":6,"window_minutes":10080,"resets_at":1780837200},"plan_type":"pro"}}}"#
        try line.write(to: log, atomically: true, encoding: .utf8)

        let usage = try XCTUnwrap(
            LogUsageReader().readLatestCodexRateLimit(
                root: root,
                now: iso("2026-06-01T11:00:00.000Z")
            )
        )

        XCTAssertEqual(usage.provider, .codex)
        XCTAssertEqual(usage.shortWindow.label, "5h")
        XCTAssertEqual(usage.shortWindow.displayPercent, 17.5)
        XCTAssertEqual(usage.shortWindow.fractionUsed, 0.175)
        XCTAssertFalse(usage.shortWindow.isEstimated)
        XCTAssertEqual(usage.longWindow.label, "7d")
        XCTAssertEqual(usage.longWindow.displayPercent, 6)
    }

    func testCodexRateLimitPastResetDatesRollOverToZeroUsage() throws {
        let root = try temporaryLogRoot()
        let log = root.appendingPathComponent("session.jsonl")
        let expiredReset = Int(isoPlain("2026-06-02T11:00:00Z").timeIntervalSince1970)
        let futureReset = Int(isoPlain("2026-06-07T12:00:00Z").timeIntervalSince1970)
        let line = #"{"timestamp":"2026-06-02T10:00:00.000Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":56,"window_minutes":300,"resets_at":\#(expiredReset)},"secondary":{"used_percent":36,"window_minutes":10080,"resets_at":\#(futureReset)},"plan_type":"plus"}}}"#
        try line.write(to: log, atomically: true, encoding: .utf8)

        let usage = try XCTUnwrap(
            LogUsageReader().readLatestCodexRateLimit(
                root: root,
                now: iso("2026-06-02T12:00:00.000Z")
            )
        )

        XCTAssertEqual(usage.shortWindow.displayPercent, 0)
        XCTAssertEqual(usage.shortWindow.resetDate, isoPlain("2026-06-02T16:00:00Z"))
        XCTAssertEqual(usage.longWindow.displayPercent, 36)
        XCTAssertEqual(usage.longWindow.resetDate, isoPlain("2026-06-07T12:00:00Z"))
    }

    func testCodexRateLimitFreshSnapshotIsNotStale() throws {
        let root = try temporaryLogRoot()
        let log = root.appendingPathComponent("session.jsonl")
        let futureShort = Int(isoPlain("2026-06-02T16:00:00Z").timeIntervalSince1970)
        let futureLong = Int(isoPlain("2026-06-09T12:00:00Z").timeIntervalSince1970)
        let line = #"{"timestamp":"2026-06-02T11:58:00.000Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_at":\#(futureShort)},"secondary":{"used_percent":80,"window_minutes":10080,"resets_at":\#(futureLong)},"plan_type":"plus"}}}"#
        try line.write(to: log, atomically: true, encoding: .utf8)

        // Snapshot is 2 minutes old — well within the freshness window.
        let usage = try XCTUnwrap(
            LogUsageReader().readLatestCodexRateLimit(root: root, now: iso("2026-06-02T12:00:00.000Z"))
        )

        XCTAssertFalse(usage.shortWindow.isStale)
        XCTAssertFalse(usage.longWindow.isStale)
    }

    func testCodexRateLimitOldSnapshotMarksUnresetWindowStale() throws {
        let root = try temporaryLogRoot()
        let log = root.appendingPathComponent("session.jsonl")
        let expiredShort = Int(isoPlain("2026-06-02T08:00:00Z").timeIntervalSince1970)
        let futureLong = Int(isoPlain("2026-06-09T12:00:00Z").timeIntervalSince1970)
        let line = #"{"timestamp":"2026-06-02T06:00:00.000Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_at":\#(expiredShort)},"secondary":{"used_percent":80,"window_minutes":10080,"resets_at":\#(futureLong)},"plan_type":"plus"}}}"#
        try line.write(to: log, atomically: true, encoding: .utf8)

        // Snapshot is 6 hours old: the 5h window has reset (accurate 0%, not
        // stale), but the 7d window still shows the frozen 80% and is stale.
        let usage = try XCTUnwrap(
            LogUsageReader().readLatestCodexRateLimit(root: root, now: iso("2026-06-02T12:00:00.000Z"))
        )

        XCTAssertEqual(usage.shortWindow.displayPercent, 0)
        XCTAssertFalse(usage.shortWindow.isStale)
        XCTAssertEqual(usage.longWindow.displayPercent, 80)
        XCTAssertTrue(usage.longWindow.isStale)
    }

    func testCodexAPIUsageParsesLiveWindows() throws {
        let data = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "primary_window": {
              "used_percent": 22,
              "limit_window_seconds": 18000,
              "reset_at": 1782249854
            },
            "secondary_window": {
              "used_percent": 98,
              "limit_window_seconds": 604800,
              "reset_at": 1782383540
            }
          }
        }
        """.data(using: .utf8)!

        let usage = try XCTUnwrap(
            CodexAPIUsageReader.providerUsage(
                from: data,
                now: iso("2026-06-02T12:00:00.000Z"),
                stale: false
            )
        )

        XCTAssertEqual(usage.provider, .codex)
        XCTAssertEqual(usage.shortWindow.label, "5h")
        XCTAssertEqual(usage.shortWindow.displayPercent, 22)
        XCTAssertFalse(usage.shortWindow.isStale)
        XCTAssertEqual(usage.longWindow.label, "7d")
        XCTAssertEqual(usage.longWindow.displayPercent, 98)
        XCTAssertEqual(usage.source, "chatgpt.com usage API")
    }

    func testCodexAPIUsageMarksCachedResponseStale() throws {
        let data = """
        {"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1782249854},
        "secondary_window":{"used_percent":50,"limit_window_seconds":604800,"reset_at":1782383540}}}
        """.data(using: .utf8)!

        let usage = try XCTUnwrap(
            CodexAPIUsageReader.providerUsage(from: data, now: iso("2026-06-02T12:00:00.000Z"), stale: true)
        )

        XCTAssertTrue(usage.shortWindow.isStale)
        XCTAssertTrue(usage.longWindow.isStale)
    }

    func testClaudeAPIUsageResponseParsesQuotaWindows() throws {
        let data = """
        {
          "five_hour": {
            "utilization": 42.5,
            "resets_at": "2026-06-02T17:00:00Z"
          },
          "seven_day": {
            "utilization": 11,
            "resets_at": "2026-06-08T17:00:00Z"
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = try XCTUnwrap(
            ClaudeAPIUsageReader.providerUsage(
                from: response,
                lastUpdated: iso("2026-06-02T12:00:00.000Z")
            )
        )

        XCTAssertEqual(usage.provider, .claude)
        XCTAssertEqual(usage.shortWindow.label, "5h")
        XCTAssertEqual(usage.shortWindow.displayPercent, 42.5)
        XCTAssertEqual(usage.shortWindow.resetDate, isoPlain("2026-06-02T17:00:00Z"))
        XCTAssertFalse(usage.shortWindow.isEstimated)
        XCTAssertEqual(usage.longWindow.label, "7d")
        XCTAssertEqual(usage.longWindow.displayPercent, 11)
        XCTAssertEqual(usage.source, "Anthropic OAuth usage API")
    }

    func testClaudeAPIUsageResponseMergesModelSpecificSevenDayWindows() throws {
        let data = """
        {
          "five_hour": {
            "utilization": 12,
            "resets_at": "2026-06-02T17:00:00Z"
          },
          "seven_day_sonnet": {
            "utilization": 33,
            "resets_at": "2026-06-08T19:00:00Z"
          },
          "seven_day_opus": {
            "utilization": 71,
            "resets_at": "2026-06-08T18:00:00Z"
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = try XCTUnwrap(
            ClaudeAPIUsageReader.providerUsage(
                from: response,
                lastUpdated: iso("2026-06-02T12:00:00.000Z")
            )
        )

        XCTAssertEqual(usage.longWindow.displayPercent, 71)
        XCTAssertEqual(usage.longWindow.resetDate, isoPlain("2026-06-08T18:00:00Z"))
    }

    func testClaudeAPIUsageCanMarkCachedResponseStale() throws {
        let data = """
        {
          "five_hour": {
            "utilization": 42.5,
            "resets_at": "2026-06-02T17:00:00Z"
          },
          "seven_day": {
            "utilization": 11,
            "resets_at": "2026-06-08T17:00:00Z"
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = try XCTUnwrap(
            ClaudeAPIUsageReader.providerUsage(
                from: response,
                lastUpdated: iso("2026-06-02T12:00:00.000Z"),
                now: iso("2026-06-02T12:00:00.000Z"),
                stale: true
            )
        )

        XCTAssertTrue(usage.shortWindow.isStale)
        XCTAssertTrue(usage.longWindow.isStale)
    }

    func testClaudeAPIUsageMergesPerModelWindowEvenWhenBaseSevenDayPresent() throws {
        // Real Anthropic responses include the aggregate `seven_day` window AND
        // per-model windows at the same time. The binding limit (here Opus at
        // 88%) must win over the low aggregate, and unrelated feature buckets
        // must be ignored.
        let data = """
        {
          "five_hour": { "utilization": 6.0, "resets_at": "2026-06-04T18:10:00.729501+00:00" },
          "seven_day": { "utilization": 4.0, "resets_at": "2026-06-08T18:00:00Z" },
          "seven_day_opus": { "utilization": 88.0, "resets_at": "2026-06-09T10:00:00Z" },
          "seven_day_sonnet": { "utilization": 20.0, "resets_at": "2026-06-09T11:00:00Z" },
          "seven_day_cowork": { "utilization": 99.0, "resets_at": "2026-06-09T12:00:00Z" },
          "extra_usage": { "is_enabled": false, "utilization": null }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = try XCTUnwrap(
            ClaudeAPIUsageReader.providerUsage(
                from: response,
                lastUpdated: iso("2026-06-04T12:00:00.000Z")
            )
        )

        XCTAssertEqual(usage.shortWindow.displayPercent, 6.0)
        XCTAssertEqual(usage.longWindow.displayPercent, 88.0)
        XCTAssertEqual(usage.longWindow.resetDate, isoPlain("2026-06-09T10:00:00Z"))
    }

    func testConfigLoaderReadsUserLimits() throws {
        let root = try temporaryLogRoot()
        let configURL = root.appendingPathComponent(".usage-meter.json")
        let config = """
        {
          "codex": {
            "shortWindowHours": 6,
            "longWindowDays": 7,
            "shortLimitTokens": 111,
            "longLimitTokens": 222
          },
          "claude": {
            "shortWindowHours": 6,
            "longWindowDays": 7,
            "shortLimitTokens": 333,
            "longLimitTokens": 444
          }
        }
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let loaded = UsageConfigLoader().load(home: root)

        XCTAssertEqual(loaded.codex.shortWindowHours, 6)
        XCTAssertEqual(loaded.codex.shortLimitTokens, 111)
        XCTAssertEqual(loaded.claude.shortLimitTokens, 333)
    }

    func testCodexActivityReaderUsesDesktopAppTurnEvents() throws {
        let home = try temporaryLogRoot()
        let db = try createCodexLogDatabase(home: home)
        try insertLog(db: db, ts: 100, target: "codex_core::session::turn", body: #"op.dispatch.user_input"#)
        try insertLog(db: db, ts: 101, target: "codex_app_server::outgoing_message", body: "app-server event: item/started targeted_connections=1")
        try insertLog(db: db, ts: 90, target: "codex_app_server::outgoing_message", body: "app-server event: turn/completed targeted_connections=1")

        let reader = CodexActivityReader(home: home)

        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 101)), true)
    }

    func testCodexActivityReaderKeepsIdleGraceAfterCompletion() throws {
        let home = try temporaryLogRoot()
        let db = try createCodexLogDatabase(home: home)
        try insertLog(db: db, ts: 100, target: "codex_core::session::turn", body: #"op.dispatch.user_input"#)
        try insertLog(db: db, ts: 101, target: "codex_app_server::outgoing_message", body: "app-server event: item/started targeted_connections=1")

        let reader = CodexActivityReader(home: home, idleHysteresis: 4)
        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 101)), true)

        try insertLog(db: db, ts: 102, target: "codex_app_server::outgoing_message", body: "app-server event: turn/completed targeted_connections=1")
        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 102)), true)
        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 105)), true)
        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 107)), false)
    }

    func testCodexActivityReaderDoesNotTreatOldCompletionAsActiveOnStartup() throws {
        let home = try temporaryLogRoot()
        let db = try createCodexLogDatabase(home: home)
        try insertLog(db: db, ts: 100, target: "codex_core::session::turn", body: #"op.dispatch.user_input"#)
        try insertLog(db: db, ts: 101, target: "codex_app_server::outgoing_message", body: "app-server event: turn/completed targeted_connections=1")

        let reader = CodexActivityReader(home: home, idleHysteresis: 4)

        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 500)), false)
    }

    func testCodexActivityReaderStopsStaleUnresolvedTurns() throws {
        let home = try temporaryLogRoot()
        let db = try createCodexLogDatabase(home: home)
        try insertLog(db: db, ts: 100, target: "codex_core::session::turn", body: #"op.dispatch.user_input"#)
        try insertLog(db: db, ts: 101, target: "codex_app_server::outgoing_message", body: "app-server event: item/started targeted_connections=1")

        let reader = CodexActivityReader(home: home, unresolvedTurnTimeout: 120)

        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 150)), true)
        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 300)), false)
    }

    func testCodexActivityReaderIgnoresTelemetryTextOnOtherTargets() throws {
        let home = try temporaryLogRoot()
        let db = try createCodexLogDatabase(home: home)
        try insertLog(db: db, ts: 100, target: "log", body: #"diagnostic text codex.op="user_input" app-server event: item/started"#)
        try insertLog(db: db, ts: 101, target: "codex_otel.log_only", body: "app-server event: item/commandExecution/outputDelta")

        let reader = CodexActivityReader(home: home)

        XCTAssertNil(reader.isActive(now: Date(timeIntervalSince1970: 102)))
    }

    func testCodexActivityReaderUsesModernRootDatabasePulse() throws {
        let home = try temporaryLogRoot()
        let db = try createCodexLogDatabase(home: home, modern: true)
        try insertLog(
            db: db,
            ts: 100,
            target: "codex_api::endpoint::responses_websocket",
            body: #"session_loop:submission_dispatch{otel.name="op.dispatch.user_input"}"#
        )

        let reader = CodexActivityReader(home: home, activityPulseWindow: 12)

        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 105)), true)
        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 113)), false)
    }

    func testCodexDatabaseRateLimitParsesModernMessage() throws {
        let home = try temporaryLogRoot()
        let db = try createCodexLogDatabase(home: home, modern: true)
        let message = #"request: websocket event: {"type":"codex.rate_limits","plan_type":"plus","rate_limits":{"primary":{"used_percent":49,"window_minutes":300,"reset_at":500},"secondary":{"used_percent":12,"window_minutes":10080,"reset_at":1000}}}"#
        try insertLog(db: db, ts: 100, target: "codex_api::endpoint::responses_websocket", body: message)

        let usage = try XCTUnwrap(
            LogUsageReader().readLatestCodexDatabaseRateLimit(
                home: home,
                now: Date(timeIntervalSince1970: 200)
            )
        )

        XCTAssertEqual(usage.shortWindow.displayPercent, 49)
        XCTAssertEqual(usage.longWindow.displayPercent, 12)
        XCTAssertEqual(usage.shortWindow.resetDate, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(usage.source, "~/.codex/logs_2.sqlite")
    }

    func testClaudeActivityReaderUsesHookStatusAndExpiresStaleBusyState() throws {
        let home = try temporaryLogRoot()
        try ActivityStatusWriter.write(
            provider: .claude,
            state: "busy",
            event: "UserPromptSubmit",
            home: home,
            now: Date(timeIntervalSince1970: 100)
        )

        let reader = ClaudeActivityReader(home: home, maximumBusyAge: 60)

        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 120)), true)
        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 200)), false)

        try ActivityStatusWriter.write(
            provider: .claude,
            state: "idle",
            event: "Stop",
            home: home,
            now: Date(timeIntervalSince1970: 201)
        )
        XCTAssertEqual(reader.isActive(now: Date(timeIntervalSince1970: 202)), false)
    }

    func testClaudeHookInstallerPreservesExistingSettingsAndHooks() throws {
        let home = try temporaryLogRoot()
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = """
        {
          "model": "claude-test",
          "hooks": {
            "Stop": [
              {"hooks": [{"type": "command", "command": "/tmp/existing-hook"}]}
            ]
          }
        }
        """
        try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

        try ClaudeHookInstaller.install(executablePath: "/Applications/UsageMeter.app/Contents/MacOS/UsageMeter", home: home)

        let data = try Data(contentsOf: settingsURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "claude-test")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopGroups.count, 2)
        XCTAssertTrue(
            ClaudeHookInstaller.isInstalled(
                executablePath: "/Applications/UsageMeter.app/Contents/MacOS/UsageMeter",
                home: home
            )
        )
    }

    private func temporaryLogRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createCodexLogDatabase(home: URL, modern: Bool = false) throws -> URL {
        let relativePath = modern ? ".codex" : ".codex/sqlite"
        let dir = home.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("logs_2.sqlite")
        try runSQLite(db: db, sql: """
        create table logs (
          id integer primary key,
          ts integer not null,
          target text not null default 'log',
          feedback_log_body text
        );
        """)
        return db
    }

    private func insertLog(db: URL, ts: Int, target: String = "log", body: String) throws {
        let escapedTarget = target.replacingOccurrences(of: "'", with: "''")
        let escaped = body.replacingOccurrences(of: "'", with: "''")
        try runSQLite(db: db, sql: "insert into logs (ts, target, feedback_log_body) values (\(ts), '\(escapedTarget)', '\(escaped)');")
    }

    private func runSQLite(db: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, sql]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func iso(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }

    private func isoPlain(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
