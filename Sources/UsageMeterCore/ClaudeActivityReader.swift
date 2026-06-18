import Foundation

public final class ClaudeActivityReader: @unchecked Sendable {
    public static let relativeStatusPath = "Library/Application Support/UsageMeter/activity/claude.json"

    private let home: URL
    private let maximumBusyAge: TimeInterval

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        maximumBusyAge: TimeInterval = 15 * 60
    ) {
        self.home = home
        self.maximumBusyAge = maximumBusyAge
    }

    public func isActive(now: Date = Date()) -> Bool? {
        let url = home.appendingPathComponent(Self.relativeStatusPath)
        guard let data = try? Data(contentsOf: url),
              let status = try? JSONDecoder().decode(ActivityStatus.self, from: data) else {
            return nil
        }

        guard status.state == "busy" else {
            return false
        }

        return now.timeIntervalSince1970 - status.timestamp <= maximumBusyAge
    }
}

public enum ActivityStatusWriter {
    public static func write(
        provider: UsageProvider,
        state: String,
        event: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) throws {
        guard state == "busy" || state == "idle" else {
            throw ActivityStatusError.invalidState
        }

        let url = home.appendingPathComponent(
            "Library/Application Support/UsageMeter/activity/\(provider.rawValue.lowercased()).json"
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let status = ActivityStatus(
            provider: provider.rawValue.lowercased(),
            state: state,
            event: event,
            timestamp: now.timeIntervalSince1970
        )
        let data = try JSONEncoder().encode(status)
        try data.write(to: url, options: .atomic)
    }
}

public enum ClaudeHookInstaller {
    public static func isInstalled(
        executablePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard let root = loadSettings(home: home),
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }

        return hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                return handlers.contains { handler in
                    handler["command"] as? String == executablePath
                        && (handler["args"] as? [String])?.prefix(2) == ["--activity-hook", "claude"]
                }
            }
        }
    }

    public static func install(
        executablePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var root = loadSettings(home: home) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for definition in hookDefinitions {
            var groups = hooks[definition.event] as? [[String: Any]] ?? []
            groups = groups.compactMap { removingUsageMeterHandlers(from: $0) }

            var group: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": executablePath,
                    "args": ["--activity-hook", "claude", definition.state, definition.event],
                    "timeout": 5
                ]]
            ]
            if let matcher = definition.matcher {
                group["matcher"] = matcher
            }
            groups.append(group)
            hooks[definition.event] = groups
        }

        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static let hookDefinitions: [(event: String, state: String, matcher: String?)] = [
        ("UserPromptSubmit", "busy", nil),
        ("PreToolUse", "busy", ".*"),
        ("PostToolUse", "busy", ".*"),
        ("PostToolUseFailure", "busy", ".*"),
        ("Stop", "idle", nil),
        ("StopFailure", "idle", nil),
        ("PermissionRequest", "idle", ".*"),
        ("Notification", "idle", "permission_prompt|idle_prompt"),
        ("SessionEnd", "idle", ".*")
    ]

    private static func loadSettings(home: URL) -> [String: Any]? {
        let url = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func removingUsageMeterHandlers(from group: [String: Any]) -> [String: Any]? {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
        let filtered = handlers.filter { handler in
            guard let args = handler["args"] as? [String] else { return true }
            return args.prefix(2) != ["--activity-hook", "claude"]
        }
        guard !filtered.isEmpty else { return nil }
        var updated = group
        updated["hooks"] = filtered
        return updated
    }
}

private struct ActivityStatus: Codable {
    let provider: String
    let state: String
    let event: String
    let timestamp: TimeInterval
}

private enum ActivityStatusError: Error {
    case invalidState
}
