import XCTest
@testable import Molly

final class HTTPBodyTests: XCTestCase {
    func testParsesBodyWhenComplete() {
        let raw = Data("POST /event HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        guard case .request(let r) = HTTPRequestParser.parse(raw) else { return XCTFail("not parsed") }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello")
    }

    func testWaitsForWholeBody() {
        let raw = Data("POST /event HTTP/1.1\r\nContent-Length: 10\r\n\r\nhello".utf8)
        if case .incomplete = HTTPRequestParser.parse(raw) {} else { XCTFail("should wait for body") }
    }

    func testOversizeBodyIsRefused() {
        let raw = Data("POST /event HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)
        if case .tooLarge = HTTPRequestParser.parse(raw) {} else { XCTFail("should be too large") }
    }

    func testPostRoutesAndMethodMismatch() {
        let router = Router()
        router.get("/x") { _ in .text("get") }
        router.post("/x") { r in .text(String(decoding: r.body, as: UTF8.self)) }
        let post = HTTPRequest(method: "POST", path: "/x", query: [:], headers: [:], body: Data("b".utf8))
        XCTAssertEqual(String(decoding: router.route(post).body, as: UTF8.self), "b")
        XCTAssertEqual(router.route(HTTPRequest(method: "DELETE", path: "/x", query: [:], headers: [:])).status, 405)
        XCTAssertEqual(HTTPResponse.reason(for: 204), "No Content")
        XCTAssertEqual(HTTPResponse.reason(for: 413), "Payload Too Large")
    }
}

final class EventsCollectorTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func make(_ json: String = "{}") throws -> (EventsCollector, MetricsRegistry) {
        let config = try Config.parse(Data(#"{"collectors": {"events": \#(json)}}"#.utf8))
        let collector = try EventsCollector(settings: config.collector("events"), now: { self.clock })
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        return (collector, registry)
    }

    private func hook(_ event: String, tool: String? = nil, session: String = "s1", cwd: String = "/Users/me/src/github.com/aschepis/molly") -> Data {
        var o: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string(session), "cwd": .string(cwd),
                                      "transcript_path": .string("/secret/path.jsonl"), "tool_input": .object(["command": .string("rm -rf /")])]
        if let tool { o["tool_name"] = .string(tool) }
        return try! JSONEncoder().encode(JSONValue.object(o))
    }

    func testHookPayloadCountsEventsToolsAndProjects() throws {
        let (c, r) = try make()
        XCTAssertEqual(c.handle(body: hook("PreToolUse", tool: "Bash"), authorization: nil), .accepted)
        XCTAssertEqual(c.handle(body: hook("PostToolUse", tool: "Bash"), authorization: nil), .accepted)
        XCTAssertEqual(c.handle(body: hook("Stop"), authorization: nil), .accepted)
        let hooks = r.counter("molly_claude_hook_events_total", help: "", labels: ["event", "tool", "project"])
        XCTAssertEqual(hooks.value(labels: ["event": "PreToolUse", "tool": "Bash", "project": "aschepis/molly"]), 1)
        XCTAssertEqual(hooks.value(labels: ["event": "Stop", "tool": "", "project": "aschepis/molly"]), 1)
        let events = r.counter("molly_events_total", help: "", labels: ["source", "event"])
        XCTAssertEqual(events.value(labels: ["source": "claude_code", "event": "PreToolUse"]), 1)
        XCTAssertEqual(r.gauge("molly_claude_hook_sessions_active", help: "").value(), 1)
        XCTAssertEqual(r.gauge("molly_claude_hook_last_event_timestamp_seconds", help: "").value(), clock.timeIntervalSince1970)
        let rendered = r.render()
        XCTAssertFalse(rendered.contains("secret"))
        XCTAssertFalse(rendered.contains("rm -rf"))
        XCTAssertEqual(ProjectTracker.shared.snapshot()[.claude]?["aschepis/molly"], clock)
    }

