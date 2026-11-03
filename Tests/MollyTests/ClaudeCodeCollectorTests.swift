import XCTest
@testable import Molly

final class ClaudeLineTests: XCTestCase {
    func testAssistantLineExtractsUsageModelAndTools() throws {
        let json = """
        {"type":"assistant","isSidechain":false,"cwd":"/Users/me/src","timestamp":"2026-11-02T21:44:33.437Z","message":{"id":"msg_1","role":"assistant","model":"claude-fable-5-1","content":[{"type":"text","text":"hello"},{"type":"tool_use","name":"Bash","input":{}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":6444,"cache_read_input_tokens":28356,"output_tokens":364}}}
        """
        let line = try XCTUnwrap(ClaudeLine.parse(json))
        XCTAssertEqual(line.role, .assistant)
        XCTAssertEqual(line.model, "claude-fable-5-1")
        XCTAssertEqual(line.toolNames, ["Bash"])
        XCTAssertEqual(line.usage, TokenUsage(input: 2, output: 364, cacheRead: 28356, cacheCreation: 6444))
        XCTAssertEqual(line.cwd, "/Users/me/src")
        XCTAssertEqual(line.timestamp, Date(timeIntervalSince1970: 1_793_655_873.437))
    }

    func testToolResultsAndMetaAreNotPrompts() throws {
        let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#
        XCTAssertEqual(try XCTUnwrap(ClaudeLine.parse(toolResult)).countsAsMessage, false)
        let meta = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"caveat"}}"#
        XCTAssertEqual(try XCTUnwrap(ClaudeLine.parse(meta)).countsAsMessage, false)
        let typed = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
        XCTAssertEqual(try XCTUnwrap(ClaudeLine.parse(typed)).countsAsMessage, true)
        let blocks = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
        XCTAssertEqual(try XCTUnwrap(ClaudeLine.parse(blocks)).countsAsMessage, true)
    }

    func testOtherLineTypesAndGarbageAreIgnored() {
        for text in [#"{"type":"file-history-snapshot"}"#, #"{"type":"summary","summary":"x"}"#, "not json", "", #"{"a":1}"#] {
            XCTAssertNil(ClaudeLine.parse(text), text)
        }
    }

    func testPricingMatchesBySubstringAndConfigOverrides() {
        let table = ClaudePricing.table(from: CollectorSettings(name: "claude_code", raw: [
            "pricing": .object(["sonnet": .object(["input": .number(1), "output": .number(2)])]),
        ]))
        XCTAssertEqual(ClaudePricing.price(for: "claude-sonnet-4-5", in: table)?.input, 1)
        XCTAssertEqual(ClaudePricing.price(for: "claude-haiku-4-5", in: table)?.input, 1)
        XCTAssertEqual(ClaudePricing.price(for: "claude-opus-4-1", in: table)?.output, 25)
        XCTAssertNotNil(ClaudePricing.price(for: "claude-fable-5-1", in: table))
        XCTAssertNil(ClaudePricing.price(for: "gpt-5", in: table))
        let cost = ClaudePricing.cost(TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheCreation: 0),
                                      at: ModelPrice(input: 3, output: 15, cacheRead: 0, cacheWrite: 0))
        XCTAssertEqual(cost, 18, accuracy: 1e-9)
    }

    func testProjectNameNormalization() {
        XCTAssertEqual(ProjectName.normalize(path: "/Users/me/src/github.com/acme/widgets"), "acme/widgets")
        XCTAssertEqual(ProjectName.normalize(path: "/Users/me/src/github.com/acme/widgets/Sources/x"), "acme/widgets")
        XCTAssertEqual(ProjectName.normalize(path: "/Users/me/notes"), "notes")
        XCTAssertEqual(ProjectName.normalize(path: "/Users/me/src/github.com"), "github.com")
        XCTAssertEqual(ProjectName.decodeClaudeDirectory("-Users-me-notes"), "/Users/me/notes")
    }

    func testRecentIDsDeduplicatesAndEvicts() {
        var ids = RecentIDs(limit: 2)
        XCTAssertTrue(ids.insert("a"))
        XCTAssertFalse(ids.insert("a"))
        XCTAssertTrue(ids.insert("b"))
        XCTAssertTrue(ids.insert("c"))
        XCTAssertTrue(ids.insert("a"), "oldest id was evicted")
    }
}

