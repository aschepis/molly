import Foundation

/// Apple Reminders counts from the Data-*.sqlite stores. Titles, notes and
/// locations are never selected; list names are read only to group counts and
/// are published only when the `lists` label policy is enabled.
struct ReminderWindow {
    let dayStart: Double
    let dayEnd: Double
    let now: Double
    /// Completions after this instant feed the counter.
    let cursor: Double
}

struct ReminderCounts: Equatable {
    var open: Double = 0
    var dueToday: Double = 0
    var overdue: Double = 0
    var completedToday: Double = 0
    var completedSinceCursor: Double = 0
    var lists: Double = 0
    var openByList: [String: Double] = [:]
    var overdueByList: [String: Double] = [:]

    /// Several stores (one per account) are summed into a single picture.
    mutating func merge(_ other: ReminderCounts) {
        open += other.open
        dueToday += other.dueToday
        overdue += other.overdue
        completedToday += other.completedToday
        completedSinceCursor += other.completedSinceCursor
        lists += other.lists
        openByList.merge(other.openByList, uniquingKeysWith: +)
        overdueByList.merge(other.overdueByList, uniquingKeysWith: +)
    }
}

enum ReminderQueries {
    static let unknownList = "unknown"

    /// Reminders that are not tombstoned and whose list is not in the trash.
    private static let liveReminders = """
        FROM ZREMCDREMINDER r
        LEFT JOIN ZREMCDBASELIST l ON l.Z_PK = r.ZLIST
        WHERE COALESCE(r.ZMARKEDFORDELETION, 0) = 0 AND COALESCE(l.ZMARKEDFORDELETION, 0) = 0
        """
    private static let openOnly = "AND COALESCE(r.ZCOMPLETED, 0) = 0"
    private static let overdueOnly = "\(openOnly) AND r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE < ?"

    static func counts(db: SQLiteDatabase, window: ReminderWindow) throws -> ReminderCounts {
        var counts = ReminderCounts()
        counts.open = try scalar(db, "SELECT count(*) \(liveReminders) \(openOnly)")
        counts.dueToday = try scalar(db, """
            SELECT count(*) \(liveReminders) \(openOnly) AND r.ZDUEDATE >= ? AND r.ZDUEDATE < ?
            """, [window.dayStart, window.dayEnd])
        counts.overdue = try scalar(db, "SELECT count(*) \(liveReminders) \(overdueOnly)", [window.dayStart])
        counts.completedToday = try completed(db: db, after: window.dayStart, upTo: window.now)
        counts.completedSinceCursor = try completed(db: db, after: window.cursor, upTo: window.now)
        counts.lists = try scalar(db, """
            SELECT count(*) FROM ZREMCDBASELIST WHERE ZNAME IS NOT NULL AND COALESCE(ZMARKEDFORDELETION, 0) = 0
            """)
        counts.openByList = try byList(db, "\(liveReminders) \(openOnly)")
        counts.overdueByList = try byList(db, "\(liveReminders) \(overdueOnly)", [window.dayStart])
        return counts
    }

    /// Reminders completed in (after, upTo], dates in seconds since 2001.
    static func completed(db: SQLiteDatabase, after: Double, upTo: Double) throws -> Double {
        try scalar(db, """
            SELECT count(*) \(liveReminders) AND r.ZCOMPLETED = 1 AND r.ZCOMPLETIONDATE > ? AND r.ZCOMPLETIONDATE <= ?
            """, [after, upTo])
    }

    private static func scalar(_ db: SQLiteDatabase, _ sql: String, _ values: [Double] = []) throws -> Double {
        Double(try db.scalar(sql, bindings: values.map { .real($0) }).int ?? 0)
    }

    private static func byList(_ db: SQLiteDatabase, _ source: String, _ values: [Double] = []) throws -> [String: Double] {
        let rows = try db.query("SELECT l.ZNAME AS list, count(*) AS n \(source) GROUP BY l.ZNAME", bindings: values.map { .real($0) })
        var result: [String: Double] = [:]
        for row in rows {
            result[row["list"].string ?? unknownList, default: 0] += Double(row["n"].int ?? 0)
        }
        return result
    }
}

