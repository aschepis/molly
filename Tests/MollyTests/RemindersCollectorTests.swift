import XCTest
@testable import Molly

final class RemindersCollectorTests: GroupBTestCase {
    private func cocoa(_ date: Date) -> Double { CocoaTime.cocoaSeconds(date) }
    private let day = 86_400.0

    /// Lists: Work (1), Home (2), Trash (3, tombstoned). Reminders cover every bucket the counts care about.
    private func fixture() -> String {
        let n = cocoa(noon)
        let m = cocoa(midnight)
        return makeDatabase("""
            CREATE TABLE ZREMCDBASELIST(Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZMARKEDFORDELETION INTEGER);
            CREATE TABLE ZREMCDREMINDER(Z_PK INTEGER PRIMARY KEY, ZLIST INTEGER, ZTITLE TEXT, ZCOMPLETED INTEGER,
                ZCOMPLETIONDATE REAL, ZDUEDATE REAL, ZMARKEDFORDELETION INTEGER);
            INSERT INTO ZREMCDBASELIST VALUES (1, 'Work', 0), (2, 'Home', 0), (3, 'Trash', 1);
            INSERT INTO ZREMCDREMINDER(ZLIST, ZTITLE, ZCOMPLETED, ZCOMPLETIONDATE, ZDUEDATE, ZMARKEDFORDELETION) VALUES
              (1, 'overdue',        0, NULL, \(m - day), 0),
              (1, 'due today',      0, NULL, \(m + 3600), 0),
              (2, 'due tomorrow',   0, NULL, \(m + day + 60), 0),
              (2, 'no date',        0, NULL, NULL, 0),
              (1, 'done today',     1, \(n - 600), \(m - 60), 0),
              (2, 'done last week', 1, \(n - 7 * day), NULL, 0),
              (1, 'tombstone',      0, NULL, \(m - day), 1),
              (3, 'in trashed list', 0, NULL, \(m - day), 0);
            """)
    }

    private func window(cursor: Double? = nil) -> ReminderWindow {
        ReminderWindow(dayStart: cocoa(midnight), dayEnd: cocoa(midnight) + day, now: cocoa(noon), cursor: cursor ?? cocoa(noon))
    }

    func testQueries() throws {
        let counts = try ReminderQueries.counts(db: try open(fixture()), window: window(cursor: cocoa(noon) - 86_400 * 8))
        XCTAssertEqual(counts.open, 4)
        XCTAssertEqual(counts.dueToday, 1)
        XCTAssertEqual(counts.overdue, 1)
        XCTAssertEqual(counts.completedToday, 1)
        XCTAssertEqual(counts.completedSinceCursor, 2)
        XCTAssertEqual(counts.lists, 2, "trashed list excluded")
        XCTAssertEqual(counts.openByList, ["Work": 2, "Home": 2])
        XCTAssertEqual(counts.overdueByList, ["Work": 1])
    }

    func testCollectorPublishesCountsAndHidesListNames() throws {
        let collector = try RemindersCollector(settings: settings("reminders", ["path": .string(fixture())]),
                                               stateFolder: makeFolder(), now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertEqual(sample(registry, "molly_reminders_open "), 4)
        XCTAssertEqual(sample(registry, "molly_reminders_due_today "), 1)
        XCTAssertEqual(sample(registry, "molly_reminders_overdue "), 1)
        XCTAssertEqual(sample(registry, "molly_reminders_completed_today "), 1)
        XCTAssertEqual(sample(registry, "molly_reminders_lists "), 2)
        XCTAssertEqual(sample(registry, "molly_reminders_completed_total "), 0, "no backfill on first run")
        XCTAssertEqual(sample(registry, "molly_reminders_list_open{list=\"redacted\"}"), 4)
        let output = registry.render().lowercased()
        XCTAssertFalse(output.contains("work"))
        XCTAssertFalse(output.contains("home"))
    }

    func testListPolicyEnabledPublishesNamesAndCapsCardinality() throws {
        let config: [String: JSONValue] = ["path": .string(fixture()),
                                           "lists": .object(["enabled": .bool(true), "maxCardinality": .number(1)])]
        let collector = try RemindersCollector(settings: settings("reminders", config), stateFolder: makeFolder(), now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertEqual(sample(registry, "molly_reminders_list_overdue{list=\"work\"}"), 1)
        XCTAssertNotNil(sample(registry, "molly_reminders_list_open{list=\"other\"}"), "second list folds into other")
    }

    func testCursorCountsLaterCompletionsOnce() throws {
        let path = fixture()
        let state = makeFolder()
        let first = try RemindersCollector(settings: settings("reminders", ["path": .string(path)]), stateFolder: state, now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try first.start(registry: registry)
        try first.collect()

        execute("UPDATE ZREMCDREMINDER SET ZCOMPLETED = 1, ZCOMPLETIONDATE = \(cocoa(noon) + 30) WHERE ZTITLE = 'overdue'", at: path)
        let second = try RemindersCollector(settings: settings("reminders", ["path": .string(path)]), stateFolder: state,
                                            now: { self.noon.addingTimeInterval(60) }, calendar: utc)
        let registry2 = MetricsRegistry()
        try second.start(registry: registry2)
        try second.collect()
        try second.collect()
        XCTAssertEqual(sample(registry2, "molly_reminders_completed_total "), 1)
        XCTAssertEqual(sample(registry2, "molly_reminders_completed_today "), 2)
    }

    func testUnreadableStoreIsUnavailable() throws {
        let collector = try RemindersCollector(settings: settings("reminders", ["path": .string("/nonexistent/Data-x.sqlite")]),
                                               stateFolder: makeFolder())
        try collector.start(registry: MetricsRegistry())
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }

    func testLiveStoreExposesMetricFamilies() throws {
        let collector = try RemindersCollector(settings: settings("reminders", [:]), stateFolder: makeFolder())
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        do {
            try collector.collect()
        } catch is CollectorUnavailable {
            throw XCTSkip("Reminders store absent or unreadable on this machine")
        }
        let output = registry.render()
        for family in ["molly_reminders_open", "molly_reminders_due_today", "molly_reminders_overdue",
                       "molly_reminders_completed_today", "molly_reminders_completed_total", "molly_reminders_lists"] {
            XCTAssertTrue(output.contains(family), family)
        }
    }
}