final class ClaudeCodeCollectorTests: TempFolderTestCase {
    private let cwd = "/Users/me/src/github.com/acme/widgets"

    private func userLine(_ text: String, at stamp: String) -> String {
        #"{"type":"user","isSidechain":false,"cwd":"\#(cwd)","timestamp":"\#(stamp)","message":{"role":"user","content":"\#(text)"}}"# + "\n"
    }

    private func assistantLines(id: String, at stamp: String, blocks: [String], sidechain: Bool = false) -> String {
        blocks.map { block in
            #"{"type":"assistant","isSidechain":\#(sidechain),"cwd":"\#(cwd)","timestamp":"\#(stamp)","message":{"id":"\#(id)","role":"assistant","model":"claude-sonnet-4-5","content":[\#(block)],"usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50}}}"# + "\n"
        }.joined()
    }

    private let textBlock = #"{"type":"text","text":"ok"}"#
    private let toolBlock = #"{"type":"tool_use","name":"Bash","input":{}}"#

    private struct Fixture {
        let projects: URL
        let history: URL
        let session: URL
        let state: URL
    }

    private func makeFixture() throws -> Fixture {
        let base = makeTempFolder()
        let projects = base.appendingPathComponent("projects")
        let dir = projects.appendingPathComponent("-Users-me-src-github-com-acme-widgets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = dir.appendingPathComponent("s1.jsonl")
        try Data().write(to: session)
        let history = base.appendingPathComponent("history.jsonl")
        try Data().write(to: history)
        return Fixture(projects: projects, history: history, session: session, state: base.appendingPathComponent("state"))
    }

    private func makeCollector(_ f: Fixture, extra: [String: JSONValue] = [:], tracker: ProjectTracker = ProjectTracker()) throws -> (ClaudeCodeCollector, MetricsRegistry) {
        var raw: [String: JSONValue] = ["projectsDir": .string(f.projects.path), "historyFile": .string(f.history.path)]
        raw.merge(extra) { $1 }
        let collector = try ClaudeCodeCollector(settings: settings("claude_code", raw), stateFolder: f.state,
                                                tracker: tracker, startedAt: Date().addingTimeInterval(-1))
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        return (collector, registry)
    }

    func testExistingFilesAreNotBackfilledButAppendsAreCounted() throws {
        let f = try makeFixture()
        try append(userLine("old", at: "2026-11-02T10:00:00.000Z"), to: f.session)
        try append(assistantLines(id: "m0", at: "2026-11-02T10:00:05.000Z", blocks: [textBlock]), to: f.session)
        try backdate(f.session)

        let tracker = ProjectTracker()
        let (collector, registry) = try makeCollector(f, tracker: tracker)
        try collector.collect()
        XCTAssertNil(value(registry, "molly_claude_messages_total", ["role": "user"]))
        XCTAssertEqual(value(registry, "molly_claude_sessions_total") ?? 0, 0)

        try append(userLine("hello", at: "2026-11-03T10:00:00.000Z"), to: f.session)
        try append(assistantLines(id: "m1", at: "2026-11-03T10:00:30.000Z", blocks: [textBlock, toolBlock, toolBlock]), to: f.session)
        try collector.collect()

        let labels = ["project": "acme/widgets"]
        XCTAssertEqual(value(registry, "molly_claude_messages_total", labels.merging(["role": "user"]) { $1 }), 1)
        XCTAssertEqual(value(registry, "molly_claude_messages_total", labels.merging(["role": "assistant"]) { $1 }), 1,
                       "three lines with one message id are one message")
        XCTAssertEqual(value(registry, "molly_claude_tool_calls_total", labels.merging(["tool": "Bash"]) { $1 }), 2)
        XCTAssertEqual(value(registry, "molly_claude_tokens_total", ["model": "claude-sonnet-4-5", "kind": "output"]), 50)
        XCTAssertEqual(value(registry, "molly_claude_tokens_total", ["model": "claude-sonnet-4-5", "kind": "cache_read"]), 1000)
        let expectedCost = (10 * 3.0 + 50 * 15.0 + 1000 * 0.3 + 100 * 3.75) / 1_000_000
        XCTAssertEqual(try XCTUnwrap(value(registry, "molly_claude_estimated_cost_usd_total", ["model": "claude-sonnet-4-5"])), expectedCost, accuracy: 1e-9)
        XCTAssertEqual(value(registry, "molly_claude_session_duration_seconds_total", labels), 30)
        XCTAssertNotNil(tracker.snapshot()[.claude]?["acme/widgets"])

        try collector.collect()
        XCTAssertEqual(value(registry, "molly_claude_messages_total", labels.merging(["role": "user"]) { $1 }), 1, "second run adds nothing")
    }

    func testPartialTrailingLineWaitsForItsNewline() throws {
        let f = try makeFixture()
        try backdate(f.session)
        let (collector, registry) = try makeCollector(f)
        try collector.collect()

        let line = userLine("hello", at: "2026-11-03T10:00:00.000Z")
        let cut = line.index(line.startIndex, offsetBy: 40)
        try append(String(line[..<cut]), to: f.session)
        try collector.collect()
        XCTAssertNil(value(registry, "molly_claude_messages_total", ["role": "user"]))

        try append(String(line[cut...]), to: f.session)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_claude_messages_total", ["role": "user"]), 1)
    }

    func testOffsetsPersistAcrossRestart() throws {
        let f = try makeFixture()
        try backdate(f.session)
        var (collector, registry) = try makeCollector(f)
        try collector.collect()
        try append(userLine("one", at: "2026-11-03T10:00:00.000Z"), to: f.session)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_claude_messages_total", ["role": "user"]), 1)

        try append(userLine("two", at: "2026-11-03T10:01:00.000Z"), to: f.session)
        (collector, registry) = try makeCollector(f)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_claude_messages_total", ["role": "user"]), 1,
                       "restarted collector counts only the line appended while it was down")
    }

