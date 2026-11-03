import XCTest
@testable import Molly

final class ConfigTests: XCTestCase {
    func testDefaultsWhenEmpty() throws {
        let c = try Config.parse(Data("{}".utf8))
        XCTAssertEqual(c.server, Config.Server(bind: "127.0.0.1", port: 9765))
        XCTAssertEqual(c.constLabels["user"], NSUserName())
        XCTAssertFalse(c.constLabels["host"]!.isEmpty)
        XCTAssertFalse(c.constLabels["host"]!.contains("."))
        XCTAssertTrue(c.collector("anything").isEmpty)
        XCTAssertTrue(c.collector("anything").enabled())
        XCTAssertFalse(c.collector("anything").enabled(default: false))
    }

    func testMissingFileIsDefaults() throws {
        let c = try Config.load(from: URL(fileURLWithPath: "/nonexistent/molly.json"))
        XCTAssertEqual(c.server.port, 9765)
    }

    func testParsesEverySection() throws {
        let json = """
        {
          "server": {"bind": "0.0.0.0", "port": 9000},
          "labels": {"user": "u", "host": "h", "extra": {"env": "work"}},
          "links": {"grafana": "http://g:1", "prometheus": "http://p:2"},
          "logLevel": "debug",
          "collectors": {
            "browser": {"enabled": false, "interval": 120, "domains": {"enabled": true, "patterns": ["x.com"]}, "paths": ["a", "b"]}
          }
        }
        """
        let c = try Config.parse(Data(json.utf8))
        XCTAssertEqual(c.server, Config.Server(bind: "0.0.0.0", port: 9000))
        XCTAssertEqual(c.constLabels, ["user": "u", "host": "h", "env": "work"])
        XCTAssertEqual(c.links.grafana, "http://g:1")
        XCTAssertEqual(c.logLevel, "debug")
        let browser = c.collector("browser")
        XCTAssertFalse(browser.enabled())
        XCTAssertEqual(browser.interval(default: 60), 120)
        XCTAssertEqual(browser.strings("paths"), ["a", "b"])
        XCTAssertEqual(try browser.policy("domains").patterns, ["x.com"])
        XCTAssertTrue(try browser.filter("domains").enabled)
        XCTAssertEqual(try browser.policy("missing", defaults: LabelPolicy(enabled: true)).enabled, true)
    }

    func testMCPSectionDefaultsToStackAndServer() throws {
        let defaults = try Config.parse(Data(#"{"server": {"port": 9000}, "links": {"prometheus": "http://p:2"}}"#.utf8))
        XCTAssertEqual(defaults.mcpPrometheusURL, "http://p:2")
        XCTAssertEqual(defaults.mcpMollyURL, "http://127.0.0.1:9000")
        let explicit = try Config.parse(Data(#"{"mcp": {"prometheusURL": "http://x:1", "mollyURL": "http://y:2"}}"#.utf8))
        XCTAssertEqual(explicit.mcpPrometheusURL, "http://x:1")
        XCTAssertEqual(explicit.mcpMollyURL, "http://y:2")
        XCTAssertThrowsError(try Config.parse(Data(#"{"mcp": {"prometheusURL": ""}}"#.utf8)))
        XCTAssertThrowsError(try Config.parse(Data(#"{"mcp": []}"#.utf8)))
    }

    func testSettingsGettersFallBack() throws {
        let c = try Config.parse(Data(#"{"collectors": {"x": {"interval": -5, "n": 2.5, "s": 7}}}"#.utf8))
        let x = c.collector("x")
        XCTAssertEqual(x.interval(default: 30), 30)
        XCTAssertEqual(x.int("n", default: 1), 1)
        XCTAssertEqual(x.double("n", default: 1), 2.5)
        XCTAssertEqual(x.string("s", default: "d"), "d")
        XCTAssertEqual(x.bool("missing", default: true), true)
        XCTAssertTrue(x.section("sub").isEmpty)
    }

    func testRejectsBadValues() {
        for bad in [
            #"[]"#,
            #"{"server": {"port": 70000}}"#,
            #"{"server": {"bind": 1}}"#,
            #"{"labels": {"extra": {"bad-name": "x"}}}"#,
            #"{"labels": {"extra": {"ok": 1}}}"#,
            #"{"logLevel": "loud"}"#,
            #"{"collectors": {"x": 1}}"#,
            #"{"collectors": {"x": {"domains": {"mode": "no"}}}}"#,
            "not json",
        ] {
            let data = Data(bad.utf8)
            if let c = try? Config.parse(data) {
                XCTAssertThrowsError(try c.collector("x").policy("domains"), bad)
            }
        }
    }

    func testPolicyErrorNamesTheSection() throws {
        let c = try Config.parse(Data(#"{"collectors": {"x": {"domains": {"mode": "no"}}}}"#.utf8))
        XCTAssertThrowsError(try c.collector("x").policy("domains")) { error in
            XCTAssertTrue("\(error)".contains("collectors.x.domains"), "\(error)")
        }
    }
}
