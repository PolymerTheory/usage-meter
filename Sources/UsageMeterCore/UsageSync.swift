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
    /// Short, non-reversible fingerprint of the account/workspace this reading
    /// belongs to. Lets a device avoid trusting a reading from a different
    /// account (or workspace) than its own. Absent on blobs from older builds.
    public var account: String?

    public init(updatedAt: Date, updatedBy: String, short: SharedWindow, long: SharedWindow, detail: String, source: String, account: String? = nil) {
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.short = short
        self.long = long
        self.detail = detail
        self.source = source
        self.account = account
    }

    enum CodingKeys: String, CodingKey {
        case updatedAt, updatedBy, short, long, detail, source, account
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.updatedBy = try c.decode(String.self, forKey: .updatedBy)
        self.short = try c.decode(SharedWindow.self, forKey: .short)
        self.long = try c.decode(SharedWindow.self, forKey: .long)
        self.detail = try c.decode(String.self, forKey: .detail)
        self.source = try c.decode(String.self, forKey: .source)
        self.account = try c.decodeIfPresent(String.self, forKey: .account)
    }

    /// True when at least one window carries a real percentage.
    public var isAvailable: Bool {
        short.percent != nil || long.percent != nil
    }

    /// Whether this reading may be trusted for a device whose account is
    /// `mine`. When our own account is unknown we don't block; when it's known,
    /// the reading must carry a matching fingerprint (so an untagged reading
    /// from an older build, or one from a different account, is not reused).
    public func accountMatches(_ mine: String?) -> Bool {
        guard let mine else { return true }
        return account == mine
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

        guard let (data, status) = perform(request), (200..<300).contains(status),
              let data, !data.isEmpty else { return nil }
        return try? Self.decoder.decode(SharedUsage.self, from: data)
    }

    public enum ProbeResult: Equatable, Sendable {
        case ok
        case unauthorized
        case reachableNoData
        case badURL
        case unreachable(String)

        public var message: String {
            switch self {
            case .ok: return "Connected — endpoint is reachable."
            case .reachableNoData: return "Connected — endpoint reachable (no data published yet)."
            case .unauthorized: return "Reached the server, but the token was rejected (401/403). Check the token."
            case .badURL: return "That doesn't look like a valid URL."
            case let .unreachable(why): return "Couldn't reach the endpoint: \(why)"
            }
        }

        public var isSuccess: Bool { self == .ok || self == .reachableNoData }
    }

    /// A read-only reachability check for the settings UI — never writes, so it
    /// can't clobber real data. Distinguishes "works", "bad token", and
    /// "unreachable" so the user gets actionable feedback.
    public func probe(config: SyncConfig) -> ProbeResult {
        let trimmed = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return .badURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        apply(token: config.token, to: &request)

        guard let (data, status) = perform(request) else {
            return .unreachable("no response (offline, wrong host, or CORS/DNS)")
        }
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .reachableNoData
        case 200..<300: return (data?.isEmpty ?? true) ? .reachableNoData : .ok
        default: return .unreachable("HTTP \(status)")
        }
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
        if let (_, status) = perform(request) { return (200..<300).contains(status) }
        return false
    }

    private func apply(token: String?, to request: inout URLRequest) {
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Synchronous request. Returns `(body, statusCode)` when an HTTP response
    /// arrives (any status), or nil on a transport-level failure (offline, DNS,
    /// timeout). `read`/`publish` still treat only 2xx as usable.
    private func perform(_ request: URLRequest) -> (Data?, Int)? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, Int)?
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            result = (data, http.statusCode)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
        }
        return result
    }
}