    func testNewFilesAfterStartAreReadFromTheTop() throws {
        let f = try makeFixture()
        try backdate(f.session)
        let (collector, registry) = try makeCollector(f)
        try collector.collect()
        let fresh = f.projects.appendingPathComponent("-Users-me-notes/s2.jsonl")
        try FileManager.default.createDirectory(at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
        try append(userLine("hi", at: "2026-11-03T10:00:00.000Z").replacingOccurrences(of: cwd, with: "/Users/me/notes"), to: fresh)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_claude_sessions_total"), 1)
        XCTAssertEqual(value(registry, "molly_claude_messages_total", ["role": "user", "project": "notes"]), 1)
        XCTAssertEqual(value(registry, "molly_claude_sessions_active"), 1)
    }

    func testSubagentLinesAndPrompts() throws {
        let f = try makeFixture()
        try backdate(f.session)
        try backdate(f.history)
        let (collector, registry) = try makeCollector(f)
        try collector.collect()
        try append(assistantLines(id: "side", at: "2026-11-03T10:00:00.000Z", blocks: [textBlock], sidechain: true), to: f.session)
        try append(#"{"display":"SECRET PROMPT","timestamp":1793656395200,"project":"/x"}"# + "\n", to: f.history)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_claude_subagent_messages_total"), 1)
        XCTAssertEqual(value(registry, "molly_claude_prompts_total"), 1)
        XCTAssertFalse(registry.render().contains("SECRET"))
    }

    func testProjectPolicyRedactsDeniedProjects() throws {
        let f = try makeFixture()
        try backdate(f.session)
        let (collector, registry) = try makeCollector(f, extra: [
            "projects": .object(["mode": .string("denylist"), "patterns": strings(["acme/*"])]),
        ])
        try collector.collect()
        try append(userLine("hi", at: "2026-11-03T10:00:00.000Z"), to: f.session)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_claude_messages_total", ["role": "user", "project": "redacted"]), 1)
    }

    func testMissingDirectoryIsUnavailable() throws {
        let f = try makeFixture()
        try FileManager.default.removeItem(at: f.projects)
        let (collector, _) = try makeCollector(f)
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }
}
