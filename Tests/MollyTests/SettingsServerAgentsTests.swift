import XCTest
@testable import Molly

final class SettingsServerAgentsTests: XCTestCase {
    func testLabelNameValidation() {
        XCTAssertNil(ServerRules.labelNameError("team"))
        XCTAssertNil(ServerRules.labelNameError("_rack_2"))
        XCTAssertNotNil(ServerRules.labelNameError(""))
        XCTAssertNotNil(ServerRules.labelNameError("2fast"))
        XCTAssertNotNil(ServerRules.labelNameError("my-label"))
        XCTAssertNotNil(ServerRules.labelNameError("user"))
        XCTAssertNotNil(ServerRules.labelNameError("host"))
    }

    func testOpenBindWarningOnlyWithoutTokenOffLoopback() {
        XCTAssertNil(ServerRules.openBindWarning(bind: "127.0.0.1", token: ""))
        XCTAssertNil(ServerRules.openBindWarning(bind: "localhost", token: ""))
        XCTAssertNil(ServerRules.openBindWarning(bind: "0.0.0.0", token: "abc"))
        XCTAssertNotNil(ServerRules.openBindWarning(bind: "0.0.0.0", token: ""))
    }

    func testAnyRemoteBindWarnsWithoutToken() {
        XCTAssertNil(ServerRules.openBindWarning(binds: ["127.0.0.1", "::1"], token: ""))
        let warning = ServerRules.openBindWarning(binds: ["127.0.0.1", "100.64.0.1"], token: "")
        XCTAssertTrue(warning?.contains("100.64.0.1") == true)
        XCTAssertNil(ServerRules.openBindWarning(binds: ["127.0.0.1", "100.64.0.1"], token: "abc"))
    }

    func testBindListParsingAndFormatting() {
        XCTAssertEqual(ServerRules.parseBindList(" 127.0.0.1 ,100.64.0.1\n"), ["127.0.0.1", "100.64.0.1"])
        XCTAssertEqual(ServerRules.parseBindList(" , "), [])
        XCTAssertEqual(ServerRules.formatBindList(["127.0.0.1", "100.64.0.1"]), "127.0.0.1, 100.64.0.1")
    }

    func testURLsAndToken() {
        XCTAssertEqual(ServerRules.metricsURL(bind: "127.0.0.1", port: 9765), "http://127.0.0.1:9765/metrics")
        XCTAssertEqual(ServerRules.insightsURL(bind: "127.0.0.1", port: 9765), "http://127.0.0.1:9765/insights/latest")
        let token = ServerRules.randomToken()
        XCTAssertEqual(token.count, 32)
        XCTAssertNotNil(token.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertNotEqual(token, ServerRules.randomToken())
    }

    func testMCPCommandQuotesBinary() {
        let command = AgentsRules.mcpAddCommand(binary: "/Applications/Molly.app/Contents/MacOS/molly")
        XCTAssertEqual(command, "claude mcp add molly -- \"/Applications/Molly.app/Contents/MacOS/molly\" mcp")
    }

    func testPatchLeavesFlattenObjectsAndKeepArrays() {
        let patch: JSONValue = .object([
            "collectors": .object([
                "browser": .object(["domains": .object(["patterns": .array([.string("*.example.com")]), "enabled": .bool(true)])]),
                "codex": .object(["enabled": .bool(false)]),
            ]),
        ])
        let leaves = AgentsRules.leaves(patch)
        XCTAssertEqual(leaves.map { $0.path.joined(separator: ".") }, [
            "collectors.browser.domains.enabled",
            "collectors.browser.domains.patterns",
            "collectors.codex.enabled",
        ])
        XCTAssertEqual(leaves[1].value, .array([.string("*.example.com")]))
        XCTAssertTrue(AgentsRules.leaves(.object([:])).isEmpty)
    }

    func testStagingRecommendationsEditsTheModelWithoutSaving() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("config.json")
        let model = SettingsModel(document: try ConfigDocument(url: url), stateFolder: folder, reload: {})
        let rec = Recommendation(severity: .info, collector: "codex", title: "t", why: "w",
                                 configPatch: .object(["collectors": .object(["codex": .object(["enabled": .bool(false)])])]))
        let manual = Recommendation(severity: .warn, collector: nil, title: "m", why: "w", configPatch: nil)
        let paths = AgentsRules.stage([rec, manual], into: model)
        XCTAssertEqual(paths, ["collectors.codex.enabled"])
        XCTAssertFalse(model.collectorEnabled("codex"))
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testGatherWithoutFallbackThrowsWhenDaemonIsDown() throws {
        let config = try Config.parse(Data(#"{"server": {"bind": "127.0.0.1", "port": 1}}"#.utf8))
        XCTAssertThrowsError(try TuneCommand.gather(config: config, inProcessFallback: false)) { error in
            XCTAssertTrue(error is TuneCommand.StatsUnavailable)
        }
    }
}
