import XCTest
@testable import Molly

final class TunerTests: XCTestCase {
    private func status(_ name: String, interval: Double = 60, runs: Int = 10, errors: Int = 0,
                        lastError: String? = nil, duration: Double = 0.1, unavailable: Bool = false,
                        since: Date? = nil) -> TuneInput.CollectorStatus {
        TuneInput.CollectorStatus(name: name, interval: interval, runs: runs, errors: errors, lastError: lastError,
                                  lastDuration: duration, unavailable: unavailable, unavailableSince: since)
    }

    private func input(families: [FamilyStats] = [], collectors: [TuneInput.CollectorStatus] = [],
                       configJSON: String = "{}", scrapeDuration: Double? = nil, scrapeSamples: Double? = nil,
                       env: TuneInput.Environment = .init()) throws -> TuneInput {
        var i = TuneInput(families: families, collectors: collectors, config: try Config.parse(Data(configJSON.utf8)))
        i.scrapeDuration = scrapeDuration
        i.scrapeSamples = scrapeSamples
        i.environment = env
        i.now = Date(timeIntervalSince1970: 1_800_000_000)
        return i
    }

    private func family(_ name: String, series: Int, labels: [String: Int] = [:]) -> FamilyStats {
        FamilyStats(name: name, type: .gauge, series: series, labelCardinality: labels)
    }

    func testRule1UnavailableWithPermissionErrorForOverAnHour() throws {
        let old = Date(timeIntervalSince1970: 1_800_000_000 - 7200)
        let recent = Date(timeIntervalSince1970: 1_800_000_000 - 600)
        let recs = Tuner.unavailableCollectors(try input(collectors: [
            status("messages", lastError: "chat.db is not readable (missing file or Full Disk Access)", unavailable: true, since: old),
            status("notes", lastError: "not readable", unavailable: true, since: recent),
            status("git", lastError: "timeout", unavailable: true, since: old),
        ]))
        XCTAssertEqual(recs.map { $0.collector }, ["messages"])
        XCTAssertEqual(recs[0].severity, .warn)
        XCTAssertEqual(recs[0].configPatch, Tuner.patch("messages", ["enabled": .bool(false)]))
    }

