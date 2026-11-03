import Foundation

/// System-recorded usage from knowledgeC.db. The system keeps writing it while
/// Molly is not running; we count only rows that ended after our cursor and
/// clip each row to the cursor so a long row is never counted twice.
struct KnowledgeInterval {
    let value: String
    let flag: Int64
    let start: Double
    let end: Double
}

enum KnowledgeStream: String, CaseIterable {
    case appUsage = "/app/usage"
    case mediaUsage = "/app/mediaUsage"
    case display = "/display/isBacklit"
    case bluetooth = "/bluetooth/isConnected"
    case notifications = "/notification/usage"

    var cursorKey: String { "cursor." + rawValue }
}

enum KnowledgeQueries {
    static let unknownApp = "unknown"

    /// Rows of a stream whose end is in (after, upTo]; open-ended rows (no end yet) are skipped.
    static func intervals(db: SQLiteDatabase, stream: KnowledgeStream, after: Double, upTo: Double) throws -> [KnowledgeInterval] {
        let rows = try db.query("""
            SELECT ZVALUESTRING AS value, ZVALUEINTEGER AS flag, ZSTARTDATE AS start, ZENDDATE AS end
            FROM ZOBJECT WHERE ZSTREAMNAME = ? AND ZENDDATE > ? AND ZENDDATE <= ? AND ZSTARTDATE IS NOT NULL
            """, bindings: [.text(stream.rawValue), .real(after), .real(upTo)])
        return rows.compactMap { row in
            guard let start = row["start"].double, let end = row["end"].double else { return nil }
            return KnowledgeInterval(value: row["value"].string ?? unknownApp, flag: row["flag"].int ?? 0, start: start, end: end)
        }
    }

    /// Received notifications, one entry per row, with the app that posted it.
    static func notifications(db: SQLiteDatabase, after: Double, upTo: Double) throws -> [KnowledgeInterval] {
        let rows = try db.query("""
            SELECT s.Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID AS app, o.ZSTARTDATE AS start, o.ZENDDATE AS end
            FROM ZOBJECT o LEFT JOIN ZSTRUCTUREDMETADATA s ON s.Z_PK = o.ZSTRUCTUREDMETADATA
            WHERE o.ZSTREAMNAME = ? AND o.ZVALUESTRING = 'Receive' AND o.ZENDDATE > ? AND o.ZENDDATE <= ?
            """, bindings: [.text(KnowledgeStream.notifications.rawValue), .real(after), .real(upTo)])
        return rows.compactMap { row in
            guard let end = row["end"].double else { return nil }
            return KnowledgeInterval(value: row["app"].string ?? unknownApp, flag: 0, start: row["start"].double ?? end, end: end)
        }
    }

    /// Seconds each value was active within [from, ∞), clipping rows that started earlier.
    static func seconds(_ intervals: [KnowledgeInterval], from: Double, where include: (KnowledgeInterval) -> Bool = { _ in true }) -> [String: Double] {
        var totals: [String: Double] = [:]
        for interval in intervals where include(interval) {
            let seconds = interval.end - max(interval.start, from)
            if seconds > 0 { totals[interval.value, default: 0] += seconds }
        }
        return totals
    }

    static func sum(_ values: [String: Double]) -> Double { values.values.reduce(0, +) }

    static func newestEnd(_ intervals: [KnowledgeInterval]) -> Double? { intervals.map { $0.end }.max() }
}

final class KnowledgeCollector: Collector {
    static let defaultPath = "~/Library/Application Support/Knowledge/knowledgeC.db"

    let name = "knowledge"
    let interval: TimeInterval

    private let path: String
    private let appFilter: LabelFilter
    private let store: StateStore
    private let startedAt: Date
    private let now: () -> Date
    private let calendar: Calendar

