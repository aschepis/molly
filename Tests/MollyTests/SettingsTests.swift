import XCTest
@testable import Molly

final class ConfigDocumentTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("molly-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var configURL: URL { folder.appendingPathComponent("config.json") }

    func testMissingFileIsEmptyObject() throws {
        let doc = try ConfigDocument(url: configURL)
        XCTAssertEqual(doc.root, .object([:]))
        XCTAssertNil(doc.get(path: ["server", "port"]))
    }

    func testSetCreatesIntermediateObjectsAndNilRemoves() throws {
        var doc = try ConfigDocument(url: configURL)
        doc.set(path: ["collectors", "browser", "domains", "enabled"], .bool(true))
        XCTAssertEqual(doc.get(path: ["collectors", "browser", "domains", "enabled"]), .bool(true))
        doc.set(path: ["collectors", "browser", "domains", "enabled"], nil)
        XCTAssertEqual(doc.get(path: ["collectors", "browser", "domains"]), .object([:]))
        doc.set(path: [], .bool(true))
        XCTAssertNotNil(doc.root.objectValue, "empty path must be ignored")
    }

    func testSetReplacesNonObjectInTheWay() throws {
        var doc = ConfigDocument(url: configURL, root: .object(["server": .string("oops")]))
        doc.set(path: ["server", "port"], .number(1234))
        XCTAssertEqual(doc.get(path: ["server", "port"])?.intValue, 1234)
    }

    func testSaveKeepsUnknownKeysSortsAndValidates() throws {
        try Data(#"{"zeta": {"custom": 1}, "server": {"port": 9000}, "alpha": true}"#.utf8).write(to: configURL)
        var doc = try ConfigDocument(url: configURL)
        doc.set(path: ["server", "bind"], .string("0.0.0.0"))
        try doc.save()
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"custom\" : 1") || text.contains("\"custom\": 1"))
        let alpha = text.range(of: "\"alpha\"")!.lowerBound
        let server = text.range(of: "\"server\"")!.lowerBound
        let zeta = text.range(of: "\"zeta\"")!.lowerBound
        XCTAssertTrue(alpha < server && server < zeta, "keys must be sorted")
        XCTAssertTrue(text.hasSuffix("\n"))
        let reparsed = try Config.load(from: configURL)
        XCTAssertEqual(reparsed.server.bind, "0.0.0.0")
        XCTAssertEqual(reparsed.server.port, 9000)
    }

    func testSaveRefusesInvalidConfigAndLeavesFileUntouched() throws {
        let original = Data(#"{"server": {"port": 9000}}"#.utf8)
        try original.write(to: configURL)
        var doc = try ConfigDocument(url: configURL)
        doc.set(path: ["server", "port"], .number(0))
        XCTAssertThrowsError(try doc.save())
        XCTAssertEqual(try Data(contentsOf: configURL), original)
        XCTAssertTrue(ConfigDocument.backups(of: configURL).isEmpty, "no backup for a refused save")
    }

    func testSaveWritesBackupAndCapsThem() throws {
        try Data("{}".utf8).write(to: configURL)
        var doc = try ConfigDocument(url: configURL)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<(ConfigDocument.maxBackups + 3) {
            doc.set(path: ["logLevel"], .string(i % 2 == 0 ? "info" : "debug"))
            try doc.save(now: base.addingTimeInterval(Double(i)))
        }
        let backups = ConfigDocument.backups(of: configURL)
        XCTAssertEqual(backups.count, ConfigDocument.maxBackups)
        XCTAssertEqual(backups.first?.lastPathComponent, ConfigDocument.backupName(for: base.addingTimeInterval(3)))
        XCTAssertEqual(backups.last?.lastPathComponent, ConfigDocument.backupName(for: base.addingTimeInterval(12)))
        let previous = try String(contentsOf: backups.last!, encoding: .utf8)
        XCTAssertTrue(previous.contains("debug"), "the newest backup holds the previous save")
    }

    func testBackupNameFormat() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 3; comps.hour = 14; comps.minute = 5; comps.second = 9
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(ConfigDocument.backupName(for: date), "config.json.bak-20261103-140509")
    }

    func testRejectsNonObjectFile() throws {
        try Data("[1,2]".utf8).write(to: configURL)
        XCTAssertThrowsError(try ConfigDocument(url: configURL))
    }
}

