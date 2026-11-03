import XCTest
@testable import Molly

final class KnowledgeCollectorTests: GroupBTestCase {
    private func cocoa(_ date: Date) -> Double { CocoaTime.cocoaSeconds(date) }

    private func fixture() -> String {
        let n = cocoa(noon)
        return makeDatabase("""
            CREATE TABLE ZSTRUCTUREDMETADATA(Z_PK INTEGER PRIMARY KEY, Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID TEXT);
            CREATE TABLE ZOBJECT(Z_PK INTEGER PRIMARY KEY, ZSTREAMNAME TEXT, ZVALUESTRING TEXT, ZVALUEINTEGER INTEGER,
                ZSTARTDATE REAL, ZENDDATE REAL, ZCREATIONDATE REAL, ZSTRUCTUREDMETADATA INTEGER);
            INSERT INTO ZSTRUCTUREDMETADATA VALUES (1, 'com.apple.MobileSMS');
            INSERT INTO ZOBJECT(ZSTREAMNAME, ZVALUESTRING, ZVALUEINTEGER, ZSTARTDATE, ZENDDATE) VALUES
              ('/app/usage', 'com.example.editor', 1, \(n - 1000), \(n - 900)),
              ('/app/usage', 'com.example.editor', 1, \(n - 800), \(n - 700)),
              ('/app/usage', 'com.example.mail', 1, \(n - 600), \(n - 500)),
              ('/app/usage', 'com.example.openended', 1, \(n - 100), NULL),
              ('/app/usage', 'com.example.future', 1, \(n + 100), \(n + 200)),
              ('/app/mediaUsage', 'com.example.music', 1, \(n - 400), \(n - 340)),
              ('/display/isBacklit', '', 1, \(n - 1000), \(n - 700)),
              ('/display/isBacklit', '', 0, \(n - 700), \(n - 600)),
              ('/bluetooth/isConnected', '', 1, \(n - 500), \(n - 200));
            INSERT INTO ZOBJECT(ZSTREAMNAME, ZVALUESTRING, ZSTARTDATE, ZENDDATE, ZSTRUCTUREDMETADATA) VALUES
              ('/notification/usage', 'Receive', \(n - 300), \(n - 300), 1),
              ('/notification/usage', 'Receive', \(n - 200), \(n - 200), NULL),
              ('/notification/usage', 'Dismiss', \(n - 100), \(n - 100), 1);
            """)
    }

    func testIntervalsClipToCursorAndIgnoreOpenEndedAndFutureRows() throws {
        let db = try open(fixture())
        let n = cocoa(noon)
        let rows = try KnowledgeQueries.intervals(db: db, stream: .appUsage, after: n - 5000, upTo: n)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(KnowledgeQueries.seconds(rows, from: n - 5000), ["com.example.editor": 200, "com.example.mail": 100])
        // A cursor inside the first row counts only the part after it.
        let clipped = try KnowledgeQueries.intervals(db: db, stream: .appUsage, after: n - 950, upTo: n)
        XCTAssertEqual(KnowledgeQueries.seconds(clipped, from: n - 950)["com.example.editor"], 150)
        XCTAssertEqual(KnowledgeQueries.newestEnd(rows), n - 500)
    }

    func testNotificationsCountReceivedOnlyPerApp() throws {
        let rows = try KnowledgeQueries.notifications(db: open(fixture()), after: cocoa(noon) - 5000, upTo: cocoa(noon))
        let perApp = Dictionary(rows.map { ($0.value, 1) }, uniquingKeysWith: +)
        XCTAssertEqual(perApp, ["com.apple.MobileSMS": 1, "unknown": 1])
    }

    func testCollectorFirstRunBackfillsNothingButFillsToday() throws {
        let collector = try KnowledgeCollector(settings: settings("knowledge", ["path": .string(fixture())]), stateFolder: makeFolder(), now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertEqual(sample(registry, "molly_knowledge_app_usage_seconds_today{app=\"com.example.editor\"}"), 200)
        XCTAssertEqual(sample(registry, "molly_knowledge_notifications_today "), 2)
        XCTAssertNil(sample(registry, "molly_knowledge_app_usage_seconds_total{"))
        XCTAssertEqual(sample(registry, "molly_knowledge_display_on_seconds_total "), 0)
    }

    func testCollectorCountsRowsEndedAfterStart() throws {
        let path = fixture()
        let state = makeFolder()
        let start = noon.addingTimeInterval(-1000)
        // The process "started" 1000s before noon, so every fixture row ended after the cursor.
        let running = try KnowledgeCollector(settings: settings("knowledge", ["path": .string(path)]), stateFolder: state, now: sequence([start, noon]), calendar: utc)
        let registry2 = MetricsRegistry()
        try running.start(registry: registry2)
        try running.collect()
        XCTAssertEqual(sample(registry2, "molly_knowledge_app_usage_seconds_total{app=\"com.example.editor\"}"), 200)
        XCTAssertEqual(sample(registry2, "molly_knowledge_app_usage_seconds_total{app=\"com.example.mail\"}"), 100)
        XCTAssertEqual(sample(registry2, "molly_knowledge_media_playing_seconds_total{app=\"com.example.music\"}"), 60)
        XCTAssertEqual(sample(registry2, "molly_knowledge_display_on_seconds_total "), 300)
        XCTAssertEqual(sample(registry2, "molly_knowledge_bluetooth_connected_seconds_total "), 300)
        XCTAssertEqual(sample(registry2, "molly_knowledge_notifications_total{app=\"com.apple.mobilesms\"}"), 1)
        try running.collect()
        XCTAssertEqual(sample(registry2, "molly_knowledge_app_usage_seconds_total{app=\"com.example.editor\"}"), 200, "cursor prevents recounting")
    }

    /// Returns each value once, then repeats the last, so `startedAt` and later `now` can differ.
    private func sequence(_ dates: [Date]) -> () -> Date {
        var remaining = dates
        return { remaining.count > 1 ? remaining.removeFirst() : (remaining.first ?? Date()) }
    }
}
