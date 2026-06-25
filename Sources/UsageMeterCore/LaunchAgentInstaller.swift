import Foundation

/// Installs a per-user LaunchAgent so macOS keeps UsageMeter running: it starts
/// automatically at login and is relaunched if it ever exits abnormally
/// (crash, signature re-evaluation kill, a manual kill). This is the idiomatic
/// way for a menu-bar utility to stay alive and is the safety net behind
/// "don't let it die".
///
/// The app self-installs this on first launch (see `ensureRunning`), so it
/// works no matter how the app arrived on a machine — manual download, a
/// Sparkle in-app update, or the install script — not only when the install
/// script was run.
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

    /// True when the currently running process was started by launchd from this
    /// LaunchAgent (launchd sets XPC_SERVICE_NAME to the job label). Used to
    /// tell the managed instance apart from one launched by Sparkle/Finder.
    public static func isManagedInstance() -> Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    /// Full (re)install used by the `--install-launch-agent` command and the
    /// install script: write the plist and force a clean reload + restart.
    public static func install(
        executablePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        try writePlist(executablePath: executablePath, home: home)
        let domain = "gui/\(getuid())"
        run(["bootout", "\(domain)/\(label)"])
        run(["bootstrap", domain, plistURL(home: home).path])
        run(["kickstart", "-k", "\(domain)/\(label)"])
    }

    /// Idempotent self-heal for the app launch path: make sure the LaunchAgent
    /// is installed, loaded, and running, without disturbing an already-healthy
    /// managed instance. Safe to call on every non-managed launch.
    ///
    /// Typical cases:
    /// - First launch on a new machine (no plist): writes it, bootstraps, runs.
    /// - After a Sparkle update relaunches the new binary: the job is loaded but
    ///   not running, so `kickstart` starts the new binary as a managed instance.
    /// - Launched while a managed instance is already running: `kickstart`
    ///   without `-k` is a no-op, so nothing is disturbed.
    public static func ensureRunning(
        executablePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"

        let changed = (try? writePlist(executablePath: executablePath, home: home)) ?? false

        if !isLoaded(service: service) {
            run(["bootstrap", domain, plistURL(home: home).path])
        } else if changed {
            // Program path changed (e.g. installed to a new location): reload so
            // launchd picks up the new ProgramArguments.
            run(["bootout", service])
            run(["bootstrap", domain, plistURL(home: home).path])
        }

        // Start it if it isn't already running; no-op if it is.
        run(["kickstart", service])
    }

    // MARK: - Plist

    /// Writes the plist only when it is missing or differs, so repeated launches
    /// don't churn the file. Returns whether the on-disk content changed.
    @discardableResult
    private static func writePlist(
        executablePath: String,
        home: URL
    ) throws -> Bool {
        let url = plistURL(home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            // Restart on abnormal exit (crash / kill / signature termination)
            // but NOT on a clean exit. A clean exit is what Sparkle triggers
            // when it quits the app to swap in an update, so this lets the
            // update proceed instead of launchd racing to relaunch mid-swap.
            "KeepAlive": ["SuccessfulExit": false],
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

        if let existing = try? Data(contentsOf: url), existing == data {
            return false
        }
        try data.write(to: url, options: .atomic)
        return true
    }

    // MARK: - launchctl

    private static func isLoaded(service: String) -> Bool {
        run(["print", service]) == 0
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
