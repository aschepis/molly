import XCTest
@testable import Molly

/// Canned Prometheus answers keyed by a substring of the PromQL.
private final class FakeSource: MetricsQuerying {
    var vectors: [(contains: String, samples: [PrometheusClient.Sample])] = []
    var matrices: [PrometheusClient.Series] = []
    var mollyPages: [String: String] = [:]
    var queries: [String] = []
    var failWith: Error?

    func sample(_ value: Double, _ labels: [String: String] = [:]) -> PrometheusClient.Sample {
        PrometheusClient.Sample(labels: labels, timestamp: Date(), value: value)
    }

    func query(_ promql: String, at: Date?) throws -> [PrometheusClient.Sample] {
        queries.append(promql)
        if let failWith { throw failWith }
        return vectors.first { promql.contains($0.contains) }?.samples ?? []
    }

    func queryRange(_ promql: String, from: Date, to: Date, step: TimeInterval) throws -> [PrometheusClient.Series] {
        queries.append("range:\(promql):\(Int(step))")
        if let failWith { throw failWith }
        return matrices
    }

    func fetchMolly(_ path: String) throws -> String {
        guard let page = mollyPages[path] else { throw LiveMetricsSource.SourceError.mollyUnreachable(path) }
        return page
    }
}

private struct Boom: Error {}

final class MCPServerTests: XCTestCase {
    private var source: FakeSource!
    private var server: MCPServer!

    override func setUp() {
        source = FakeSource()
        server = MCPServer(tools: MCPTools.all(source: source))
    }