final class StackConfigTests: XCTestCase {
    func testPrometheusDurations() {
        for ok in ["2y", "90d", "26w", "12h", "30m", "1h30m", "500ms"] {
            XCTAssertTrue(PrometheusDuration.isValid(ok), ok)
        }
        for bad in ["", "2", "y", "2 y", "2years", "-1d", "1.5d"] {
            XCTAssertFalse(PrometheusDuration.isValid(bad), bad)
        }
    }

    func testStackSectionParsesAndValidates() throws {
        let config = try Config.parse(Data(#"{"stack": {"retention": "90d", "composeDir": "~/src/molly/deploy"}}"#.utf8))
        XCTAssertEqual(config.stack.retention, "90d")
        XCTAssertEqual(config.stack.composeDir, "~/src/molly/deploy")
        XCTAssertEqual(try Config.parse(Data("{}".utf8)).stack, Config.Stack())
        XCTAssertNil(try Config.parse(Data(#"{"stack": {"composeDir": ""}}"#.utf8)).stack.composeDir)
        XCTAssertThrowsError(try Config.parse(Data(#"{"stack": {"retention": "forever"}}"#.utf8)))
        XCTAssertThrowsError(try Config.parse(Data(#"{"stack": []}"#.utf8)))
    }
}

final class CatalogTests: XCTestCase {
    private var collectorsFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Molly/Collectors")
    }

    func testCollectorCatalogCoversRegistry() {
        let names = Set(CollectorCatalog.all.map { $0.name })
        XCTAssertEqual(names, CollectorRegistry.knownNames)
        XCTAssertEqual(CollectorCatalog.optIn, CollectorRegistry.disabledByDefault)
        XCTAssertEqual(CollectorCatalog.all.count, names.count, "no duplicate rows")
    }

    func testPermissionLinksOpenSystemSettings() {
        for permission in Permission.allCases where permission != .none {
            let url = permission.settingsURL
            XCTAssertEqual(url?.scheme, "x-apple.systempreferences", permission.rawValue)
            XCTAssertTrue(url?.absoluteString.contains("Privacy_") ?? false, permission.rawValue)
        }
        XCTAssertNil(Permission.none.settingsURL)
    }

    /// Scans the collector sources so a new `filter("...")` call without a
    /// catalog row, or one with an inline default, fails here.
    func testPrivacyCatalogCoversEveryFilterCall() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: collectorsFolder.path).filter { $0.hasSuffix("Collector.swift") }
        XCTAssertGreaterThan(files.count, 20, "collector sources not found at \(collectorsFolder.path)")
        let call = try NSRegularExpression(pattern: #"filter\("([a-z_]+)""#)
        let explicit = try NSRegularExpression(pattern: #"collector\("([a-z_]+)"\)\.filter"#)
        let staticDefault = try NSRegularExpression(pattern: #"defaults: [A-Za-z]+Collector\.[a-z]+Defaults\)"#)
        var seen: Set<String> = []
        for file in files {
            let text = try String(contentsOf: collectorsFolder.appendingPathComponent(file), encoding: .utf8)
            let fileCollector = CatalogTests.collectorName(forFile: file)
            for line in text.split(separator: "\n").map(String.init) {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = call.firstMatch(in: line, range: range),
                      let keyRange = Range(match.range(at: 1), in: line) else { continue }
                let key = String(line[keyRange])
                var collector = fileCollector
                if let m = explicit.firstMatch(in: line, range: range), let r = Range(m.range(at: 1), in: line) {
                    collector = String(line[r])
                }
                let id = "\(collector).\(key)"
                XCTAssertNotNil(PrivacyCatalog.dimension(id), "\(file): no PrivacyCatalog row for \(id)")
                XCTAssertNotNil(staticDefault.firstMatch(in: line, range: range),
                                "\(file): \(id) must pass a static <Collector>.<key>Defaults so the catalog shares it")
                seen.insert(id)
            }
        }
        for dimension in PrivacyCatalog.all {
            XCTAssertTrue(seen.contains(dimension.id), "catalog row \(dimension.id) has no filter call")
        }
        XCTAssertEqual(PrivacyCatalog.all.count, 18)
    }

    static func collectorName(forFile file: String) -> String {
        let overrides = ["process_self": "process"]
        let stem = file.replacingOccurrences(of: "Collector.swift", with: "")
        var snake = ""
        for (i, ch) in stem.enumerated() {
            if ch.isUppercase && i > 0 { snake.append("_") }
            snake.append(ch.lowercased())
        }
        return overrides[snake] ?? snake
    }

    func testCatalogDefaultsMatchCollectors() {
        XCTAssertEqual(PrivacyCatalog.dimension("browser.domains")?.defaults, BrowserCollector.domainsDefaults)
        XCTAssertEqual(PrivacyCatalog.dimension("shell.commands")?.defaults.mode, .allowlist)
        XCTAssertEqual(PrivacyCatalog.dimension("titles.titles")?.defaults.hash, true)
        XCTAssertFalse(PrivacyCatalog.dimension("browser.domains")?.defaults.enabled ?? true)
    }

    func testPresetsMatchConfigFiles() throws {
        let configFolder = collectorsFolder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config")
        let files: [SettingsModel.Preset: String] = [.strict: "molly.privacy-strict.json", .balanced: "molly.example.json", .developer: "molly.developer.json"]
        for (preset, name) in files {
            let onDisk = try JSONValue.parse(Data(contentsOf: configFolder.appendingPathComponent(name)))
            let embedded = try JSONValue.parse(Data(Presets.json(preset).utf8))
            XCTAssertEqual(embedded, onDisk, "\(name) changed: run scripts/generate-presets.py")
        }
    }
}

final class SettingsModelTests: XCTestCase {
    private var folder: URL!
    private var reloads = 0
    private var pauses = 0

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("molly-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("state"), withIntermediateDirectories: true)
        reloads = 0
        pauses = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeModel(_ json: String = "{}") throws -> SettingsModel {
        let url = folder.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: url)
        return try SettingsModel.load(url: url, stateFolder: folder.appendingPathComponent("state"),
                                      reload: { self.reloads += 1 },
                                      pauseCollectors: { self.pauses += 1 },
                                      collectorStatuses: { [CollectorManager.Status(name: "browser", interval: 60, unavailable: true)] })
    }

    func testDefaultsComeFromCatalogsWhenFileIsEmpty() throws {
        let model = try makeModel()
        XCTAssertTrue(model.collectorEnabled("browser"))
        XCTAssertFalse(model.collectorEnabled("titles"))
        XCTAssertEqual(model.collectorInterval("calendar"), 300)
        XCTAssertEqual(model.policy(PrivacyCatalog.dimension("browser.domains")!), BrowserCollector.domainsDefaults)
        XCTAssertEqual(model.serverPort, 9765)
        XCTAssertEqual(model.retention, "2y")
        XCTAssertTrue(model.retentionIsValid)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.status(of: "browser")?.unavailable, true)
    }

    func testEditsMarkDirtyAndApplySavesAndReloads() throws {
        let model = try makeModel()
        model.setCollectorEnabled("browser", false)
        model.setCollectorInterval("focus", 2.6)
        model.serverPort = 9800
        XCTAssertTrue(model.isDirty)
        XCTAssertNil(model.validationError)
        XCTAssertTrue(model.apply())
        XCTAssertEqual(reloads, 1)
        XCTAssertFalse(model.isDirty)
        let saved = try Config.load(from: model.document.url)
        XCTAssertFalse(saved.collector("browser").enabled())
        XCTAssertEqual(saved.collector("focus").interval(default: 5), 3)
        XCTAssertEqual(saved.server.port, 9800)
    }

    func testInvalidEditIsReportedNotSaved() throws {
        let model = try makeModel()
        model.serverPort = 70000
        XCTAssertNotNil(model.validationError)
        XCTAssertFalse(model.apply())
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(reloads, 0)
        model.revert()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.serverPort, 9765)
    }

    func testPolicyEditsWriteTheExpectedKeys() throws {
        let model = try makeModel()
        let domains = PrivacyCatalog.dimension("browser.domains")!
        model.setPolicyEnabled(domains, true)
        model.setPolicyMode(domains, .allowlist)
        model.setPolicyPatterns(domains, [" github.com ", "", "*.apple.com"])
        model.setPolicyHash(domains, true)
        model.setPolicyMaxCardinality(domains, -3)
        let policy = model.policy(domains)
        XCTAssertTrue(policy.enabled)
        XCTAssertEqual(policy.mode, .allowlist)
        XCTAssertEqual(policy.patterns, ["github.com", "*.apple.com"])
        XCTAssertTrue(policy.hash)
        XCTAssertEqual(policy.maxCardinality, 0)
        XCTAssertFalse(model.hasSalt(domains))
        model.regenerateSalt(domains)
        XCTAssertTrue(model.hasSalt(domains))
        XCTAssertEqual(model.get(domains.path + ["salt"])?.stringValue?.count, 32)
        model.setSalt(domains, "")
        XCTAssertFalse(model.hasSalt(domains))
    }

    func testMalformedPolicyFallsBackToDefaults() throws {
        let model = try makeModel(#"{"collectors": {"browser": {"domains": {"enabled": "yes"}}}}"#)
        XCTAssertEqual(model.policy(PrivacyCatalog.dimension("browser.domains")!), BrowserCollector.domainsDefaults)
        XCTAssertNotNil(model.validationError)
        model.serverPort = 9001
        XCTAssertFalse(model.apply(), "a malformed policy must block Apply, not just reload")
        XCTAssertEqual(reloads, 0)
    }

    func testSecretsAreWriteOnly() throws {
        let model = try makeModel()
        XCTAssertFalse(model.hasInsightsAPIKey)
        model.setInsightsAPIKey("sk-test")
        XCTAssertTrue(model.hasInsightsAPIKey)
        model.setInsightsAPIKey("")
        XCTAssertFalse(model.hasInsightsAPIKey)
        XCTAssertNil(model.get(["collectors", "insights", "apiKey"]))
        model.eventsToken = "abc"
        XCTAssertEqual(model.eventsToken, "abc")
        model.eventsToken = ""
        XCTAssertNil(model.get(["collectors", "events", "token"]))
    }

    func testTypedAccessorsRoundTrip() throws {
        let model = try makeModel()
        model.serverBind = "0.0.0.0"
        model.grafanaURL = "http://g:1"
        model.prometheusURL = "http://p:2"
        model.logLevel = "debug"
        model.setExtraLabel("env", "laptop")
        model.insightsEnabled = true
        model.insightsBackend = "cli"
        model.insightsModel = "claude-opus-5-5"
        model.insightsDailyHour = 30
        model.insightsWeekly = false
        model.mcpPrometheusURL = "http://m:3"
        model.retention = " 90d "
        model.composeDir = "~/x/deploy"
        XCTAssertEqual(model.serverBind, "0.0.0.0")
        XCTAssertEqual(model.grafanaURL, "http://g:1")
        XCTAssertEqual(model.prometheusURL, "http://p:2")
        XCTAssertEqual(model.logLevel, "debug")
        XCTAssertEqual(model.extraLabels, ["env": "laptop"])
        XCTAssertTrue(model.insightsEnabled)
        XCTAssertEqual(model.insightsBackend, "cli")
        XCTAssertEqual(model.insightsModel, "claude-opus-5-5")
        XCTAssertEqual(model.insightsDailyHour, 23)
        XCTAssertFalse(model.insightsWeekly)
        XCTAssertEqual(model.mcpPrometheusURL, "http://m:3")
        XCTAssertEqual(model.retention, "90d")
        XCTAssertEqual(model.composeDir, "~/x/deploy")
        XCTAssertEqual(model.effectiveComposeDir?.path, Paths.expand("~/x/deploy"))
        model.setExtraLabel("env", nil)
        XCTAssertEqual(model.extraLabels, [:])
        model.mcpPrometheusURL = ""
        XCTAssertEqual(model.mcpPrometheusURL, "http://p:2", "empty falls back to the Prometheus link")
        XCTAssertTrue(model.apply())
    }

    func testApplyPresetCopiesFlagsAndPoliciesButKeepsSalt() throws {
        let model = try makeModel(#"{"collectors": {"browser": {"interval": 7, "domains": {"salt": "keep-me"}}}}"#)
        model.applyPreset(.strict)
        let strict = try JSONValue.parse(Data(Presets.json(.strict).utf8))
        let strictDomains = strict.objectValue!["collectors"]!.objectValue!["browser"]!.objectValue!["domains"]!.objectValue!
        let domains = PrivacyCatalog.dimension("browser.domains")!
        XCTAssertEqual(model.policy(domains).enabled, strictDomains["enabled"]?.boolValue)
        XCTAssertEqual(model.get(domains.path + ["salt"])?.stringValue, "keep-me")
        XCTAssertEqual(model.collectorInterval("browser"), 7, "presets leave intervals alone")
        for name in CollectorRegistry.knownNames {
            if let flag = strict.objectValue!["collectors"]!.objectValue![name]?.objectValue?["enabled"]?.boolValue {
                XCTAssertEqual(model.collectorEnabled(name), flag, name)
            }
        }
        XCTAssertNil(model.validationError)
    }

    func testForgetDataPausesDeletesAndReloads() throws {
        let model = try makeModel()
        let state = folder.appendingPathComponent("state")
        try Data("{}".utf8).write(to: state.appendingPathComponent("browser.json"))
        try Data("{}".utf8).write(to: state.appendingPathComponent("git.json"))
        XCTAssertEqual(Set(model.stateFiles.keys), ["browser", "git"])
        model.forgetData(collector: "browser")
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(Set(model.stateFiles.keys), ["git"])
        XCTAssertNil(model.lastError)
        model.forgetData(collector: "nothing")
        XCTAssertEqual(model.lastMessage, "nothing had no stored data")
        model.forgetAllData()
        XCTAssertTrue(model.stateFiles.isEmpty)
        XCTAssertEqual(reloads, 3)
    }

    func testApplyRetentionSavesWritesEnvAndRunsCompose() throws {
        let model = try makeModel()
        let deploy = folder.appendingPathComponent("deploy")
        try FileManager.default.createDirectory(at: deploy, withIntermediateDirectories: true)
        try Data("services: {}\n".utf8).write(to: deploy.appendingPathComponent("docker-compose.yml"))
        try "OTHER=1\nPROMETHEUS_RETENTION=2y\n".write(to: deploy.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        model.retention = "90d"
        model.composeDir = deploy.path
        var ran: [String] = []
        let done = expectation(description: "compose")
        model.applyRetention(run: { cmd, args, dir in
            ran = [cmd] + args + [dir]
            return "recreated"
        }, queue: .global(), completion: { result in
            if case .success(let output) = result {
                XCTAssertTrue(output.contains("recreated"))
            } else {
                XCTFail("expected success, got \(result)")
            }
            done.fulfill()
        })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(ran, ["docker", "compose", "up", "-d", "prometheus", deploy.path])
        XCTAssertEqual(try String(contentsOf: deploy.appendingPathComponent(".env"), encoding: .utf8), "OTHER=1\nPROMETHEUS_RETENTION=90d\n")
        XCTAssertEqual(try Config.load(from: model.document.url).stack.retention, "90d")
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(model.lastMessage, "Prometheus retention set to 90d")
    }

    func testApplyRetentionRejectsBadDurationWithoutSaving() throws {
        let model = try makeModel()
        model.retention = "soon"
        let done = expectation(description: "fail")
        model.applyRetention(run: { _, _, _ in XCTFail("must not run"); return "" }, completion: { result in
            if case .success = result { XCTFail("expected failure") }
            done.fulfill()
        })
        wait(for: [done], timeout: 1)
        XCTAssertEqual(reloads, 0)
        XCTAssertNotNil(model.lastError)
    }
}

final class MaintenanceTests: XCTestCase {
    func testRewriteEnvReplacesOrAppends() {
        XCTAssertEqual(Maintenance.rewriteEnv("", retention: "30d"), "PROMETHEUS_RETENTION=30d\n")
        XCTAssertEqual(Maintenance.rewriteEnv("A=1\n", retention: "30d"), "A=1\nPROMETHEUS_RETENTION=30d\n")
        XCTAssertEqual(Maintenance.rewriteEnv("A=1\nPROMETHEUS_RETENTION=2y\nB=2", retention: "30d"),
                       "A=1\nPROMETHEUS_RETENTION=30d\nB=2\n")
    }

    func testWriteRetentionValidates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("molly-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try Maintenance.writeRetention("never", composeDir: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".env").path))
        let env = try Maintenance.writeRetention("1y", composeDir: dir)
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "PROMETHEUS_RETENTION=1y\n")
    }

    func testApplyRetentionNeedsComposeFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("molly-nocompose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try Maintenance.applyRetention("1y", composeDir: dir, run: { _, _, _ in "" }))
    }

    func testForgetOnlyTouchesJSONFilesOfThatCollector() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("molly-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("browser.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("notes.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("README"))
        XCTAssertEqual(Set(Maintenance.stateFiles(folder: dir).keys), ["browser", "notes"])
        XCTAssertEqual(try Maintenance.forget(collector: "browser", folder: dir).count, 1)
        XCTAssertEqual(try Maintenance.forget(collector: "browser", folder: dir).count, 0)
        XCTAssertEqual(try Maintenance.forgetAll(folder: dir).map { $0.lastPathComponent }, ["notes.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README").path))
    }
}
