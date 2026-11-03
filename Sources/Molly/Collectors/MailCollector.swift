import Foundation

/// Best-effort Apple Mail volume from the Envelope Index. Only mailbox URLs
/// (to tell sent from received) and counts are read; no senders, subjects or
/// addresses. Off by default because the schema changes between macOS releases.
enum MailDirection: String, CaseIterable {
    case sent, received

    private static let excluded = ["draft", "junk", "spam", "trash", "deleted", "outbox", "sendlater"]

    /// Mailbox URL to direction; nil for drafts, junk, trash and other non-mail folders.
    static func classify(mailboxURL: String) -> MailDirection? {
        let url = mailboxURL.lowercased()
        let name = url.split(separator: "/").last.map(String.init) ?? url
        if excluded.contains(where: { name.contains($0) }) { return nil }
        return name.hasPrefix("sent") ? .sent : .received
    }
}

struct MailBatch: Equatable {
    var counts: [MailDirection: Int] = [:]
    var maxRowID: Int64?
}

enum MailQueries {
    static func currentMaxRowID(db: SQLiteDatabase) throws -> Int64 {
        try db.scalar("SELECT COALESCE(MAX(ROWID), 0) FROM messages").int ?? 0
    }

    /// Messages with ROWID after `rowID`.
    static func newMessages(db: SQLiteDatabase, afterRowID rowID: Int64) throws -> MailBatch {
        try grouped(db, "m.ROWID > ?", [.integer(rowID)])
    }

    /// Messages received (or sent) in [since, until], Unix seconds.
    static func messagesToday(db: SQLiteDatabase, since: Double, until: Double) throws -> MailBatch {
        try grouped(db, "COALESCE(m.date_received, m.date_sent) >= ? AND COALESCE(m.date_received, m.date_sent) <= ?", [.real(since), .real(until)])
    }

    static func unread(db: SQLiteDatabase) throws -> Int {
        try grouped(db, "m.read = 0").counts[.received] ?? 0
    }

    private static func grouped(_ db: SQLiteDatabase, _ condition: String, _ bindings: [SQLiteValue] = []) throws -> MailBatch {
        let rows = try db.query("""
            SELECT mb.url AS url, count(*) AS n, MAX(m.ROWID) AS last_id
            FROM messages m JOIN mailboxes mb ON mb.ROWID = m.mailbox
            WHERE m.deleted = 0 AND \(condition) GROUP BY mb.url
            """, bindings: bindings)
        var batch = MailBatch()
        for row in rows {
            guard let url = row["url"].string, let direction = MailDirection.classify(mailboxURL: url) else { continue }
            batch.counts[direction, default: 0] += Int(row["n"].int ?? 0)
            if let id = row["last_id"].int { batch.maxRowID = max(batch.maxRowID ?? id, id) }
        }
        return batch
    }
}

final class MailCollector: Collector {
    static let cursorKey = "cursor.rowid"

    let name = "mail"
    let interval: TimeInterval

    private let configuredPath: String?
    private let store: StateStore
    private let now: () -> Date
    private let calendar: Calendar

    private var total: Counter?
    private var today: Gauge?
    private var unreadGauge: Gauge?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        interval = settings.interval(default: 120)
        configuredPath = settings.raw["path"]?.stringValue.map(Paths.expand)
        store = StateStore(collector: "mail", folder: stateFolder)
        self.now = now
        self.calendar = calendar
    }

    func start(registry: MetricsRegistry) throws {
        total = registry.counter("molly_mail_messages_total", help: "Mail messages sent and received since Molly started watching.", labels: ["direction"])
        today = registry.gauge("molly_mail_messages_today", help: "Mail messages sent and received since local midnight.", labels: ["direction"])
        unreadGauge = registry.gauge("molly_mail_unread", help: "Unread received messages that are not deleted.")
    }

    /// Mail keeps its index under ~/Library/Mail/V<n>/MailData; the highest version wins.
    static func locateEnvelopeIndex(mailRoot: String = Paths.expand("~/Library/Mail")) -> String? {
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: mailRoot)) ?? [])
            .filter { $0.hasPrefix("V") && Int($0.dropFirst()) != nil }
            .sorted { (Int($0.dropFirst()) ?? 0) > (Int($1.dropFirst()) ?? 0) }
        return versions.map { "\(mailRoot)/\($0)/MailData/Envelope Index" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    func collect() throws {
        guard let path = configuredPath ?? Self.locateEnvelopeIndex() else {
            throw CollectorUnavailable(reason: "Mail Envelope Index not found")
        }
        let db = try SQLiteSnapshot.open(path: path)
        let current = now()
        let since = calendar.startOfDay(for: current).timeIntervalSince1970

        do {
            let cursor = try store.int(MailCollector.cursorKey).map(Int64.init) ?? MailQueries.currentMaxRowID(db: db)
            let fresh = try MailQueries.newMessages(db: db, afterRowID: cursor)
            let todayBatch = try MailQueries.messagesToday(db: db, since: since, until: current.timeIntervalSince1970)
            let unread = try MailQueries.unread(db: db)

            for direction in MailDirection.allCases {
                total?.add(Double(fresh.counts[direction] ?? 0), labels: ["direction": direction.rawValue])
                today?.set(todayBatch.counts[direction] ?? 0, labels: ["direction": direction.rawValue])
            }
            unreadGauge?.set(unread)
            store.set(MailCollector.cursorKey, Int(max(cursor, fresh.maxRowID ?? cursor)))
            try store.save()
        } catch let error as SQLiteError {
            throw CollectorUnavailable(reason: "Mail schema not recognised: \(error)")
        }
    }
}
