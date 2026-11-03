import XCTest
@testable import Molly

private let alertsResponse = """
{"status":"success","data":{"alerts":[
 {"labels":{"alertname":"BatteryLow","severity":"info","host":"mac"},
  "annotations":{"summary":"Battery below 15%","description":"Battery at 12%."},
  "state":"firing","activeAt":"2026-11-03T10:00:00Z","value":"12"},
 {"labels":{"alertname":"LongSessionNoBreak","severity":"warning"},
  "annotations":{},"state":"firing","value":"1"},
 {"labels":{"alertname":"DiskAlmostFull","severity":"info"},
  "annotations":{"summary":"Disk"},"state":"pending","value":"0.05"},
 {"labels":{"alertname":"BatteryLow","severity":"info","host":"other"},
  "annotations":{},"state":"firing","value":"9"}
]}}
"""

private func alert(_ name: String, _ severity: AlertSeverity = .info) -> FiringAlert {
    FiringAlert(name: name, severity: severity, summary: name, description: "")
}

final class AlertsParserTests: XCTestCase {
    func testKeepsFiringOnlyOncePerName() throws {
        let alerts = try AlertsParser.parse(Data(alertsResponse.utf8))
        XCTAssertEqual(alerts.map { $0.name }, ["BatteryLow", "LongSessionNoBreak"])
        XCTAssertEqual(alerts[0].summary, "Battery below 15%")
        XCTAssertEqual(alerts[0].description, "Battery at 12%.")
        XCTAssertEqual(alerts[1].severity, .warning)
    }

    func testMissingAnnotationsFallBackToName() throws {
        let alerts = try AlertsParser.parse(Data(alertsResponse.utf8))
        XCTAssertEqual(alerts[1].summary, "LongSessionNoBreak")
        XCTAssertEqual(alerts[1].description, "")
    }