    func testSessionsExpireAndEndExplicitly() throws {
        let (c, r) = try make(#"{"activeWindowSeconds": 100}"#)
        let active = r.gauge("molly_claude_hook_sessions_active", help: "")
        _ = c.handle(body: hook("SessionStart", session: "a"), authorization: nil)
        _ = c.handle(body: hook("UserPromptSubmit", session: "b"), authorization: nil)
        XCTAssertEqual(active.value(), 2)
        _ = c.handle(body: hook("SessionEnd", session: "a"), authorization: nil)
        XCTAssertEqual(active.value(), 1)
        clock = clock.addingTimeInterval(101)
        try c.collect()
        XCTAssertEqual(active.value(), 0)
    }

    func testGenericEventAndValidation() throws {
        let (c, r) = try make()
        XCTAssertEqual(c.handle(body: Data(#"{"source":"cron","event":"backup","value":3}"#.utf8), authorization: nil), .accepted)
        XCTAssertEqual(r.counter("molly_events_total", help: "", labels: ["source", "event"]).value(labels: ["source": "cron", "event": "backup"]), 3)
        XCTAssertEqual(c.handle(body: Data("nope".utf8), authorization: nil), .badRequest("body must be a JSON object"))
        XCTAssertEqual(c.handle(body: Data(#"{"event":"x"}"#.utf8), authorization: nil), .badRequest("source is required"))
        XCTAssertEqual(c.handle(body: Data(#"{"source":"x"}"#.utf8), authorization: nil), .badRequest("event is required"))
        XCTAssertEqual(c.handle(body: Data(#"{"source":"x","event":"y","value":-1}"#.utf8), authorization: nil), .badRequest("value must be >= 0"))
        _ = c.handle(body: Data(#"{"source":"we ird\"","event":"a\nb"}"#.utf8), authorization: nil)
        XCTAssertNotNil(r.counter("molly_events_total", help: "", labels: ["source", "event"]).value(labels: ["source": "weird", "event": "ab"]))
    }

    func testTokenIsCheckedBeforeBody() throws {
        let (c, _) = try make(#"{"token": "sekret"}"#)
        XCTAssertEqual(c.handle(body: Data("garbage".utf8), authorization: nil), .unauthorized)
        XCTAssertEqual(c.handle(body: Data("garbage".utf8), authorization: "Bearer wrong"), .unauthorized)
        XCTAssertEqual(c.handle(body: Data("garbage".utf8), authorization: "Bearer sekret"), .badRequest("body must be a JSON object"))
        XCTAssertEqual(c.handle(body: hook("Stop"), authorization: "Bearer sekret"), .accepted)
    }

    func testProjectPolicyApplies() throws {
        let (c, r) = try make(#"{"projects": {"enabled": true, "mode": "denylist", "patterns": ["aschepis/*"]}}"#)
        _ = c.handle(body: hook("Stop"), authorization: nil)
        _ = c.handle(body: hook("Stop", cwd: ""), authorization: nil)
        let hooks = r.counter("molly_claude_hook_events_total", help: "", labels: ["event", "tool", "project"])
        XCTAssertEqual(hooks.value(labels: ["event": "Stop", "tool": "", "project": "redacted"]), 1)
        XCTAssertEqual(hooks.value(labels: ["event": "Stop", "tool": "", "project": "other"]), 1)
    }

    func testRouteReturns204And401And400() throws {
        let config = try Config.parse(Data(#"{"collectors": {"events": {"token": "t"}}}"#.utf8))
        let registry = MetricsRegistry()
        let manager = CollectorManager(registry: registry, collectors: [try EventsCollector(settings: config.collector("events"))])
        manager.startAll()
        defer { manager.stopAll() }
        let router = Router()
        Routes.register(on: router, manager: manager, config: config)
        func post(_ body: String, auth: String? = nil) -> Int {
            var headers: [String: String] = [:]
            if let auth { headers["authorization"] = auth }
            return router.route(HTTPRequest(method: "POST", path: "/event", query: [:], headers: headers, body: Data(body.utf8))).status
        }
        XCTAssertEqual(post(#"{"source":"a","event":"b"}"#), 401)
        XCTAssertEqual(post("x", auth: "Bearer t"), 400)
        XCTAssertEqual(post(#"{"source":"a","event":"b"}"#, auth: "Bearer t"), 204)
    }

    func testRouteWithoutCollectorIs503() {
        let manager = CollectorManager(registry: MetricsRegistry(), collectors: [])
        let router = Router()
        Routes.register(on: router, manager: manager, config: Config())
        XCTAssertEqual(router.route(HTTPRequest(method: "POST", path: "/event", query: [:], headers: [:], body: Data("{}".utf8))).status, 503)
    }
}

final class HookCommandTests: XCTestCase {
    private func parse(_ s: String) -> JSONValue { try! JSONValue.parse(Data(s.utf8)) }

    func testSnippetCoversEveryEventWithTheExecutable() {
        let snippet = HookCommand.snippetJSON(executable: "/opt/molly")
        let json = parse(snippet)
        let hooks = json["hooks"]!.objectValue!
        XCTAssertEqual(Set(hooks.keys), Set(HookCommand.hookEvents))
        for (_, groups) in hooks {
            let command = groups.arrayValue![0]["hooks"]!.arrayValue![0]["command"]!.stringValue
            XCTAssertEqual(command, "/opt/molly hook")
        }
    }

    func testMergeKeepsExistingHooksAndIsIdempotent() throws {
        let existing = parse(#"""
        {"model": "opus", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/bin/say hi"}]}]}}
        """#)
        let once = try HookCommand.merge(settings: existing, executable: "/opt/molly")
        let twice = try HookCommand.merge(settings: once, executable: "/opt/molly")
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once["model"]?.stringValue, "opus")
        let pre = once["hooks"]!["PreToolUse"]!.arrayValue!
        XCTAssertEqual(pre.count, 2)
        XCTAssertEqual(pre[0]["matcher"]?.stringValue, "Bash")
        XCTAssertTrue(HookCommand.isMollyGroup(pre[1]))
        XCTAssertEqual(once["hooks"]!.objectValue!.count, HookCommand.hookEvents.count)
    }

    func testMergeReplacesStaleExecutablePath() throws {
        let old = try HookCommand.merge(settings: parse("{}"), executable: "/old/molly")
        let new = try HookCommand.merge(settings: old, executable: "/new/molly")
        let commands = new["hooks"]!["Stop"]!.arrayValue!.flatMap { $0["hooks"]!.arrayValue! }.compactMap { $0["command"]?.stringValue }
        XCTAssertEqual(commands, ["/new/molly hook"])
        XCTAssertThrowsError(try HookCommand.merge(settings: parse("{}"), executable: "/renamed/binary"))
    }

    func testUnmergeRemovesOnlyMollyGroups() throws {
        let existing = parse(#"""
        {"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "/usr/bin/say hi"}]}]}}
        """#)
        let merged = try HookCommand.merge(settings: existing, executable: "/opt/molly")
        let restored = try HookCommand.unmerge(settings: merged)
        XCTAssertEqual(restored, existing)
        XCTAssertEqual(try HookCommand.unmerge(settings: try HookCommand.merge(settings: parse("{}"), executable: "/x/molly")), parse("{}"))
    }

    func testMergeRejectsNonObject() {
        XCTAssertThrowsError(try HookCommand.merge(settings: parse("[]"), executable: "/x"))
    }

    func testWithSourceAddsClaudeSourceOnce() {
        let out = HookCommand.withSource(Data(#"{"hook_event_name":"Stop"}"#.utf8))!
        XCTAssertEqual(parse(String(decoding: out, as: UTF8.self))["source"]?.stringValue, "claude_code")
        let kept = HookCommand.withSource(Data(#"{"source":"mine"}"#.utf8))!
        XCTAssertEqual(parse(String(decoding: kept, as: UTF8.self))["source"]?.stringValue, "mine")
        XCTAssertNil(HookCommand.withSource(Data("[]".utf8)))
    }
}
