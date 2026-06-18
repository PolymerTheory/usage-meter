import Cocoa

struct ProbeState {
    let provider: String
    let state: String
    let event: String?
    let updatedAt: Date?
    let path: String

    var isBusy: Bool {
        state == "busy"
    }

    var statusText: String {
        guard let updatedAt else {
            return "no status file"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let age = formatter.localizedString(for: updatedAt, relativeTo: Date())
        if let event, !event.isEmpty {
            return "\(state) via \(event), \(age)"
        }
        return "\(state), \(age)"
    }
}

final class StatusStore {
    private let directory: URL
    private let codexLogReader = CodexAppLogReader()
    private let claudeFileReader = ClaudeFileActivityReader()

    init() {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageMeter/activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func state(provider: String) -> ProbeState {
        if provider == "codex", let codexState = codexLogReader.state() {
            return codexState
        }

        let url = directory.appendingPathComponent("\(provider).json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if provider == "claude", let fileState = claudeFileReader.state() {
                return fileState
            }
            return ProbeState(provider: provider, state: "idle", event: nil, updatedAt: nil, path: url.path)
        }

        let state = object["state"] as? String ?? "idle"
        let event = object["event"] as? String
        let timestamp = object["timestamp"] as? Double
        let updatedAt = timestamp.map { Date(timeIntervalSince1970: $0) }
        return ProbeState(provider: provider, state: state, event: event, updatedAt: updatedAt, path: url.path)
    }
}

final class CodexAppLogReader {
    private let database: URL
    private var idleCandidateSince: Date?
    private var lastObservedDone: TimeInterval = 0
    private var sawActiveTurn = false
    private let idleHysteresis: TimeInterval = 4
    private let unresolvedTurnTimeout: TimeInterval = 120

    init() {
        database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sqlite/logs_2.sqlite")
    }

    func state() -> ProbeState? {
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

        guard let output = runSQLite(sql: sql) else {
            return nil
        }

        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard parts.count == 3,
              let latestStarted = TimeInterval(parts[0]),
              let latestBusy = TimeInterval(parts[1]),
              let latestDone = TimeInterval(parts[2]) else {
            return nil
        }

        let newest = max(latestStarted, latestBusy, latestDone)
        guard newest > 0 else {
            return nil
        }

        let now = Date()
        let isBusy: Bool
        if latestBusy > latestDone,
           now.timeIntervalSince1970 - latestBusy <= unresolvedTurnTimeout {
            idleCandidateSince = nil
            lastObservedDone = latestDone
            sawActiveTurn = true
            isBusy = true
        } else if latestStarted > latestDone,
                  now.timeIntervalSince1970 - latestStarted <= unresolvedTurnTimeout {
            idleCandidateSince = nil
            lastObservedDone = latestDone
            sawActiveTurn = true
            isBusy = true
        } else if latestDone != lastObservedDone {
            lastObservedDone = latestDone
            guard sawActiveTurn else {
                idleCandidateSince = nil
                return ProbeState(
                    provider: "codex",
                    state: "idle",
                    event: "codex-app-log",
                    updatedAt: Date(timeIntervalSince1970: newest),
                    path: database.path
                )
            }
            idleCandidateSince = now
            sawActiveTurn = false
            isBusy = true
        } else if let idleCandidateSince,
                  now.timeIntervalSince(idleCandidateSince) < idleHysteresis {
            isBusy = true
        } else {
            isBusy = false
        }

        return ProbeState(
            provider: "codex",
            state: isBusy ? "busy" : "idle",
            event: "codex-app-log",
            updatedAt: Date(timeIntervalSince1970: newest),
            path: database.path
        )
    }

    private func runSQLite(sql: String) -> String? {
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

final class ClaudeFileActivityReader {
    private let roots: [URL]
    private let activeWindow: TimeInterval = 45

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots = [
            home.appendingPathComponent(".claude/tasks", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true)
        ]
    }

    func state() -> ProbeState? {
        guard let newest = newestModifiedFile() else {
            return nil
        }

        let age = Date().timeIntervalSince(newest.date)
        return ProbeState(
            provider: "claude",
            state: age <= activeWindow ? "busy" : "idle",
            event: "claude-file-mtime",
            updatedAt: newest.date,
            path: newest.url.path
        )
    }

    private func newestModifiedFile() -> (url: URL, date: Date)? {
        var newest: (url: URL, date: Date)?
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let date = values.contentModificationDate else {
                    continue
                }
                if newest == nil || date > newest!.date {
                    newest = (url, date)
                }
            }
        }

        return newest
    }
}

final class DotView: NSView {
    var state: ProbeState {
        didSet { needsDisplay = true }
    }

    init(state: ProbeState) {
        self.state = state
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 18, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color: NSColor = state.isBusy ? .systemGreen : .systemGray
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
    }
}

final class RowView: NSStackView {
    private let dot: DotView
    private let detail = NSTextField(labelWithString: "")

    init(title: String, state: ProbeState) {
        dot = DotView(state: state)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.widthAnchor.constraint(equalToConstant: 88).isActive = true

        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
        addArrangedSubview(dot)
        addArrangedSubview(label)
        addArrangedSubview(detail)
        update(state)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ state: ProbeState) {
        dot.state = state
        detail.stringValue = state.statusText
        detail.toolTip = state.path
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StatusStore()
    private var window: NSWindow!
    private var codexRow: RowView!
    private var claudeRow: RowView!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let codex = store.state(provider: "codex")
        let claude = store.state(provider: "claude")

        codexRow = RowView(title: "Codex", state: codex)
        claudeRow = RowView(title: "Claude", state: claude)

        let title = NSTextField(labelWithString: "Activity Probe")
        title.font = .systemFont(ofSize: 17, weight: .bold)

        let hint = NSTextField(labelWithString: "Green means busy. Codex uses desktop sqlite events; Claude uses hook status or recent Claude task/project writes.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        let stack = NSStackView(views: [title, codexRow, claudeRow, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Activity Probe"
        window.center()
        window.contentView = stack
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func refresh() {
        codexRow.update(store.state(provider: "codex"))
        claudeRow.update(store.state(provider: "claude"))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