    func testRule2SlowCollectorRaisesInterval() throws {
        let recs = Tuner.slowCollectors(try input(collectors: [
            status("git", interval: 120, duration: 70),
            status("system", interval: 15, duration: 1),
            status("events", interval: 0, duration: 5),
        ]))
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].configPatch, Tuner.patch("git", ["interval": .number(140)]))
    }

    func testRule3ErrorRate() throws {
        let recs = Tuner.failingCollectors(try input(collectors: [
            status("docker", runs: 10, errors: 3, lastError: "daemon down"),
            status("notes", runs: 10, errors: 1, lastError: "x"),
            status("mail", runs: 2, errors: 2, lastError: "too few runs"),
            status("codex", runs: 10, errors: 10, lastError: "unavailable", unavailable: true),
        ]))
        XCTAssertEqual(recs.map { $0.collector }, ["docker"])
        XCTAssertTrue(recs[0].why.contains("daemon down"))
        XCTAssertNil(recs[0].configPatch)
    }

    func testRule4WideLabelDimension() throws {
        let cfg = #"{"collectors": {"browser": {"domains": {"enabled": true, "maxCardinality": 30}}}}"#
        let recs = Tuner.wideLabels(try input(
            families: [
                family("molly_browser_domain_visits_total", series: 70, labels: ["browser": 2, "domain": 70]),
                family("molly_git_commits_total", series: 20, labels: ["repo": 20, "author": 2]),
                family("molly_claude_tool_calls_total", series: 150, labels: ["tool": 12, "project": 150]),
            ],
            collectors: [status("browser"), status("git"), status("claude_code")],
            configJSON: cfg))
        XCTAssertEqual(recs.map { $0.collector }, ["browser", "claude_code"])
        XCTAssertEqual(recs[0].configPatch, Tuner.patch("browser", ["domains": .object(["maxCardinality": .number(15)])]))
        XCTAssertEqual(recs[1].configPatch, Tuner.patch("claude_code", ["projects": .object(["maxCardinality": .number(50)])]))
    }

    func testRule5SeriesBudget() throws {
        let big = family("molly_browser_domain_visits_total", series: 4000, labels: ["domain": 2000, "browser": 2])
        let mid = family("molly_knowledge_app_usage_seconds_total", series: 1500, labels: ["app": 1500])
        let recs = Tuner.seriesBudget(try input(families: [big, mid, family("molly_up", series: 1)],
                                                collectors: [status("browser"), status("knowledge")]))
        XCTAssertEqual(recs.count, 1)
        XCTAssertTrue(recs[0].title.contains("5501"))
        let patch = recs[0].configPatch?["collectors"]
        XCTAssertEqual(patch?["browser"]?["domains"]?["enabled"], .bool(false))
        XCTAssertEqual(patch?["knowledge"]?["apps"]?["enabled"], .bool(false))
        XCTAssertTrue(Tuner.seriesBudget(try input(families: [big], collectors: [status("browser")])).isEmpty)
        XCTAssertFalse(Tuner.seriesBudget(try input(families: [family("molly_up", series: 1)], scrapeSamples: 6000)).isEmpty)
    }

    func testRule6SlowScrape() throws {
        let fast = try input(collectors: [status("git", duration: 3)], scrapeDuration: 0.02)
        XCTAssertTrue(Tuner.slowScrape(fast).isEmpty)
        let slow = try input(collectors: [status("git", interval: 120, duration: 3), status("system", interval: 15, duration: 0.5),
                                          status("events", interval: 0, duration: 9)], scrapeDuration: 2.5)
        let recs = Tuner.slowScrape(slow)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].configPatch?["collectors"]?["git"]?["interval"], .number(240))
        XCTAssertNil(recs[0].configPatch?["collectors"]?["events"])
    }

    func testRule7EnableableSources() throws {
        var env = TuneInput.Environment()
        env.codexSessionsExist = true
        env.mailIndexExists = true
        env.accessibilityTrusted = true
        let recs = Tuner.enableableSources(try input(configJSON: #"{"collectors": {"codex": {"enabled": false}}}"#, env: env))
        XCTAssertEqual(recs.map { $0.collector }, ["codex", "mail", "input"])
        XCTAssertTrue(recs.allSatisfy { $0.severity == .info && $0.configPatch == nil })
        let none = Tuner.enableableSources(try input(configJSON: #"{"collectors": {"mail": {"enabled": true}}}"#, env: env))
        XCTAssertEqual(none.map { $0.collector }, ["input"])
    }

    func testRule8HashingAvailable() throws {
        let cfg = #"{"collectors": {"browser": {"domains": {"enabled": true}}, "shell": {"hosts": {"enabled": true, "hash": true}}}}"#
        let recs = Tuner.hashingAvailable(try input(configJSON: cfg))
        XCTAssertEqual(recs.map { $0.title }, ["browser.domains exports raw values"])
        XCTAssertTrue(Tuner.hashingAvailable(try input()).isEmpty)
    }

    func testRule9TokenOnOpenBind() throws {
        XCTAssertTrue(Tuner.tokenOnOpenBind(try input(configJSON: #"{"server": {"bind": "0.0.0.0"}, "collectors": {"events": {"token": "s"}}}"#)).isEmpty)
        XCTAssertTrue(Tuner.tokenOnOpenBind(try input(configJSON: #"{"server": {"bind": "127.0.0.1"}}"#)).isEmpty)
        XCTAssertEqual(Tuner.tokenOnOpenBind(try input(configJSON: #"{"server": {"bind": "0.0.0.0"}}"#)).count, 1)
        XCTAssertEqual(Tuner.tokenOnOpenBind(try input(configJSON: #"{"server": {"bind": ["127.0.0.1", "100.64.0.1"]}}"#)).count, 1)
    }

    func testCollectorNameMapping() {
        let known = ["browser", "git", "claude_code", "events", "processes", "process"]
        XCTAssertEqual(Tuner.collectorName(for: "molly_browser_visits_total", known: known), "browser")
        XCTAssertEqual(Tuner.collectorName(for: "molly_claude_tokens_total", known: known), "claude_code")
        XCTAssertEqual(Tuner.collectorName(for: "molly_claude_hook_events_total", known: known), "events")
        XCTAssertEqual(Tuner.collectorName(for: "molly_process_cpu_ratio", known: known), "processes")
        XCTAssertEqual(Tuner.collectorName(for: "molly_self_threads", known: known), "process")
        XCTAssertNil(Tuner.collectorName(for: "molly_unknown_thing", known: known))
    }

    func testHealthyInputYieldsNothing() throws {
        let recs = Tuner.recommend(input: try input(families: [family("molly_up", series: 1)],
                                                    collectors: [status("system", interval: 15, duration: 0.01)],
                                                    scrapeDuration: 0.01, scrapeSamples: 900))
        XCTAssertEqual(recs, [])
        XCTAssertEqual(TuneReport.text(recs), "No recommendations. Molly looks healthy.\n")
    }

    func testReportShapes() throws {
        let rec = Recommendation(severity: .warn, collector: "git", title: "T", why: "W",
                                 configPatch: Tuner.patch("git", ["interval": .number(240)]))
        let text = TuneReport.text([rec])
        XCTAssertTrue(text.hasPrefix("1. [warn] T\n   W\n   patch:\n"))
        XCTAssertTrue(text.contains("\"interval\" : 240"))
        let json = TuneReport.json([rec]).arrayValue?.first
        XCTAssertEqual(json?["collector"]?.stringValue, "git")
        XCTAssertEqual(json?["configPatch"]?["collectors"]?["git"]?["interval"], .number(240))
    }
}

final class JSONMergeTests: XCTestCase {
    func testDeepMergeReplacesArraysAndScalars() throws {
        let base = try JSONValue.parse(Data(#"{"a": {"b": 1, "c": [1,2]}, "d": "x"}"#.utf8))
        let patch = try JSONValue.parse(Data(#"{"a": {"c": [3], "e": true}, "f": 5}"#.utf8))
        let merged = JSONMerge.merge(base, patch)
        XCTAssertEqual(merged["a"]?["b"], .number(1))
        XCTAssertEqual(merged["a"]?["c"], .array([.number(3)]))
        XCTAssertEqual(merged["a"]?["e"], .bool(true))
        XCTAssertEqual(merged["d"], .string("x"))
        XCTAssertEqual(merged["f"], .number(5))
        XCTAssertEqual(JSONMerge.changedPaths(base, merged), ["a.c", "a.e", "f"])
    }

    func testMergeIntoEmptyAndNonObject() {
        XCTAssertEqual(JSONMerge.merge(.object([:]), .object(["x": .number(1)])), .object(["x": .number(1)]))
        XCTAssertEqual(JSONMerge.merge(.number(1), .object(["x": .number(1)])), .object(["x": .number(1)]))
    }

    func testApplyPatchesWritesBackupAndMergedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("molly-tune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try Data(#"{"server": {"port": 9765}, "collectors": {"git": {"roots": ["~/src"]}}}"#.utf8).write(to: file)
        let recs = [
            Recommendation(severity: .warn, collector: "git", title: "", why: "", configPatch: Tuner.patch("git", ["interval": .number(240)])),
            Recommendation(severity: .info, collector: nil, title: "", why: "", configPatch: nil),
        ]
        let changed = try TuneCommand.applyPatches(recs, to: file)
        XCTAssertEqual(changed, ["collectors.git.interval"])
        let after = try JSONValue.parse(try Data(contentsOf: file))
        XCTAssertEqual(after["collectors"]?["git"]?["interval"], .number(240))
        XCTAssertEqual(after["collectors"]?["git"]?["roots"], .array([.string("~/src")]))
        XCTAssertEqual(after["server"]?["port"], .number(9765))
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".bak-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try TuneCommand.applyPatches([recs[1]], to: file), [])
    }

    func testParsersTolerateMissingFields() {
        let families = TuneCommand.parseFamilies([["name": "molly_up", "series": 1], ["series": 2]])
        XCTAssertEqual(families.map { $0.name }, ["molly_up"])
        let collectors = TuneCommand.parseCollectors([["name": "git", "unavailableSince": 1.0], [:]])
        XCTAssertEqual(collectors.count, 1)
        XCTAssertEqual(collectors[0].unavailableSince, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(TuneCommand.parsePrivacy(["dimensions": [["collector": "browser", "policy": "domains", "other": 3]]]).first?.other, 3)
        XCTAssertTrue(TuneCommand.parsePrivacy(["nope": 1]).isEmpty)
    }
}

final class RegistryStatsTests: XCTestCase {
    func testStatsCountSeriesAndDistinctLabelValues() {
        let r = MetricsRegistry()
        let g = r.gauge("apps", help: "", labels: ["app", "kind"])
        g.set(1, labels: ["app": "a", "kind": "x"])
        g.set(1, labels: ["app": "b", "kind": "x"])
        g.set(1, labels: ["app": "b", "kind": "y"])
        _ = r.counter("empty", help: "")
        let stats = r.stats()
        XCTAssertEqual(stats.map { $0.name }, ["apps", "empty"])
        XCTAssertEqual(stats[0], FamilyStats(name: "apps", type: .gauge, series: 3, labelCardinality: ["app": 2, "kind": 2]))
        XCTAssertEqual(stats[1].series, 0)
    }

    func testSelfCollectorPublishesRegistrySize() throws {
        let r = MetricsRegistry()
        let c = ProcessSelfCollector(settings: CollectorSettings(name: "process", raw: [:]))
        try c.start(registry: r)
        r.gauge("big", help: "", labels: ["k"]).replaceAll(["a": 1, "b": 2], label: "k")
        try c.collect()
        XCTAssertEqual(r.gauge("molly_self_series", help: "", labels: ["family"]).value(labels: ["family": "big"]), 2)
        XCTAssertGreaterThan(r.gauge("molly_self_series_total", help: "").value() ?? 0, 2)
        XCTAssertGreaterThan(r.gauge("molly_self_metric_families", help: "").value() ?? 0, 1)
    }
}
