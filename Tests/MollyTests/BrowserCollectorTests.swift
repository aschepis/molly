import XCTest
@testable import Molly

final class BrowserCollectorTests: GroupBTestCase {
    private func chromeMicros(_ date: Date) -> Int64 { CocoaTime.webKitMicroseconds(date) }

    private func chromiumFixture(visits: [(String, Date)]) -> String {
        var sql = "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER);"
        sql += "CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);"
        for (index, visit) in visits.enumerated() {
            sql += "INSERT INTO urls(id, url) VALUES (\(index + 1), '\(visit.0)');"
            sql += "INSERT INTO visits(url, visit_time) VALUES (\(index + 1), \(chromeMicros(visit.1)));"
        }
        return makeDatabase(sql)
    }

    func testDomainExtraction() {
        let cases: [(String, String?)] = [
            ("https://Example.COM/path?q=1#frag", "example.com"),
            ("http://user:pass@example.com:8080/x", "example.com"),
            ("https://www.example.com", "www.example.com"),
            ("https://xn--bcher-kva.example/", "xn--bcher-kva.example"),
            ("https://[::1]:3000/a", "[::1]"),
            ("https://example.com?x=1", "example.com"),
            ("file:///Users/me/doc.html", nil),
            ("chrome://settings", nil),
            ("about:blank", nil),
            ("https:///nohost", nil),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(BrowserQueries.domain(fromURL: url), expected, url)
        }
    }

    func testChromiumVisitsRespectCursorAndUpperBound() throws {
        let path = chromiumFixture(visits: [
            ("https://a.com/1", noon.addingTimeInterval(-300)),
            ("https://a.com/2", noon.addingTimeInterval(-200)),
            ("https://b.com/", noon.addingTimeInterval(-100)),
            ("https://future.com/", noon.addingTimeInterval(500)),
        ])
        let db = try open(path)
        let all = try BrowserQueries.visits(db: db, schema: .chromium, after: noon.timeIntervalSince1970 - 250, upTo: noon.timeIntervalSince1970)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.domains, ["a.com": 1, "b.com": 1])
        XCTAssertEqual(all.newestUnix ?? 0, noon.timeIntervalSince1970 - 100, accuracy: 1e-5)

