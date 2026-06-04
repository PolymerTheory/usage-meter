import AppKit
import SwiftUI
import UsageMeterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = UsageViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchDiagnostics.write("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton(with: .empty)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 390)
        popover.contentViewController = NSHostingController(rootView: UsagePopoverView(model: model))

        model.onSnapshot = { [weak self] snapshot in
            self?.configureStatusButton(with: snapshot)
        }
        model.refresh()

        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refresh()
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
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
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

    func refresh() {
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                UsageMonitor().snapshot()
            }.value
            self.snapshot = snapshot
            self.onSnapshot?(snapshot)
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
                Button(action: model.refresh) {
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
                Spacer()
                Text("Updated \(relativeDate(provider.lastUpdated))")
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
        return "resets \(relativeDate(resetDate))"
    }

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
