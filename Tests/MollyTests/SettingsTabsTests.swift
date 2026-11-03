import XCTest
@testable import Molly

final class SettingsTabsTests: XCTestCase {
    private let report = """
    {"constLabels": {"host": "h", "user": "u"},
     "dimensions": [
       {"collector": "browser", "dimension": "browser.domains", "key": "domains",
        "counts": {"passed": 12, "other": 3, "redacted": 0, "hashed": 1}},
       {"collector": "calendar", "dimension": "calendar.calendars",
        "counts": {"passed": 0, "other": 0, "redacted": 15, "hashed": 0}},
       {"collector": "broken", "dimension": "broken.key"},
       "not an object"
     ]}
    """

    func testParseReadsCountsPerDimension() throws {
        let parsed = try PrivacyAuditSummary.parse(Data(report.utf8))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed["browser.domains"], .init(passed: 12, other: 3, redacted: 0, hashed: 1))
        XCTAssertEqual(parsed["calendar.calendars"]?.redacted, 15)
        XCTAssertNil(parsed["broken.key"])
    }

    func testParseOfEmptyReportGivesNothing() throws {
        XCTAssertTrue(try PrivacyAuditSummary.parse(Data("{}".utf8)).isEmpty)
        XCTAssertThrowsError(try PrivacyAuditSummary.parse(Data("nope".utf8)))
    }

    func testCountsSummaryOmitsZeros() {
        XCTAssertEqual(PrivacyAuditSummary.Counts(passed: 12, other: 3).summary, "12 passed · 3 other")
        XCTAssertEqual(PrivacyAuditSummary.Counts().summary, "nothing recorded yet")
        XCTAssertEqual(PrivacyAuditSummary.Counts(redacted: 15).total, 15)
    }

    func testStatusPillCoversEveryState() {
        let now = Date(timeIntervalSince1970: 1_000)
        var status = CollectorManager.Status(name: "focus", interval: 5)

        XCTAssertEqual(CollectorStatusText.pill(enabled: false, status: status, now: now).kind, .off)
        XCTAssertEqual(CollectorStatusText.pill(enabled: true, status: nil, now: now).text, "starts on Apply")
        XCTAssertEqual(CollectorStatusText.pill(enabled: true, status: status, now: now).kind, .waiting)

        status.errors = 2
        XCTAssertEqual(CollectorStatusText.pill(enabled: true, status: status, now: now).text, "2 errors")

        status.lastSuccess = now.addingTimeInterval(-42)
        let pill = CollectorStatusText.pill(enabled: true, status: status, now: now)
        XCTAssertEqual(pill.text, "ok 42s ago, 2 errors")
        XCTAssertEqual(pill.kind, .errors)

        status.errors = 0
        XCTAssertEqual(CollectorStatusText.pill(enabled: true, status: status, now: now).kind, .ok)

        status.unavailable = true
        XCTAssertEqual(CollectorStatusText.pill(enabled: true, status: status, now: now).kind, .unavailable)
    }

    func testPatternTextRoundTrips() {
        let patterns = ["*.google.com", "github.com"]
        XCTAssertEqual(PatternText.split(PatternText.join(patterns)), patterns)
        XCTAssertEqual(PatternText.split(" a.com ,\n\nb.com\n"), ["a.com", "b.com"])
        XCTAssertEqual(PatternText.split(""), [])
    }

    func testEveryCatalogDimensionBelongsToACatalogCollector() {
        let names = Set(CollectorCatalog.all.map { $0.name })
        for dimension in PrivacyCatalog.all {
            XCTAssertTrue(names.contains(dimension.collector), dimension.id)
        }
    }
}
