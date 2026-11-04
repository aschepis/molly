import Foundation

/// Everything the user edits except the token, which lives in the Keychain.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultServerURL = "http://adams-macbook-pro.tail853834.ts.net:9765"
    public static let defaultDeviceName = "iphone"
    public static let defaultBackfillDays = 30

    public var serverURL: String = AppSettings.defaultServerURL
    public var deviceName: String = AppSettings.defaultDeviceName
    public var backfillDays: Int = AppSettings.defaultBackfillDays
    public var enabledTypes: Set<MollyHealthType> = Set(MollyHealthType.allCases)
    public var hasRequestedAuthorization = false

    public init() {}

    /// The base URL without a trailing slash; nil when it is not an http(s) URL with a host.
    public var baseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    public func endpoint(_ path: String) -> URL? {
        guard let base = baseURL else { return nil }
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        return URL(string: root + path)
    }

    /// Lowercase letters, digits, `_` and `-`, as the Mac stores it; empty falls back to the default.
    public var sanitizedDeviceName: String {
        let plain = deviceName.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return plain.isEmpty ? AppSettings.defaultDeviceName : String(plain.prefix(32))
    }

    public var enabledInCatalogOrder: [MollyHealthType] {
        MollyHealthType.allCases.filter { enabledTypes.contains($0) }
    }
}

/// What the last upload attempt did, shown in the status section.
public struct SyncState: Codable, Equatable, Sendable {
    public var lastAttempt: Date?
    public var lastHTTPStatus: Int?
    public var lastAccepted: Int?
    public var lastRejected: [String: Int] = [:]
    public var lastError: String?
    /// The Mac's local day of the newest successful post; decides whether yesterday is re-sent.
    public var lastPostedDay: String?

    public init() {}
}

/// Fixed-size log so a long-running app cannot grow without bound.
public final class LogRing: @unchecked Sendable {
    public static let capacity = 200

    private let lock = NSLock()
    private var storage: [String] = []
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func append(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: now())
        lock.lock()
        defer { lock.unlock() }
        storage.append("\(stamp) \(message)")
        if storage.count > LogRing.capacity { storage.removeFirst(storage.count - LogRing.capacity) }
    }

    public var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public enum BackfillPlanner {
    public static let maxDays = 365

    /// `count` local days ending on `today`, oldest first.
    public static func days(count: Int, endingOn today: Date, calendar: Calendar) -> [Date] {
        let clamped = min(max(count, 1), maxDays)
        let start = calendar.startOfDay(for: today)
        return (0..<clamped).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: start) }
    }

    /// Yesterday is re-sent when the local date moved on since the last post, so a
    /// night's sleep lands on the wake-up day. Oldest first.
    public static func daysToRefresh(today: Date, lastPostedDay: String?, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: today)
        let todayKey = DayKey.string(for: start, calendar: calendar)
        guard lastPostedDay != todayKey, let yesterday = calendar.date(byAdding: .day, value: -1, to: start) else {
            return [start]
        }
        return [yesterday, start]
    }
}
