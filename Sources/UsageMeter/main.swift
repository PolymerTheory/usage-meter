import AppKit
import SwiftUI
import UsageMeterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = UsageViewModel()
    /// Global mouse-down monitor installed while the popover is open so that
    /// clicking anywhere outside it dismisses it. (.transient behavior is
    /// unreliable for accessory-policy apps that never become the active app.)
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchDiagnostics.write("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton(with: .empty)

        popover.behavior = .applicationDefined   // we manage dismissal manually
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 390)
        popover.contentViewController = NSHostingController(rootView: UsagePopoverView(model: model))

        model.onSnapshot = { [weak self] snapshot in
            self?.configureStatusButton(with: snapshot)
        }
        model.refreshQuota()

        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshQuota()
            }
        }

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshActivity()
            }
        }
    }

    private func configureStatusButton(with snapshot: UsageSnapshot) {
        guard let button = statusItem.button else {
            LaunchDiagnostics.write("status item has no button")
            return
        }

        button.target = self
        button.action = #selector(togglePopover)
        button.image = MeterIconRenderer.image(snapshot: snapshot)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "UsageMeter: Codex and Claude quota"
        statusItem.length = 28
        LaunchDiagnostics.write("configured status button title=\(button.title) frame=\(button.frame)")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            closePopover()
        } else {
            model.refreshQuota()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Delivered on the main thread; close only if still shown.
            guard let self, self.popover.isShown else { return }
            self.closePopover()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // NSPopoverDelegate: clean up the monitor if the popover closes for any
    // other reason (e.g. Escape key, programmatic close).
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.removeOutsideClickMonitor() }
    }
}

enum LaunchDiagnostics {
    static func write(_ message: String) {
        let url = URL(fileURLWithPath: "/tmp/UsageMeter-launch.log")
        let line = "\(Date()) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

@main
enum UsageMeterMain {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    var onSnapshot: ((UsageSnapshot) -> Void)?
    private let monitor = UsageMonitor()

    func refreshQuota() {
        Task {
            let monitor = self.monitor
            let snapshot = await Task.detached(priority: .utility) {
                monitor.snapshot()
            }.value
            self.snapshot = snapshot
            self.onSnapshot?(snapshot)
        }
    }

    func refreshActivity() {
        guard !snapshot.providers.isEmpty else { return }
        Task {
            let monitor = self.monitor
            let states = await Task.detached(priority: .utility) {
                monitor.activityStates()
            }.value
            let updatedProviders = self.snapshot.providers.map { provider in
                ProviderUsage(
                    provider: provider.provider,
                    shortWindow: provider.shortWindow,
                    longWindow: provider.longWindow,
                    detail: provider.detail,
                    source: provider.source,
                    lastUpdated: provider.lastUpdated,
                    isActive: states[provider.provider] ?? provider.isActive
                )
            }
            let updatedSnapshot = UsageSnapshot(providers: updatedProviders, generatedAt: self.snapshot.generatedAt)
            self.snapshot = updatedSnapshot
            self.onSnapshot?(updatedSnapshot)
        }
    }
}

struct UsagePopoverView: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI Usage")
                    .font(.headline)
                Spacer()
                Button(action: model.refreshQuota) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            ForEach(model.snapshot.providers, id: \.provider.rawValue) { provider in
                ProviderView(provider: provider)
            }

            Text("Codex uses logged rate-limit snapshots when available. Claude uses Anthropic OAuth usage data when available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 380, height: 390)
    }
}

struct ProviderView: View {
    let provider: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.provider.rawValue)
                    .font(.subheadline.weight(.semibold))
                if provider.isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Text(provider.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if provider.isUnavailable {
                UnavailableProviderView(provider: provider)
            } else {
                WindowRow(window: provider.shortWindow)
                WindowRow(window: provider.longWindow)
            }

            HStack(spacing: 8) {
                Text(provider.detail)
                Spacer(minLength: 0)
                // Give "Updated" priority so it never truncates; detail gets
                // whatever space remains and truncates gracefully if needed.
                Text("Updated \(relativeDate(provider.lastUpdated))")
                    .fixedSize()
                    .layoutPriority(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct UnavailableProviderView: View {
    let provider: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Open Claude Settings > Usage for the current exact quota.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// A simple horizontal progress bar drawn with explicit colors, bypassing
/// the unreliable `.tint()` modifier on macOS ProgressView.
struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: max(0, geo.size.width * CGFloat(min(fraction, 1.0))))
            }
        }
        .frame(height: 6)
    }
}

struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(window.label)
                    .frame(width: 32, alignment: .leading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                UsageBar(fraction: window.fractionUsed, color: color)
                Text(percentLabel)
                    .frame(width: 76, alignment: .trailing)
                    .font(.caption.monospacedDigit())
            }
            HStack {
                Text(unitLabel)
                Spacer()
                Text(resetLabel)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var percentLabel: String {
        if window.unitName == "unavailable" {
            return "n/a"
        }
        let suffix = window.isEstimated ? " est" : ""
        return "\(formatPercent(window.displayPercent))%\(suffix)"
    }

    private var unitLabel: String {
        if window.unitName == "unavailable" {
            return "quota unavailable"
        }
        if window.unitName == "quota" {
            return "quota snapshot"
        }
        return "\(formatCount(window.usedUnits)) / \(formatCount(window.limitUnits)) \(window.unitName)"
    }

    private var resetLabel: String {
        guard let resetDate = window.resetDate else {
            return "reset unknown"
        }
        let now = Date()
        let seconds = resetDate.timeIntervalSince(now)
        guard seconds > 0 else { return "resetting…" }

        // Compact countdown: "47m", "1h 57m", "6d 2h"
        let totalMinutes = Int(seconds / 60)
        let hours        = Int(seconds / 3600)
        let days         = hours / 24
        let countdown: String
        if days >= 1 {
            countdown = "\(days)d \(hours - days * 24)h"
        } else if hours >= 1 {
            countdown = "\(hours)h \(totalMinutes - hours * 60)m"
        } else {
            countdown = "\(totalMinutes)m"
        }

        // Absolute clock time, plus day name when the reset is on a different day
        let timeStr = Self.resetTimeFormatter.string(from: resetDate)
        if Calendar.current.isDateInToday(resetDate) {
            return "resets \(timeStr) (\(countdown))"
        } else {
            let dayStr = Self.resetDayFormatter.string(from: resetDate)
            return "resets \(dayStr) \(timeStr) (\(countdown))"
        }
    }

    // Formatters are reused across redraws — DateFormatter init is expensive.
    private static let resetTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"   // "9:05" not "09:05"
        return f
    }()
    private static let resetDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"    // "Mon", "Fri", …
        return f
    }()

    private var color: Color {
        switch window.fractionUsed {
        case 0..<0.55: return .green
        case 0..<0.80: return .yellow
        default: return .red
        }
    }
}

private func formatPercent(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.1f", value)
}

private func formatCount(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

enum MeterIconRenderer {
    static func image(snapshot: UsageSnapshot) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let values = iconValues(snapshot: snapshot)
        let barWidth: CGFloat = 3.5
        let gap: CGFloat = 2.0
        let baseline: CGFloat = 2.0
        let maxHeight: CGFloat = 14.0

        for (index, value) in values.enumerated() {
            let x = 2 + CGFloat(index) * (barWidth + gap)
            // An unknown window (nil) renders as a short gray stub so the user
            // can tell quota data is missing rather than reading it as "empty".
            let height = value.map { max(2, maxHeight * CGFloat($0)) } ?? 3
            let rect = NSRect(x: x, y: baseline, width: barWidth, height: height)
            color(for: value).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }

        // Activity dots: a small filled circle at the base of each provider's
        // bar pair when that provider has written session logs in the last 2 min.
        let codex  = snapshot.providers.first { $0.provider == .codex }
        let claude = snapshot.providers.first { $0.provider == .claude }
        let dotY: CGFloat = 0.5
        let dotR: CGFloat = 1.0
        // Codex bars are at indices 0 and 1; Claude at 2 and 3.
        for (isActive, barIndex) in [(codex?.isActive == true, 0), (claude?.isActive == true, 2)] {
            guard isActive else { continue }
            let x0 = 2 + CGFloat(barIndex) * (barWidth + gap)
            let x1 = 2 + CGFloat(barIndex + 1) * (barWidth + gap) + barWidth
            let cx  = (x0 + x1) / 2
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: dotY, width: dotR * 2, height: dotR * 2)).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Returns the fraction used for each bar, or nil when the value is unknown
    /// (provider missing or quota unavailable) so the icon can distinguish
    /// "unknown" from a genuine zero.
    private static func iconValues(snapshot: UsageSnapshot) -> [Double?] {
        let codex = snapshot.providers.first { $0.provider == .codex }
        let claude = snapshot.providers.first { $0.provider == .claude }
        return [
            value(codex?.shortWindow),
            value(codex?.longWindow),
            value(claude?.shortWindow),
            value(claude?.longWindow)
        ]
    }

    private static func value(_ window: UsageWindow?) -> Double? {
        guard let window, window.unitName != "unavailable" else {
            return nil
        }
        return window.fractionUsed
    }

    private static func color(for value: Double?) -> NSColor {
        guard let value else {
            return NSColor.systemGray
        }
        switch value {
        case 0..<0.55:
            return NSColor.systemGreen
        case 0..<0.80:
            return NSColor.systemYellow
        default:
            return NSColor.systemRed
        }
    }
}
