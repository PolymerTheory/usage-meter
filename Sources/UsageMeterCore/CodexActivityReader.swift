import Foundation

public final class CodexActivityReader: @unchecked Sendable {
    private let home: URL
    private let lock = NSLock()
    private var idleCandidateSince: Date?
    private var lastObservedDone: TimeInterval = 0
    private var sawActiveTurn = false
    private let idleHysteresis: TimeInterval

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        idleHysteresis: TimeInterval = 4
    ) {
        self.home = home
        self.idleHysteresis = idleHysteresis
    }

    public func isActive(now: Date = Date()) -> Bool? {
        lock.lock()
        defer { lock.unlock() }

        guard let eventTimes = latestEventTimes() else {
            return nil
        }

        let latestDone = max(eventTimes.completed, eventTimes.failed)
        guard eventTimes.userInput > 0 || latestDone > 0 else {
            return nil
        }

        if eventTimes.userInput > latestDone {
            idleCandidateSince = nil
            lastObservedDone = latestDone
            sawActiveTurn = true
            return true
        }

        if latestDone != lastObservedDone {
            lastObservedDone = latestDone
            guard sawActiveTurn else {
                idleCandidateSince = nil
                return false
            }
            idleCandidateSince = now
            sawActiveTurn = false
            return true
        }

        if let idleCandidateSince,
           now.timeIntervalSince(idleCandidateSince) < idleHysteresis {
            return true
        }

        return false
    }

    private func latestEventTimes() -> CodexActivityEventTimes? {
        let database = home.appendingPathComponent(".codex/sqlite/logs_2.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else {
            return nil
        }

        let sql = """
        select
          coalesce(max(case when feedback_log_body like '%codex.op="user_input"%' then ts end), 0),
          coalesce(max(case when feedback_log_body like '%app-server event: turn/completed%' then ts end), 0),
          coalesce(max(case when feedback_log_body like '%app-server event: turn/failed%' then ts end), 0)
        from (
          select ts, feedback_log_body
          from logs
          order by id desc
          limit 5000
        );
        """

        guard let output = runSQLite(database: database, sql: sql) else {
            return nil
        }

        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard fields.count == 3,
              let userInput = TimeInterval(fields[0]),
              let completed = TimeInterval(fields[1]),
              let failed = TimeInterval(fields[2]) else {
            return nil
        }

        return CodexActivityEventTimes(userInput: userInput, completed: completed, failed: failed)
    }

    private func runSQLite(database: URL, sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

private struct CodexActivityEventTimes {
    let userInput: TimeInterval
    let completed: TimeInterval
    let failed: TimeInterval
}