    private var appUsageTotal: Counter?
    private var appUsageToday: Gauge?
    private var notificationsTotal: Counter?
    private var notificationsToday: Gauge?
    private var mediaTotal: Counter?
    private var displayTotal: Counter?
    private var bluetoothTotal: Counter?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) throws {
        interval = settings.interval(default: 60)
        path = Paths.expand(settings.string("path", default: KnowledgeCollector.defaultPath))
        appFilter = try settings.filter("apps", defaults: LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 50))
        store = StateStore(collector: "knowledge", folder: stateFolder)
        self.now = now
        self.calendar = calendar
        startedAt = now()
    }

    func start(registry: MetricsRegistry) throws {
        appUsageTotal = registry.counter("molly_knowledge_app_usage_seconds_total", help: "Foreground app seconds recorded by the system (knowledgeC).", labels: ["app"])
        appUsageToday = registry.gauge("molly_knowledge_app_usage_seconds_today", help: "Foreground app seconds since local midnight.", labels: ["app"])
        notificationsTotal = registry.counter("molly_knowledge_notifications_total", help: "Notifications received, per posting app.", labels: ["app"])
        notificationsToday = registry.gauge("molly_knowledge_notifications_today", help: "Notifications received since local midnight.")
        mediaTotal = registry.counter("molly_knowledge_media_playing_seconds_total", help: "Seconds of media playback, per app.", labels: ["app"])
        displayTotal = registry.counter("molly_knowledge_display_on_seconds_total", help: "Seconds the display was backlit.")
        bluetoothTotal = registry.counter("molly_knowledge_bluetooth_connected_seconds_total", help: "Seconds with at least one Bluetooth device connected.")
    }

    func collect() throws {
        let db = try SQLiteSnapshot.open(path: path)
        let current = now()
        let nowSeconds = CocoaTime.cocoaSeconds(current)
        let dayStart = CocoaTime.cocoaSeconds(calendar.startOfDay(for: current))

        for stream in KnowledgeStream.allCases {
            let cursor = store.double(stream.cursorKey) ?? CocoaTime.cocoaSeconds(startedAt)
            let fresh = stream == .notifications
                ? try KnowledgeQueries.notifications(db: db, after: cursor, upTo: nowSeconds)
                : try KnowledgeQueries.intervals(db: db, stream: stream, after: cursor, upTo: nowSeconds)
            publishTotals(stream: stream, fresh: fresh, cursor: cursor)
            store.set(stream.cursorKey, max(cursor, KnowledgeQueries.newestEnd(fresh) ?? cursor))
        }

        let usage = try KnowledgeQueries.intervals(db: db, stream: .appUsage, after: dayStart, upTo: nowSeconds)
        let usageToday = KnowledgeQueries.seconds(usage, from: dayStart)
        appUsageToday?.replaceAll(appFilter.labels(usageToday), label: "app")
        let notificationsSinceMidnight = try KnowledgeQueries.notifications(db: db, after: dayStart, upTo: nowSeconds)
        notificationsToday?.set(notificationsSinceMidnight.count)
        try store.save()
    }

    private func publishTotals(stream: KnowledgeStream, fresh: [KnowledgeInterval], cursor: Double) {
        switch stream {
        case .appUsage:
            addLabelled(appUsageTotal, KnowledgeQueries.seconds(fresh, from: cursor))
        case .mediaUsage:
            addLabelled(mediaTotal, KnowledgeQueries.seconds(fresh, from: cursor))
        case .display:
            displayTotal?.add(KnowledgeQueries.sum(KnowledgeQueries.seconds(fresh, from: cursor) { $0.flag == 1 }))
        case .bluetooth:
            bluetoothTotal?.add(KnowledgeQueries.sum(KnowledgeQueries.seconds(fresh, from: cursor) { $0.flag == 1 }))
        case .notifications:
            let counts = Dictionary(fresh.map { ($0.value, 1.0) }, uniquingKeysWith: +)
            addLabelled(notificationsTotal, counts)
        }
    }

    private func addLabelled(_ counter: Counter?, _ perApp: [String: Double]) {
        for (app, n) in appFilter.labels(perApp) { counter?.add(n, labels: ["app": app]) }
    }
}