    func testRejectsErrorResponse() {
        XCTAssertThrowsError(try AlertsParser.parse(Data(#"{"status":"error","error":"boom"}"#.utf8)))
        XCTAssertThrowsError(try AlertsParser.parse(Data("nope".utf8)))
    }
}

final class AlertTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let hour: TimeInterval = 3600

    private func step(_ tracker: inout AlertTracker, _ current: [FiringAlert], at offset: TimeInterval = 0,
                      muted: Set<String> = [], min: AlertSeverity = .info, repeatAfter: TimeInterval = 4 * 3600) -> AlertTracker.Outcome {
        tracker.update(current: current, now: t0.addingTimeInterval(offset), muted: muted,
                       minSeverity: min, repeatAfter: repeatAfter)
    }

    func testNotifiesOnceWhileStillFiring() {
        var tracker = AlertTracker()
        XCTAssertEqual(step(&tracker, [alert("A")]).toNotify.map { $0.name }, ["A"])
        XCTAssertTrue(step(&tracker, [alert("A")], at: 30).toNotify.isEmpty)
        XCTAssertEqual(tracker.firingCount, 1)
    }

    func testNewAlertAmongExistingOnesNotifiesOnlyTheNewOne() {
        var tracker = AlertTracker()
        _ = step(&tracker, [alert("A")])
        XCTAssertEqual(step(&tracker, [alert("A"), alert("B")], at: 30).toNotify.map { $0.name }, ["B"])
    }

    func testResolvedAlertStaysPublishedAsZero() {
        var tracker = AlertTracker()
        _ = step(&tracker, [alert("A", .warning)])
        let outcome = step(&tracker, [], at: 30)
        XCTAssertEqual(outcome.seen["A"], AlertTracker.Seen(severity: .warning, firing: false))
        XCTAssertEqual(tracker.firingCount, 0)
    }

    func testFlappingWithinRepeatWindowDoesNotRenotify() {
        var tracker = AlertTracker()
        XCTAssertEqual(step(&tracker, [alert("A")], at: 0).toNotify.count, 1)
        _ = step(&tracker, [], at: 60)
        XCTAssertTrue(step(&tracker, [alert("A")], at: 120).toNotify.isEmpty)
        _ = step(&tracker, [], at: 180)
        XCTAssertEqual(step(&tracker, [alert("A")], at: 4 * hour + 1).toNotify.count, 1)
    }

    func testMutedAlertIsTrackedButNeverNotified() {
        var tracker = AlertTracker()
        let outcome = step(&tracker, [alert("A")], muted: ["A"])
        XCTAssertTrue(outcome.toNotify.isEmpty)
        XCTAssertEqual(outcome.seen["A"]?.firing, true)
    }

    func testUnmutingLaterNotifiesOnNextTransition() {
        var tracker = AlertTracker()
        _ = step(&tracker, [alert("A")], muted: ["A"])
        _ = step(&tracker, [], at: 30, muted: ["A"])
        XCTAssertEqual(step(&tracker, [alert("A")], at: 60).toNotify.count, 1)
    }

    func testMinSeverityFilters() {
        var tracker = AlertTracker()
        let outcome = step(&tracker, [alert("I", .info), alert("W", .warning), alert("C", .critical)], min: .warning)
        XCTAssertEqual(outcome.toNotify.map { $0.name }, ["W", "C"])
        XCTAssertEqual(outcome.seen.count, 3)
    }

    func testSeverityLabelParsing() {
        XCTAssertEqual(AlertSeverity(label: "critical"), .critical)
        XCTAssertEqual(AlertSeverity(label: "Warning"), .warning)
        XCTAssertEqual(AlertSeverity(label: "page"), .info)
        XCTAssertEqual(AlertSeverity(label: nil), .info)
    }
}

final class AlertsCatalogAndCollectorTests: XCTestCase {
    private var rulesFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("deploy/prometheus/rules/molly.yml")
    }

    func testCatalogMatchesRulesFile() throws {
        let text = try String(contentsOf: rulesFile, encoding: .utf8)
        let inRules = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- alert:") else { return nil }
            return trimmed.dropFirst("- alert:".count).trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(inRules.count, Set(inRules).count, "duplicate alert names in the rules file")
        XCTAssertEqual(Set(AlertCatalog.all.map { $0.name }), Set(inRules))
        XCTAssertEqual(AlertCatalog.all.count, inRules.count, "duplicate catalog rows")
    }

    func testSettingsReadKeysWithDefaults() throws {
        let defaults = AlertsSettings(settings: CollectorSettings(name: "alerts", raw: [:]), links: Config.Links())
        XCTAssertEqual(defaults.prometheusURL, "http://localhost:9090")
        XCTAssertTrue(defaults.notify)
        XCTAssertTrue(defaults.muted.isEmpty)
        XCTAssertEqual(defaults.minSeverity, .info)
        XCTAssertEqual(defaults.repeatAfter, 4 * 3600)

        let config = try Config.parse(Data(#"{"collectors":{"alerts":{"notify":false,"muted":["BatteryLow"],"minSeverity":"warning","repeatAfterSeconds":60,"prometheusURL":"http://x:1"}}}"#.utf8))
        let custom = AlertsSettings(settings: config.collector("alerts"), links: config.links)
        XCTAssertFalse(custom.notify)
        XCTAssertEqual(custom.muted, ["BatteryLow"])
        XCTAssertEqual(custom.minSeverity, .warning)
        XCTAssertEqual(custom.repeatAfter, 60)
        XCTAssertEqual(custom.prometheusURL, "http://x:1")
    }

    func testMenuLines() {
        XCTAssertEqual(MenuModel.alertsLine(firing: 1), "1 alert firing")
        XCTAssertEqual(MenuModel.alertsLine(firing: 3), "3 alerts firing")
        XCTAssertEqual(MenuModel.healthDashboardURL(grafana: "http://localhost:3030/"), "http://localhost:3030/d/molly-health")
    }

    func testUnreachablePrometheusIsUnavailableNotAnError() throws {
        let config = try Config.parse(Data(#"{"collectors":{"alerts":{"prometheusURL":"http://127.0.0.1:1"}}}"#.utf8))
        let collector = try AlertsCollector(settings: config.collector("alerts"), config: config, notifier: FakeNotifier())
        try collector.start(registry: MetricsRegistry())
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }

    func testCollectPublishesFamiliesAgainstLiveStack() throws {
        let client = try PrometheusClient(baseURL: "http://localhost:9090")
        try XCTSkipUnless(client.isReady(), "local Prometheus not running")
        let registry = MetricsRegistry()
        let config = try Config.parse(Data("{}".utf8))
        let collector = try AlertsCollector(settings: config.collector("alerts"), config: config, notifier: FakeNotifier())
        try collector.start(registry: registry)
        try collector.collect()
        let text = registry.render()
        XCTAssertTrue(text.contains("molly_alert_notifications_authorized"))
    }
}

private final class FakeNotifier: AlertNotifier {
    var authorization = -1
    var posted: [FiringAlert] = []
    func post(_ alert: FiringAlert) { posted.append(alert) }
}
