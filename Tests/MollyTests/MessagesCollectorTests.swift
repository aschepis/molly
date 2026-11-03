import XCTest
@testable import Molly

final class MessagesCollectorTests: GroupBTestCase {
    private func nanos(_ date: Date) -> Int64 { CocoaTime.cocoaNanoseconds(date) }

    private func fixture() -> String {
        makeDatabase("""
            CREATE TABLE message(ROWID INTEGER PRIMARY KEY AUTOINCREMENT, date INTEGER, is_from_me INTEGER, service TEXT,
                cache_has_attachments INTEGER, is_read INTEGER, handle_id INTEGER, is_service_message INTEGER);
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            INSERT INTO message(date, is_from_me, service, cache_has_attachments, is_read, is_service_message)
                VALUES (\(nanos(noon.addingTimeInterval(-86400 * 3))), 0, 'iMessage', 0, 1, 0);
            INSERT INTO message(date, is_from_me, service, cache_has_attachments, is_read, is_service_message)
                VALUES (\(nanos(noon.addingTimeInterval(-600))), 0, 'iMessage', 1, 0, 0);
            INSERT INTO message(date, is_from_me, service, cache_has_attachments, is_read, is_service_message)
                VALUES (\(nanos(noon.addingTimeInterval(-500))), 1, 'SMS', 0, 1, 0);
            INSERT INTO message(date, is_from_me, service, cache_has_attachments, is_read, is_service_message)
                VALUES (\(nanos(noon.addingTimeInterval(-400))), 0, 'RCS', 0, 0, 0);
            INSERT INTO message(date, is_from_me, service, cache_has_attachments, is_read, is_service_message)
                VALUES (\(nanos(noon.addingTimeInterval(-300))), 0, 'iMessage', 0, 0, 1);
            INSERT INTO chat_message_join VALUES (1, 1), (1, 2), (2, 3), (3, 4), (3, 5);
            """)
    }

    func testTodayBucketsChatsAndUnread() throws {
        let db = try open(fixture())
        let batch = try MessagesQueries.messagesToday(db: db, sinceNanos: nanos(midnight), untilNanos: nanos(noon))
        XCTAssertEqual(batch.total(service: "iMessage", direction: "received"), 1, "service messages and older days are excluded")
        XCTAssertEqual(batch.total(service: "SMS", direction: "sent"), 1)
        XCTAssertEqual(batch.total(service: "RCS", direction: "received"), 1)
        XCTAssertEqual(batch.buckets[MessageBucket(service: "iMessage", direction: "received", hasAttachment: true)], 1)
        XCTAssertEqual(try MessagesQueries.chatsActive(db: db, sinceNanos: nanos(midnight), untilNanos: nanos(noon)), 3)
        XCTAssertEqual(try MessagesQueries.unread(db: db), 2)
        XCTAssertEqual(MessagesQueries.normalizeService("Weird"), "other")
        XCTAssertEqual(MessagesQueries.normalizeService(nil), "other")
    }

    func testCursorIsIncrementalAndSurvivesRestart() throws {
        let path = fixture()
        let state = makeFolder()
        let first = MessagesCollector(settings: settings("messages", ["path": .string(path)]), stateFolder: state, now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try first.start(registry: registry)
        try first.collect()
        XCTAssertEqual(sample(registry, "molly_messages_total{service=\"iMessage\",direction=\"received\"}"), 0, "existing rows are not backfilled")
        XCTAssertEqual(sample(registry, "molly_messages_today{service=\"iMessage\",direction=\"received\"}"), 1)

        execute("""
            INSERT INTO message(date, is_from_me, service, cache_has_attachments, is_read, is_service_message)
                VALUES (\(nanos(noon.addingTimeInterval(10))), 1, 'iMessage', 1, 1, 0), (\(nanos(noon.addingTimeInterval(11))), 0, 'SMS', 0, 0, 0);
            """, at: path)
        let restarted = MessagesCollector(settings: settings("messages", ["path": .string(path)]), stateFolder: state, now: { self.noon.addingTimeInterval(60) }, calendar: utc)
        let registry2 = MetricsRegistry()
        try restarted.start(registry: registry2)
        try restarted.collect()
        XCTAssertEqual(sample(registry2, "molly_messages_total{service=\"iMessage\",direction=\"sent\"}"), 1)
        XCTAssertEqual(sample(registry2, "molly_messages_total{service=\"SMS\",direction=\"received\"}"), 1)
        XCTAssertEqual(sample(registry2, "molly_messages_with_attachments_total{direction=\"sent\"}"), 1)
        XCTAssertEqual(sample(registry2, "molly_messages_with_attachments_total{direction=\"received\"}"), 0)
        try restarted.collect()
        XCTAssertEqual(sample(registry2, "molly_messages_total{service=\"iMessage\",direction=\"sent\"}"), 1)
    }

    func testMissingDatabaseIsUnavailable() throws {
        let collector = MessagesCollector(settings: settings("messages", ["path": .string("/nonexistent/chat.db")]), stateFolder: makeFolder())
        try collector.start(registry: MetricsRegistry())
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }
}