final class RemindersCollector: Collector {
    static let listsDefaults = LabelPolicy(enabled: false, mode: .denylist, maxCardinality: 50)
    static let defaultStoreFolders = [
        "~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores",
        "~/Library/Reminders/Container_v1/Stores",
    ]
    static let storePrefix = "Data-"
    static let storeSuffix = ".sqlite"
    static let cursorKey = "cursor.seconds"

    let name = "reminders"
    let interval: TimeInterval

    private let configuredPath: String?
    private let listFilter: LabelFilter
    private let store: StateStore
    private let startedAt: Date
    private let now: () -> Date
    private let calendar: Calendar

    private var open: Gauge?
    private var dueToday: Gauge?
    private var overdue: Gauge?
    private var completedToday: Gauge?
    private var completedTotal: Counter?
    private var lists: Gauge?
    private var listOpen: Gauge?
    private var listOverdue: Gauge?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) throws {
        interval = settings.interval(default: 300)
        configuredPath = settings.raw["path"]?.stringValue.map(Paths.expand)
        listFilter = try settings.filter("lists", defaults: RemindersCollector.listsDefaults)
        store = StateStore(collector: "reminders", folder: stateFolder)
        self.now = now
        self.calendar = calendar
        startedAt = now()
    }

    func start(registry: MetricsRegistry) throws {
        open = registry.gauge("molly_reminders_open", help: "Reminders that are not completed.")
        dueToday = registry.gauge("molly_reminders_due_today", help: "Open reminders due today.")
        overdue = registry.gauge("molly_reminders_overdue", help: "Open reminders due before today.")
        completedToday = registry.gauge("molly_reminders_completed_today", help: "Reminders completed since local midnight.")
        completedTotal = registry.counter("molly_reminders_completed_total", help: "Reminders completed since Molly started watching.")
        lists = registry.gauge("molly_reminders_lists", help: "Reminder lists.")
        listOpen = registry.gauge("molly_reminders_list_open", help: "Open reminders per list (one 'redacted' series unless the lists label policy is enabled).", labels: ["list"])
        listOverdue = registry.gauge("molly_reminders_list_overdue", help: "Overdue reminders per list (one 'redacted' series unless the lists label policy is enabled).", labels: ["list"])
    }

    func collect() throws {
        let stores = try resolveStores()
        let current = now()
        let dayStart = calendar.startOfDay(for: current)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let nowSeconds = CocoaTime.cocoaSeconds(current)
        let cursor = store.double(RemindersCollector.cursorKey) ?? CocoaTime.cocoaSeconds(startedAt)
        let window = ReminderWindow(dayStart: CocoaTime.cocoaSeconds(dayStart), dayEnd: CocoaTime.cocoaSeconds(dayEnd),
                                    now: nowSeconds, cursor: cursor)

        var total = ReminderCounts()
        for path in stores {
            let db = try SQLiteSnapshot.open(path: path)
            do {
                total.merge(try ReminderQueries.counts(db: db, window: window))
            } catch let error as SQLiteError {
                throw CollectorUnavailable(reason: "Reminders database schema not recognised: \(error)")
            }
        }

        open?.set(total.open)
        dueToday?.set(total.dueToday)
        overdue?.set(total.overdue)
        completedToday?.set(total.completedToday)
        lists?.set(total.lists)
        listOpen?.replaceAll(listFilter.labels(total.openByList), label: "list")
        listOverdue?.replaceAll(listFilter.labels(total.overdueByList), label: "list")
        completedTotal?.add(total.completedSinceCursor)
        store.set(RemindersCollector.cursorKey, max(cursor, nowSeconds))
        try store.save()
    }

    private func resolveStores() throws -> [String] {
        if let configuredPath { return [configuredPath] }
        let folders = Self.defaultStoreFolders.map(Paths.expand)
        let found = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasPrefix(Self.storePrefix) && $0.hasSuffix(Self.storeSuffix) }
                .sorted()
                .map { (folder as NSString).appendingPathComponent($0) }
        }
        guard !found.isEmpty else {
            throw CollectorUnavailable(reason: "Reminders store not found or not readable (looked in \(folders.joined(separator: ", "))); grant Full Disk Access")
        }
        return found
    }
}
