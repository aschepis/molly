import XCTest
@testable import Molly

final class CalendarCollectorTests: GroupBTestCase {
    private func cocoa(_ date: Date) -> Double { CocoaTime.cocoaSeconds(date) }
    private var day: CalendarDay { CalendarDay(start: cocoa(midnight), end: cocoa(midnight) + 86_400) }

    /// Timed events 09-10 (Work), 09:30-10:30 (Work, overlaps), 14-15 (Home); an all-day Home event;
    /// a cancelled event and a hidden event that must be ignored.
    private func fixture() -> String {
        let m = cocoa(midnight)
        func hours(_ h: Double) -> Double { m + h * 3600 }
        return makeDatabase("""
            CREATE TABLE Calendar(ROWID INTEGER PRIMARY KEY, title TEXT);
            CREATE TABLE CalendarItem(ROWID INTEGER PRIMARY KEY, all_day INTEGER, hidden INTEGER, status INTEGER);
            CREATE TABLE OccurrenceCache(day REAL, event_id INTEGER, calendar_id INTEGER, occurrence_date REAL, occurrence_end_date REAL);
            INSERT INTO Calendar VALUES (1, 'Work'), (2, 'Home');
            INSERT INTO CalendarItem VALUES (1, 0, 0, 1), (2, 0, 0, 1), (3, 0, 0, 1), (4, 1, 0, 1), (5, 0, 0, 3), (6, 0, 1, 1), (7, 0, 0, 1);
            INSERT INTO OccurrenceCache VALUES
              (\(m), 1, 1, \(hours(9)), \(hours(10))),
              (\(m), 2, 1, \(hours(9.5)), \(hours(10.5))),
              (\(m), 3, 2, \(hours(14)), \(hours(15))),
              (\(m), 4, 2, \(m), \(m + 86_399)),
              (\(m), 5, 1, \(hours(11)), \(hours(12))),
              (\(m), 6, 1, \(hours(11)), \(hours(12))),
              (\(m), 7, 1, \(hours(30)), \(hours(31)));
            """)
    }

    func testSummaryAtNoonMergesOverlapsAndSkipsAllDay() throws {
        let db = try open(fixture())
        let nowSeconds = cocoa(noon)
        let occurrences = try CalendarQueries.occurrences(db: db, day: day)
        XCTAssertEqual(occurrences.count, 4)
        let next = try CalendarQueries.nextEventStart(db: db, after: nowSeconds)
        let summary = CalendarQueries.summarize(occurrences, day: day, now: nowSeconds, nextStart: next)
        XCTAssertEqual(summary.eventsByCalendar, ["Work": 2, "Home": 2])
        XCTAssertEqual(summary.eventSeconds, 1.5 * 3600 + 3600)
        XCTAssertEqual(summary.secondsRemaining, 3600)
        XCTAssertFalse(summary.inEvent)
        XCTAssertEqual(summary.secondsUntilNext, 2 * 3600)
    }

    func testInEventAndNoUpcomingEvent() throws {
        let db = try open(fixture())
        let during = cocoa(midnight) + 9.75 * 3600
        let occurrences = try CalendarQueries.occurrences(db: db, day: day)
        let busy = CalendarQueries.summarize(occurrences, day: day, now: during, nextStart: 1)
        XCTAssertTrue(busy.inEvent)
        let late = cocoa(midnight) + 40 * 3600
        let none = CalendarQueries.summarize([], day: day, now: late, nextStart: nil)
        XCTAssertEqual(none.secondsUntilNext, -1)
        XCTAssertEqual(none.eventSeconds, 0)
    }

    func testCollectorHidesCalendarNamesByDefault() throws {
        let path = fixture()
        let collector = try CalendarCollector(settings: settings("calendar", ["path": .string(path)]), now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertEqual(sample(registry, "molly_calendar_events_today{calendar=\"redacted\"}"), 4)
        XCTAssertEqual(sample(registry, "molly_calendar_event_seconds_today "), 9000)
        XCTAssertFalse(registry.render().contains("work"))

        let open = try CalendarCollector(settings: settings("calendar", ["path": .string(path), "calendars": .object(["enabled": .bool(true)])]), now: { self.noon }, calendar: utc)
        let registry2 = MetricsRegistry()
        try open.start(registry: registry2)
        try open.collect()
        XCTAssertEqual(sample(registry2, "molly_calendar_events_today{calendar=\"work\"}"), 2)
    }

    func testUnrecognisedSchemaIsUnavailable() throws {
        let path = makeDatabase("CREATE TABLE Other(x INTEGER);")
        let collector = try CalendarCollector(settings: settings("calendar", ["path": .string(path)]))
        try collector.start(registry: MetricsRegistry())
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }
}
