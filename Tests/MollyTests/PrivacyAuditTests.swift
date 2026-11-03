import XCTest
@testable import Molly

final class PrivacyAuditTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PrivacyAudit.shared.reset()
    }

    override func tearDown() {
        PrivacyAudit.shared.reset()
        super.tearDown()
    }

    func testFilterCountsEveryOutcome() throws {
        let filter = try LabelFilter(policy: LabelPolicy(enabled: true, mode: .denylist, patterns: ["deny.me"]),
                                     dimension: "t.domains")
        _ = filter.label("ok.com")
        _ = filter.label("ok.com")
        _ = filter.label("deny.me")
        _ = filter.label("")
        let hashed = try LabelFilter(policy: LabelPolicy(enabled: true, hash: true), dimension: "t.hashed")
        _ = hashed.label("x")
        let off = try LabelFilter(policy: LabelPolicy(enabled: false), dimension: "t.off")
        _ = off.label("secret")

        let dims = Dictionary(uniqueKeysWithValues: PrivacyAudit.shared.snapshot().map { ($0.name, $0.counts) })
        XCTAssertEqual(dims["t.domains"], [.passed: 2, .redacted: 1, .other: 1])
        XCTAssertEqual(dims["t.hashed"], [.hashed: 1])
        XCTAssertEqual(dims["t.off"], [.redacted: 1])
    }

    func testFilterWithoutDimensionIsNotAudited() throws {
        let filter = try LabelFilter(policy: LabelPolicy(enabled: true))
        _ = filter.label("value")
        XCTAssertTrue(PrivacyAudit.shared.snapshot().isEmpty)
        _ = LabelFilter.disabled.label("value")
        XCTAssertTrue(PrivacyAudit.shared.snapshot().isEmpty)
    }

    func testCollectorSettingsRegistersDimensionAndKeepsCountsOnReload() throws {
        let config = try Config.parse(Data(#"{"collectors": {"browser": {"domains": {"enabled": true, "patterns": ["bank.com"]}}}}"#.utf8))
        let filter = try config.collector("browser").filter("domains", defaults: LabelPolicy(enabled: false))
        XCTAssertEqual(filter.dimension, "browser.domains")
        _ = filter.label("online.bank.com")
        _ = filter.label("github.com")

        // A reload re-registers with the (possibly changed) policy; counts remain.
        let reloaded = try Config.parse(Data("{}".utf8)).collector("browser").filter("domains", defaults: LabelPolicy(enabled: false))
        XCTAssertFalse(reloaded.enabled)
        let dim = PrivacyAudit.shared.snapshot().first { $0.name == "browser.domains" }
        XCTAssertEqual(dim?.collector, "browser")
        XCTAssertEqual(dim?.key, "domains")
        XCTAssertEqual(dim?.policy.enabled, false)
        XCTAssertEqual(dim?.counts, [.redacted: 1, .passed: 1])
    }

    func testAttachedRegistryPublishesDecisionCounter() throws {
        let registry = MetricsRegistry()
        let filter = try Config().collector("focus").filter("apps", defaults: LabelPolicy(enabled: true))
        PrivacyAudit.shared.attach(registry: registry)
        _ = filter.label("safari")
        let counter = registry.counter("molly_privacy_label_decisions_total", help: "", labels: ["dimension", "outcome"])
        XCTAssertEqual(counter.value(labels: ["dimension": "focus.apps", "outcome": "passed"]), 1)
        XCTAssertEqual(counter.value(labels: ["dimension": "focus.apps", "outcome": "redacted"]), 0)
    }

    func testReportCarriesPolicyAndCountsButNeverPatternsOrValues() throws {
        let filter = try Config.parse(Data(#"{"collectors": {"shell": {"hosts": {"enabled": true, "patterns": ["internal.corp"], "hash": true, "maxCardinality": 5}}}}"#.utf8))
            .collector("shell").filter("hosts")
        _ = filter.label("api.internal.corp")
        _ = filter.label("example.org")
        let report = PrivacyAudit.shared.report(constLabels: ["user": "u", "host": "h"],
                                                collectorsOn: ["shell", "mail"],
                                                disabledByDefault: ["mail", "tabs"])
        let data = try JSONSerialization.data(withJSONObject: report)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("internal.corp"), "patterns must not appear in the privacy report")
        XCTAssertFalse(text.contains("example.org"), "raw values must never appear")

        let dims = report["dimensions"] as? [[String: Any]]
        let hosts = dims?.first { $0["dimension"] as? String == "shell.hosts" }
        let policy = hosts?["policy"] as? [String: Any]
        XCTAssertEqual(policy?["patternCount"] as? Int, 1)
        XCTAssertEqual(policy?["hash"] as? Bool, true)
        XCTAssertEqual(policy?["maxCardinality"] as? Int, 5)
        let counts = hosts?["counts"] as? [String: Int]
        XCTAssertEqual(counts, ["passed": 0, "other": 0, "redacted": 1, "hashed": 1])

        let sensitive = report["sensitiveCollectors"] as? [[String: Any]]
        XCTAssertEqual(sensitive?.map { $0["collector"] as? String }, ["mail", "tabs"])
        XCTAssertEqual(sensitive?.first?["enabled"] as? Bool, true)
        XCTAssertEqual(sensitive?.last?["enabled"] as? Bool, false)
    }

    func testDisabledByDefaultMatchesRegistry() throws {
        let defaults = try CollectorRegistry.makeCollectors(config: Config()).map { $0.name }
        for name in CollectorRegistry.disabledByDefault {
            XCTAssertFalse(defaults.contains(name), "\(name) should be off by default")
            XCTAssertTrue(CollectorRegistry.knownNames.contains(name))
        }
        var sections: [String: JSONValue] = [:]
        for name in CollectorRegistry.disabledByDefault { sections[name] = .object(["enabled": .bool(true)]) }
        var config = Config()
        config.collectors = sections
        let enabled = try CollectorRegistry.makeCollectors(config: config).map { $0.name }
        for name in CollectorRegistry.disabledByDefault {
            XCTAssertTrue(enabled.contains(name), "\(name) should start when enabled explicitly")
        }
    }

    func testPrivacyRouteServesReport() throws {
        let registry = MetricsRegistry(constLabels: ["user": "t", "host": "h"])
        let manager = CollectorManager(registry: registry, collectors: [])
        _ = try Config().collector("browser").filter("domains")
        let router = Router()
        Routes.register(on: router, manager: manager, config: Config())
        let port = Int.random(in: 20000...40000)
        let server = try HTTPServer(bind: "127.0.0.1", port: port, router: router)
        server.start()
        defer { server.stop() }

        var status = 0
        var body = Data()
        for _ in 0..<20 {
            let (s, data) = DoctorCommand.fetch(URL(string: "http://127.0.0.1:\(port)/privacy")!, timeout: 1)
            if s == 200 {
                status = s
                body = data
                break
            }
            usleep(100_000)
        }
        XCTAssertEqual(status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["constLabels"] as? [String: String])?["host"], Config.defaultHost)
        let dims = try XCTUnwrap(json["dimensions"] as? [[String: Any]])
        XCTAssertTrue(dims.contains { $0["dimension"] as? String == "browser.domains" })
        XCTAssertNotNil(json["sensitiveCollectors"])
    }

    func testRenderedTableListsDimensions() {
        let report: [String: Any] = [
            "constLabels": ["user": "u", "host": "h"],
            "dimensions": [[
                "dimension": "browser.domains", "collector": "browser", "key": "domains", "enabled": true,
                "policy": ["enabled": true, "mode": "denylist", "patternCount": 2, "hash": false, "maxCardinality": 50],
                "counts": ["passed": 10, "other": 3, "redacted": 1, "hashed": 0],
            ]],
            "sensitiveCollectors": [["collector": "mail", "defaultEnabled": false, "enabled": false]],
        ]
        let text = PrivacyCommand.render(report)
        XCTAssertTrue(text.contains("browser.domains"))
        XCTAssertTrue(text.contains("on, denylist, 2 patterns, max 50"))
        XCTAssertTrue(text.contains("mail"))
        XCTAssertTrue(text.contains("labels on every series: host=h user=u"))
    }
}
