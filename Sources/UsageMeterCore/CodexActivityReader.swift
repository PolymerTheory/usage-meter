import Foundation

public final class CodexActivityReader: @unchecked Sendable {
    private let home: URL
    private let lock = NSLock()
    private var idleCandidateSince: Date?
    private var lastObservedDone: TimeInterval = 0
    private var sawActiveTurn = false
    private let idleHysteresis: TimeInterval
    private let unresolvedTurnTimeout: TimeInterval

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        idleHysteresis: TimeInterval = 4,
        unresolvedTurnTimeout: TimeInterval = 120
    ) {
        self.home = home
        self.idleHysteresis = idleHysteresis
        self.unresolvedTurnTimeout = unresolvedTurnTimeout
    }

    public func isActive(now: Date = Date()) -> Bool? {
        lock.lock()
        defer { lock.unlock() }

        guard let eventTimes = latestEventTimes() else {
            return nil
        }

        guard eventTimes.started > 0 || eventTimes.busy > 0 || eventTimes.done > 0 else {
            return nil
        }

        if eventTimes.busy > eventTimes.done,
           now.timeIntervalSince1970 - eventTimes.busy <= unresolvedTurnTimeout {
            idleCandidateSince = nil
            lastObservedDone = eventTimes.done
            sawActiveTurn = true
            return true
        }

        if eventTimes.started > eventTimes.done,
           now.timeIntervalSince1970 - eventTimes.started <= unresolvedTurnTimeout {
            idleCandidateSince = nil
            lastObservedDone = eventTimes.done
            sawActiveTurn = true
            return true
        }

        if eventTimes.done != lastObservedDone {
            lastObservedDone = eventTimes.done
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
          coalesce(max(case
            when target = 'codex_core::session::turn'
             and feedback_log_body like '%op.dispatch.user_input%'
            then ts end), 0),
          coalesce(max(case
            when target = 'codex_app_server::outgoing_message'
             and (
               feedback_log_body like 'app-server event: item/started%'
               or feedback_log_body like 'app-server event: item/agentMessage/delta%'
               or feedback_log_body like 'app-server event: item/commandExecution/outputDelta%'
               or feedback_log_body like 'app-server event: item/autoApprovalReview/started%'
             )
            then ts end), 0),
          coalesce(max(case
            when target = 'codex_app_server::outgoing_message'
             and (
               feedback_log_body like 'app-server event: turn/completed%'
               or feedback_log_body like 'app-server event: turn/failed%'
               or feedback_log_body like 'app-server event: item/completed%'
               or feedback_log_body like 'app-server event: item/autoApprovalReview/completed%'
             )
            then ts end), 0)
        from (
          select ts, target, feedback_log_body
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
              let started = TimeInterval(fields[0]),
              let busy = TimeInterval(fields[1]),
              let done = TimeInterval(fields[2]) else {
            return nil
        }

        return CodexActivityEventTimes(started: started, busy: busy, done: done)
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
    let started: TimeInterval
    let busy: TimeInterval
    let done: TimeInterval
}
