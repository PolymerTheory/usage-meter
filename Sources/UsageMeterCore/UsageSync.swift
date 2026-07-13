import Foundation

// MARK: - Shared blob model

/// The JSON document published to (and read from) the sync endpoint. It carries
/// only usage figures — never tokens or credentials — so it is safe to store in
/// a user's own cloud key/value entry and read from a phone.
public struct SharedUsage: Codable, Equatable, Sendable {
    public var version: Int
    public var updatedAt: Date
    public var updatedBy: String
    public var providers: [String: SharedProvider]

    public init(version: Int = 1, updatedAt: Date, updatedBy: String, providers: [String: SharedProvider]) {
        self.version = version
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.providers = providers
    }
}

public struct SharedProvider: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var updatedBy: String
    public var short: SharedWindow
    public var long: SharedWindow
    public var detail: String
    public var source: String

    public init(updatedAt: Date, updatedBy: String, short: SharedWindow, long: SharedWindow, detail: String, source: String) {
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.short = short
        self.long = long
        self.detail = detail
        self.source = source
    }

    /// True when at least one window carries a real percentage.
    public var isAvailable: Bool {
        short.percent != nil || long.percent != nil
    }
}

public struct SharedWindow: Codable, Equatable, Sendable {
    public var label: String
    /// nil means the window is unavailable (e.g. the API omitted it).
    public var percent: Double?
    public var resetAt: Date?

    public init(label: String, percent: Double?, resetAt: Date?) {
        self.label = label
        self.percent = percent
        self.resetAt = resetAt
    }
}

// MARK: - Conversions to/from the app's display models

extension SharedWindow {
    init(_ window: UsageWindow) {
        self.label = window.label
        self.percent = window.unitName == "unavailable" ? nil : window.usedPercent
        self.resetAt = window.resetDate
    }

    func toUsageWindow(stale: Bool) -> UsageWindow {
        guard let percent else {
            return UsageWindow(
                label: label, usedUnits: 0, limitUnits: 100, resetDate: nil,
                isEstimated: false, usedPercent: nil, unitName: "unavailable"
            )
        }
        return UsageWindow(
            label: label, usedUnits: Int(percent.rounded()), limitUnits: 100,
            resetDate: resetAt, isEstimated: false, usedPercent: percent,
            unitName: "quota", isStale: stale
        )
    }
}

extension SharedProvider {
    init(_ usage: ProviderUsage, at: Date, by: String) {
        self.updatedAt = at
        self.updatedBy = by
        self.short = SharedWindow(usage.shortWindow)
        self.long = SharedWindow(usage.longWindow)
        self.detail = usage.detail
        self.source = usage.source
    }

    /// Rebuild a `ProviderUsage` for display. Marks windows stale when the blob
    /// is older than `staleAfter`, and notes which device produced it.
    func toProviderUsage(provider: UsageProvider, now: Date, staleAfter: TimeInterval) -> ProviderUsage {
        let stale = now.timeIntervalSince(updatedAt) > staleAfter
        return ProviderUsage(
            provider: provider,
            shortWindow: short.toUsageWindow(stale: stale),
            longWindow: long.toUsageWindow(stale: stale),
            detail: "\(detail) • via \(updatedBy)",
            source: source,
            lastUpdated: updatedAt
        )
    }
}

// MARK: - HTTP client

/// Reads and publishes the shared blob over a simple GET/PUT contract:
/// `GET {url}` returns the stored JSON; `PUT {url}` stores the JSON body. The
/// endpoint is a per-user, key-scoped URL the user configures; `token` (if set)
/// is sent as `Authorization: Bearer`.
public struct SyncClient {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 8) {
        self.session = session
        self.timeout = timeout
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func read(config: SyncConfig) -> SharedUsage? {
        guard config.isActive, let url = URL(string: config.url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        apply(token: config.token, to: &request)

        guard let data = perform(request), !data.isEmpty else { return nil }
        return try? Self.decoder.decode(SharedUsage.self, from: data)
    }

    @discardableResult
    public func publish(_ blob: SharedUsage, config: SyncConfig) -> Bool {
        guard config.isActive, let url = URL(string: config.url),
              let body = try? Self.encoder.encode(blob) else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        apply(token: config.token, to: &request)
        return perform(request) != nil
    }

    private func apply(token: String?, to request: inout URLRequest) {
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Synchronous request; returns the body on a 2xx response, else nil.
    private func perform(_ request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return
            }
            result = data ?? Data()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
        }
        return result
    }
}
