import Foundation

/// Installs a per-user LaunchAgent so macOS keeps UsageMeter running: it starts
/// automatically at login and is relaunched within seconds if it ever exits for
/// any reason (crash, signature re-evaluation, an update mishap, a manual kill).
/// This is the idiomatic way for a menu-bar utility to stay alive and is the
/// safety net behind "don't let it die".
public enum LaunchAgentInstaller {
    public static let label = "io.github.PolymerTheory.UsageMeter"

    public static func plistURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(home: home).path)
    }

    /// Write (or refresh) the LaunchAgent plist pointing at `executablePath`
    /// and (re)load it so the change takes effect immediately.
    public static func install(
        executablePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let url = plistURL(home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,
            // Throttle relaunches so a genuinely broken build can't spin the CPU
            // by crash-looping faster than this interval.
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        reload(plistPath: url.path)
    }

    /// Reload the agent in the current GUI domain. Best-effort: a fresh install
    /// has nothing to bootout, and bootstrap is what actually starts it.
    private static func reload(plistPath: String) {
        let domain = "gui/\(getuid())"
        // Remove any existing instance first so bootstrap re-reads the plist.
        run(["bootout", "\(domain)/\(label)"])
        run(["bootstrap", domain, plistPath])
        // Ensure it is actually (re)started even if it was already loaded.
        run(["kickstart", "-k", "\(domain)/\(label)"])
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
