import Foundation

/// Message volume from Messages' chat.db. Only counts are read: message text,
/// handles and chat names never leave the SQL aggregate.
struct MessageBucket: Hashable {
    let service: String
    let direction: String
    let hasAttachment: Bool
}

struct MessageBatch {
    var buckets: [MessageBucket: Int] = [:]
    var maxRowID: Int64?

    func total(service: String, direction: String) -> Int {
        buckets.filter { $0.key.service == service && $0.key.direction == direction }.values.reduce(0, +)
    }
}

enum MessagesQueries {
    static let services = ["iMessage", "SMS", "RCS"]
    static let directions = ["sent", "received"]
    static let otherService = "other"

    static func normalizeService(_ raw: String?) -> String {
        services.first { $0.caseInsensitiveCompare(raw ?? "") == .orderedSame } ?? otherService
    }

    static func currentMaxRowID(db: SQLiteDatabase) throws -> Int64 {
        try db.scalar("SELECT COALESCE(MAX(ROWID), 0) FROM message").int ?? 0
    }

    /// Messages added after `rowID` (the cursor), grouped by service, direction and attachment.
    static func newMessages(db: SQLiteDatabase, afterRowID rowID: Int64) throws -> MessageBatch {
        let rows = try db.query("""
            SELECT service, is_from_me, cache_has_attachments AS attachments, count(*) AS n, MAX(ROWID) AS last_id
            FROM message WHERE ROWID > ? AND is_service_message = 0
            GROUP BY service, is_from_me, cache_has_attachments
            """, bindings: [.integer(rowID)])
        return batch(from: rows)
    }

    /// Messages with a date at or after `sinceNanos` (nanoseconds since 2001).
    static func messagesToday(db: SQLiteDatabase, sinceNanos: Int64, untilNanos: Int64) throws -> MessageBatch {
        let rows = try db.query("""
            SELECT service, is_from_me, cache_has_attachments AS attachments, count(*) AS n, MAX(ROWID) AS last_id
            FROM message WHERE date >= ? AND date <= ? AND is_service_message = 0
            GROUP BY service, is_from_me, cache_has_attachments
            """, bindings: [.integer(sinceNanos), .integer(untilNanos)])
        return batch(from: rows)
    }

    static func chatsActive(db: SQLiteDatabase, sinceNanos: Int64, untilNanos: Int64) throws -> Int {
        Int(try db.scalar("""
            SELECT count(DISTINCT j.chat_id) FROM message m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            WHERE m.date >= ? AND m.date <= ? AND m.is_service_message = 0
            """, bindings: [.integer(sinceNanos), .integer(untilNanos)]).int ?? 0)
    }

    static func unread(db: SQLiteDatabase) throws -> Int {
        Int(try db.scalar("SELECT count(*) FROM message WHERE is_from_me = 0 AND is_read = 0 AND is_service_message = 0").int ?? 0)
    }

    private static func batch(from rows: [SQLiteRow]) -> MessageBatch {
        var result = MessageBatch()
        for row in rows {
            let bucket = MessageBucket(
                service: normalizeService(row["service"].string),
                direction: (row["is_from_me"].int ?? 0) == 0 ? "received" : "sent",
                hasAttachment: (row["attachments"].int ?? 0) != 0)
            result.buckets[bucket, default: 0] += Int(row["n"].int ?? 0)
            if let id = row["last_id"].int { result.maxRowID = max(result.maxRowID ?? id, id) }
        }
        return result
    }
}

final class MessagesCollector: Collector {
    static let defaultPath = "~/Library/Messages/chat.db"
    static let cursorKey = "cursor.rowid"

    let name = "messages"
    let interval: TimeInterval

    private let path: String
    private let store: StateStore
    private let now: () -> Date
    private let calendar: Calendar

    private var total: Counter?
    private var today: Gauge?
    private var attachmentsTotal: Counter?
    private var chatsActiveToday: Gauge?
    private var unreadGauge: Gauge?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        interval = settings.interval(default: 60)
        path = Paths.expand(settings.string("path", default: MessagesCollector.defaultPath))
        store = StateStore(collector: "messages", folder: stateFolder)
        self.now = now
        self.calendar = calendar
    }

    func start(registry: MetricsRegistry) throws {
        total = registry.counter("molly_messages_total", help: "Messages sent and received since Molly started watching.", labels: ["service", "direction"])
        today = registry.gauge("molly_messages_today", help: "Messages sent and received since local midnight.", labels: ["service", "direction"])
        attachmentsTotal = registry.counter("molly_messages_with_attachments_total", help: "Messages carrying attachments since Molly started watching.", labels: ["direction"])
        chatsActiveToday = registry.gauge("molly_message_chats_active_today", help: "Conversations with at least one message since local midnight.")
        unreadGauge = registry.gauge("molly_messages_unread", help: "Received messages not yet marked read.")
    }

    func collect() throws {
        let db = try SQLiteSnapshot.open(path: path)
        let current = now()
        let dayStartNanos = CocoaTime.cocoaNanoseconds(calendar.startOfDay(for: current))
        let nowNanos = CocoaTime.cocoaNanoseconds(current)

        // First run starts at the newest row so existing history is never backfilled.
        let cursor = try store.int(MessagesCollector.cursorKey).map(Int64.init) ?? MessagesQueries.currentMaxRowID(db: db)
        let fresh = try MessagesQueries.newMessages(db: db, afterRowID: cursor)
        for service in MessagesQueries.services + [MessagesQueries.otherService] {
            for direction in MessagesQueries.directions {
                total?.add(Double(fresh.total(service: service, direction: direction)), labels: ["service": service, "direction": direction])
            }
        }
        for direction in MessagesQueries.directions {
            let withAttachments = fresh.buckets.filter { $0.key.direction == direction && $0.key.hasAttachment }.values.reduce(0, +)
            attachmentsTotal?.add(Double(withAttachments), labels: ["direction": direction])
        }
        store.set(MessagesCollector.cursorKey, Int(max(cursor, fresh.maxRowID ?? cursor)))

        let todayBatch = try MessagesQueries.messagesToday(db: db, sinceNanos: dayStartNanos, untilNanos: nowNanos)
        for service in MessagesQueries.services + [MessagesQueries.otherService] {
            for direction in MessagesQueries.directions {
                today?.set(todayBatch.total(service: service, direction: direction), labels: ["service": service, "direction": direction])
            }
        }
        chatsActiveToday?.set(try MessagesQueries.chatsActive(db: db, sinceNanos: dayStartNanos, untilNanos: nowNanos))
        unreadGauge?.set(try MessagesQueries.unread(db: db))
        try store.save()
    }
}

extension Doctor {
    static func messagesChecks(config: Config) -> [DoctorCommand.Check] {
        let path = Paths.expand(config.collector("messages").string("path", default: MessagesCollector.defaultPath))
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let readable = FileHandle(forReadingAtPath: path) != nil
        return [DoctorCommand.Check(name: "messages db", ok: readable, detail: readable ? "readable" : "Full Disk Access needed for chat.db")]
    }
}