    private func json(_ line: String?) -> [String: Any] {
        guard let line, let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            XCTFail("not a JSON object: \(line ?? "nil")")
            return [:]
        }
        return object
    }

    func testInitializeEchoesSupportedVersionAndAdvertisesTools() {
        let response = json(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#))
        let result = response["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "molly")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])

        let unknownVersion = json(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual(((unknownVersion["result"] as? [String: Any])?["protocolVersion"]) as? String, "2025-06-18")
    }

    func testNotificationsAndBlankLinesProduceNoOutput() {
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.handle(line: "   "))
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"ping"}"#), "a ping without an id is a notification")
    }

    func testToolsListNamesEveryTool() {
        let response = json(server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        let tools = (response["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["query_metrics", "list_metrics", "day_summary", "current_context", "collector_status"])
        XCTAssertEqual((tools[0]["inputSchema"] as? [String: Any])?["required"] as? [String], ["promql"])
    }

    func testProtocolErrors() {
        XCTAssertEqual((json(server.handle(line: "{not json"))["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual((json(server.handle(line: "[1,2]"))["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual((json(server.handle(line: #"{"jsonrpc":"2.0","id":4}"#))["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual((json(server.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"nope"}"#))["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((json(server.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{}}"#))["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual((json(server.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"missing"}}"#))["error"] as? [String: Any])?["code"] as? Int, -32602)
        let ping = json(server.handle(line: #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#))
        XCTAssertNotNil(ping["result"])
    }

    private func callText(_ name: String, _ arguments: String = "{}") -> (String, Bool) {
        let response = json(server.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#))
        let result = response["result"] as? [String: Any] ?? [:]
        let content = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (content, result["isError"] as? Bool ?? false)
    }

    func testQueryMetricsInstantAndRange() {
        source.vectors = [("molly_up", [source.sample(1, ["__name__": "molly_up", "user": "u", "host": "h"])])]
        let (instant, instantError) = callText("query_metrics", #"{"promql":"molly_up"}"#)
        XCTAssertFalse(instantError)
        XCTAssertTrue(instant.hasPrefix(MCPToolResult.framing), instant)
        XCTAssertTrue(instant.contains("molly_up 1"), instant)

        source.matrices = [PrometheusClient.Series(labels: ["app": "safari"], points: [(Date(timeIntervalSince1970: 0), 2.5)])]
        let (range, _) = callText("query_metrics", #"{"promql":"molly_focus_app","range_minutes":30}"#)
        XCTAssertTrue(range.contains("{app=\"safari\"}"), range)
        XCTAssertTrue(range.contains("=2.5"), range)
        XCTAssertTrue(source.queries.contains { $0.hasPrefix("range:molly_focus_app:30") }, "\(source.queries)")

        let (missing, missingError) = callText("query_metrics", "{}")
        XCTAssertTrue(missingError)
        XCTAssertTrue(missing.contains("promql"))

        source.failWith = Boom()
        let (failed, failedError) = callText("query_metrics", #"{"promql":"x"}"#)
        XCTAssertTrue(failedError)
        XCTAssertTrue(failed.contains("query failed"))
    }

    func testListMetricsPrefersLiveExpositionAndFiltersByPrefix() {
        source.mollyPages["/metrics"] = """
        # HELP molly_up 1 while Molly is running.
        # TYPE molly_up gauge
        molly_up 1
        # HELP molly_git_repos Repos found.
        # TYPE molly_git_repos gauge
        molly_git_repos 3
        """
        let (all, _) = callText("list_metrics")
        XCTAssertTrue(all.contains("molly_up  gauge  1 while Molly is running."), all)
        XCTAssertTrue(all.contains("molly_git_repos  gauge  Repos found."), all)
        let (filtered, _) = callText("list_metrics", #"{"prefix":"molly_git"}"#)
        XCTAssertFalse(filtered.contains("molly_up "), filtered)
        XCTAssertTrue(filtered.contains("molly_git_repos"), filtered)
    }

    func testListMetricsFallsBackToCatalogWhenMollyIsDown() {
        let (text, isError) = callText("list_metrics", #"{"prefix":"molly_focus_app"}"#)
        if MCPTools.catalogText() == nil {
            XCTAssertTrue(isError)
        } else {
            XCTAssertFalse(isError)
            XCTAssertTrue(text.contains("docs/METRICS.md"), text)
            XCTAssertTrue(text.contains("molly_focus_app"), text)
        }
    }

    func testCollectorStatusReportsUnreachableMolly() {
        let (down, downError) = callText("collector_status")
        XCTAssertTrue(downError)
        XCTAssertTrue(down.contains("unreachable"), down)
        source.mollyPages["/collectors"] = #"{"paused":false}"#
        let (up, upError) = callText("collector_status")
        XCTAssertFalse(upError)
        XCTAssertTrue(up.contains("\"paused\""), up)
    }

    func testDaySummaryRejectsBadDate() {
        let (text, isError) = callText("day_summary", #"{"date":"yesterday"}"#)
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("YYYY-MM-DD"))
    }
}

final class DaySummaryTests: XCTestCase {
    func testParseDay() {
        XCTAssertNil(DaySummary.parseDay(nil))
        XCTAssertNil(DaySummary.parseDay("2026-13-40"))
        let day = DaySummary.parseDay("2026-11-03")
        XCTAssertNotNil(day)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: day!)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 11, 3, 0])
    }

    func testRenderUsesDayWindowAndFormatsSections() {
        let source = FakeSource()
        source.vectors = [
            ("molly_active_seconds_total", [source.sample(7200)]),
            ("molly_idle_seconds_total", [source.sample(1800)]),
            ("molly_focus_switches_total", [source.sample(42)]),
            ("molly_focus_seconds_total", [source.sample(3600, ["app": "xcode"]), source.sample(600, ["app": "slack"]), source.sample(0, ["app": "finder"])]),
            ("molly_git_commits_total{author", [source.sample(3, ["repo": "aschepis/molly"])]),
            ("molly_claude_estimated_cost_usd_total", [source.sample(1.5)]),
            ("molly_claude_tokens_total", [source.sample(1000, ["kind": "output"])]),
            ("molly_claude_tool_calls_total", [source.sample(12)]),
            ("molly_messages_total", [source.sample(4, ["direction": "sent"])]),
            ("molly_meeting_seconds_total", [source.sample(1800)]),
            ("molly_meetings_total", [source.sample(2)]),
            ("molly_cpu_utilization_ratio", [source.sample(0.25)]),
        ]
        // A fixed "now" in the middle of a day so the window is partial.
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let text = DaySummary(source: source, now: { noon }).render(day: nil)
        XCTAssertTrue(text.contains("(covering 12h 0m)"), text)
        XCTAssertTrue(text.contains("Active: 2.0h, idle: 0.5h"), text)
        XCTAssertTrue(text.contains("App switches: 42"), text)
        XCTAssertTrue(text.contains("Top apps: xcode 1.0h, slack 0.2h"), text)
        XCTAssertFalse(text.contains("finder"), "zero rows are dropped")
        XCTAssertTrue(text.contains("Commits: aschepis/molly 3"), text)
        XCTAssertTrue(text.contains("Claude: $1.50 estimated, 12 tool calls, tokens output 1000"), text)
        XCTAssertTrue(text.contains("Messages: sent 4"), text)
        XCTAssertTrue(text.contains("Meetings: 2 totalling 30 min"), text)
        XCTAssertTrue(text.contains("CPU avg 25%"), text)
        XCTAssertFalse(text.contains("Flow minutes"), "absent rule yields no line")
        XCTAssertTrue(source.queries.contains { $0.contains("[43200s]") }, "window is the elapsed part of the day: \(source.queries.first ?? "")")
    }

    func testPastDayUsesFullWindowAndSkipsTodayGauges() {
        let source = FakeSource()
        source.vectors = [("molly_git_lines_added_today", [source.sample(10)]), ("molly_git_lines_removed_today", [source.sample(1)])]
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let text = DaySummary(source: source).render(day: yesterday)
        XCTAssertTrue(text.contains("(covering 24h 0m)") || text.contains("(covering 23h 0m)") || text.contains("(covering 25h 0m)"), text)
        XCTAssertFalse(text.contains("Lines today"), text)
    }

    func testCurrentContextReadsInstantGauges() {
        let source = FakeSource()
        source.vectors = [
            ("molly_focus_app", [source.sample(1, ["app": "iterm2"])]),
            ("molly_idle_seconds", [source.sample(12)]),
            ("molly_user_active", [source.sample(1)]),
            ("molly_screen_locked", [source.sample(0)]),
            ("molly_project_active", [source.sample(1, ["project": "aschepis/molly"]), source.sample(1, ["project": "a/b"])]),
            ("molly_claude_sessions_active", [source.sample(2)]),
            ("molly:flow_state:5m", [source.sample(2)]),
            ("molly_battery_percent", [source.sample(88)]),
            ("molly_battery_on_ac", [source.sample(1)]),
        ]
        let text = DaySummary(source: source).currentContext()
        XCTAssertTrue(text.contains("Focused app: iterm2"), text)
        XCTAssertTrue(text.contains("Idle for: 12s (user active: yes)"), text)
        XCTAssertTrue(text.contains("Screen locked: no"), text)
        XCTAssertTrue(text.contains("Active projects: a/b, aschepis/molly"), text)
        XCTAssertTrue(text.contains("Claude Code sessions active: 2"), text)
        XCTAssertTrue(text.contains("Flow state (last 5m): flow"), text)
        XCTAssertTrue(text.contains("Battery: 88% (on AC: yes)"), text)
        XCTAssertEqual(DaySummary(source: FakeSource()).currentContext(), "No current data (is Molly running and scraped by Prometheus?)")
    }
}

final class MetricsFormatTests: XCTestCase {
    func testVectorAndMatrixFormatting() {
        let samples = [
            PrometheusClient.Sample(labels: ["__name__": "molly_x", "b": "2", "a": "1", "user": "u", "host": "h", "job": "molly", "instance": "x:1"], timestamp: Date(), value: 3),
            PrometheusClient.Sample(labels: [:], timestamp: Date(), value: 0.123456),
        ]
        XCTAssertEqual(MetricsFormat.vector(samples), "molly_x{a=\"1\",b=\"2\"} 3\n{} 0.1235")
        XCTAssertEqual(MetricsFormat.vector([]), "(empty result)")
        let many = (0..<250).map { PrometheusClient.Sample(labels: ["i": String($0)], timestamp: Date(), value: 1) }
        XCTAssertTrue(MetricsFormat.vector(many).hasSuffix("... 50 more rows omitted (narrow the query)"))

        let t = Calendar.current.date(bySettingHour: 9, minute: 5, second: 0, of: Date())!
        let series = [PrometheusClient.Series(labels: ["__name__": "m"], points: [(t, 1), (t.addingTimeInterval(60), 2)])]
        XCTAssertEqual(MetricsFormat.matrix(series), "m 09:05=1 09:06=2")
        XCTAssertEqual(MetricsFormat.matrix([]), "(empty result)")
    }

    func testFamiliesFromExpositionAndCatalog() {
        let exposition = """
        # HELP molly_a Help A.
        # TYPE molly_a counter
        molly_a 1
        # TYPE molly_b gauge
        # HELP molly_b Help B.
        molly_b 2
        """
        XCTAssertEqual(MetricsFormat.families(fromExposition: exposition), [
            MetricsFormat.Family(name: "molly_a", type: "counter", help: "Help A."),
            MetricsFormat.Family(name: "molly_b", type: "gauge", help: "Help B."),
        ])
        let catalog = """
        | metric | type | labels | unit | meaning |
        |---|---|---|---|---|
        | `molly_up` | gauge | | bool | 1 while running |
        | not a metric row |
        """
        XCTAssertEqual(MetricsFormat.families(fromCatalog: catalog), [MetricsFormat.Family(name: "molly_up", type: "gauge", help: "1 while running")])
        XCTAssertEqual(MetricsFormat.familyTable([]), "(no metrics)")
    }
}