        let afterNewest = try BrowserQueries.visits(db: db, schema: .chromium, after: all.newestUnix ?? 0, upTo: noon.timeIntervalSince1970)
        XCTAssertEqual(afterNewest.count, 0, "the visit that set the cursor must not be counted again")
    }

    func testSafariAndFirefoxSchemas() throws {
        let safari = makeDatabase("""
            CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT, domain_expansion TEXT, visit_count INTEGER);
            CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
            INSERT INTO history_items(id, url) VALUES (1, 'https://safari.example/x');
            INSERT INTO history_visits(history_item, visit_time) VALUES (1, \(CocoaTime.cocoaSeconds(noon) - 10.123456));
            """)
        let result = try BrowserQueries.visits(db: open(safari), schema: .safari, after: midnight.timeIntervalSince1970, upTo: noon.timeIntervalSince1970)
        XCTAssertEqual(result.domains, ["safari.example": 1])
        XCTAssertEqual(
            try BrowserQueries.visits(db: open(safari), schema: .safari, after: result.newestUnix ?? 0, upTo: noon.timeIntervalSince1970).count, 0)
        XCTAssertEqual(try BrowserQueries.historyRows(db: open(safari), schema: .safari), 1)

        let firefox = makeDatabase("""
            CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER);
            INSERT INTO moz_places(id, url) VALUES (1, 'https://ff.example/');
            INSERT INTO moz_historyvisits(place_id, visit_date) VALUES (1, \(Int64(noon.timeIntervalSince1970 * 1e6) - 5_000_000));
            """)
        let ff = try BrowserQueries.visits(db: open(firefox), schema: .firefox, after: midnight.timeIntervalSince1970, upTo: noon.timeIntervalSince1970)
        XCTAssertEqual(ff.domains, ["ff.example": 1])
    }

    func testCollectorCountsOnlyNewVisitsAndGatesDomains() throws {
        let path = chromiumFixture(visits: [("https://old.example/", noon.addingTimeInterval(-3600))])
        let state = makeFolder()
        let config: [String: JSONValue] = [
            "browsers": .array([.string("fixture")]),
            "extraProfiles": .array([.object(["browser": .string("fixture"), "path": .string(path)])]),
        ]
        let collector = try BrowserCollector(settings: settings("browser", config), stateFolder: state, now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()

        XCTAssertEqual(sample(registry, "molly_browser_visits_today{browser=\"fixture\"}"), 1)
        XCTAssertEqual(sample(registry, "molly_browser_visits_total{browser=\"fixture\"}"), 0, "history before start is not backfilled")
        XCTAssertEqual(sample(registry, "molly_browser_distinct_domains_today{browser=\"fixture\"}"), 1)
        XCTAssertEqual(sample(registry, "molly_browser_available{browser=\"fixture\"}"), 1)
        XCTAssertFalse(registry.render().contains("old.example"), "domains are off by default")

        execute("""
            INSERT INTO urls(id, url) VALUES (50, 'https://new.example/page');
            INSERT INTO visits(url, visit_time) VALUES (50, \(chromeMicros(noon.addingTimeInterval(1))));
            """, at: path)
        let later = noon.addingTimeInterval(60)
        let second = try BrowserCollector(settings: settings("browser", config), stateFolder: state, now: { later }, calendar: utc)
        let secondRegistry = MetricsRegistry()
        try second.start(registry: secondRegistry)
        try second.collect()
        XCTAssertEqual(sample(secondRegistry, "molly_browser_visits_total{browser=\"fixture\"}"), 1, "cursor survives a restart")
        try second.collect()
        XCTAssertEqual(sample(secondRegistry, "molly_browser_visits_total{browser=\"fixture\"}"), 1, "a second run adds nothing")
    }

    func testDomainLabelsAppearWhenPolicyEnabled() throws {
        let path = chromiumFixture(visits: [
            ("https://keep.example/a", noon.addingTimeInterval(-60)),
            ("https://secret.bank.example/b", noon.addingTimeInterval(-50)),
        ])
        let config: [String: JSONValue] = [
            "browsers": .array([.string("fixture")]),
            "extraProfiles": .array([.object(["browser": .string("fixture"), "path": .string(path)])]),
            "domains": .object(["enabled": .bool(true), "patterns": .array([.string("bank.example")])]),
        ]
        let collector = try BrowserCollector(settings: settings("browser", config), stateFolder: makeFolder(), now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertEqual(sample(registry, "molly_browser_domain_visits_today{browser=\"fixture\",domain=\"keep.example\"}"), 1)
        XCTAssertEqual(sample(registry, "molly_browser_domain_visits_today{browser=\"fixture\",domain=\"redacted\"}"), 1)
        XCTAssertFalse(registry.render().contains("bank.example"))
    }

    func testMissingProfilesAreUnavailable() throws {
        let config: [String: JSONValue] = ["browsers": .array([.string("nonexistent_browser")])]
        let collector = try BrowserCollector(settings: settings("browser", config), stateFolder: makeFolder())
        try collector.start(registry: MetricsRegistry())
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }

    func testDetectionHonoursAllowListAndExtras() {
        let extra = BrowserProfile(browser: "arc", schema: .chromium, path: "/x/History")
        let found = BrowserDetector.detect(allowed: ["arc"], extras: [extra], fileExists: { $0 == "/x/History" })
        XCTAssertEqual(found, [extra])
        XCTAssertTrue(BrowserDetector.detect(allowed: ["safari"], extras: [extra], fileExists: { $0 == "/x/History" }).isEmpty)
    }
}
