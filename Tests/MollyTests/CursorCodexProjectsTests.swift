import XCTest
import SQLite3
@testable import Molly

final class CursorCollectorTests: TempFolderTestCase {
    private func execute(_ sql: String, at path: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        sqlite3_close(db)
    }

    private func millis(_ secondsFromNow: Double) -> Int64 {
        Int64((Date().timeIntervalSince1970 + secondsFromNow) * 1000)
    }

    private func makeDatabase(at path: String) {
        execute("""
        CREATE TABLE ai_code_hashes (hash TEXT PRIMARY KEY, source TEXT NOT NULL, createdAt INTEGER NOT NULL);
        CREATE TABLE scored_commits (commitHash TEXT NOT NULL, branchName TEXT NOT NULL, scoredAt INTEGER NOT NULL, PRIMARY KEY (commitHash, branchName));
        CREATE TABLE conversation_summaries (conversationId TEXT PRIMARY KEY, updatedAt INTEGER NOT NULL);
        """, at: path)
    }

    func testCountsOnlyRowsNewerThanTheCursor() throws {
        let dir = makeTempFolder()
        let path = dir.appendingPathComponent("ai-code-tracking.db").path
        makeDatabase(at: path)
        execute("""
        INSERT INTO ai_code_hashes VALUES ('old', 'tab', \(millis(-3600)));
        INSERT INTO scored_commits VALUES ('c0', 'main', \(millis(-3600)));
        """, at: path)

        let state = dir.appendingPathComponent("state")
        func collector() -> (CursorCollector, MetricsRegistry) {
            let c = CursorCollector(settings: settings("cursor", ["databasePath": .string(path)]),
                                    stateFolder: state, startedAt: Date().addingTimeInterval(-60))
            let r = MetricsRegistry()
            try! c.start(registry: r)
            return (c, r)
        }

        var (c, registry) = collector()
        try c.collect()
        XCTAssertEqual(value(registry, "molly_cursor_available"), 1)
        XCTAssertEqual(value(registry, "molly_cursor_ai_code_events_total"), 0)

        execute("""
        INSERT INTO ai_code_hashes VALUES ('n1', 'tab', \(millis(-10))), ('n2', 'composer', \(millis(-5)));
        INSERT INTO scored_commits VALUES ('c1', 'main', \(millis(-4)));
        INSERT INTO conversation_summaries VALUES ('conv', \(millis(-3)));
        """, at: path)
        try c.collect()
        XCTAssertEqual(value(registry, "molly_cursor_ai_code_events_total"), 2)
        XCTAssertEqual(value(registry, "molly_cursor_scored_commits_total"), 1)
        XCTAssertEqual(value(registry, "molly_cursor_conversations_total"), 1)
        try c.collect()
        XCTAssertEqual(value(registry, "molly_cursor_ai_code_events_total"), 2)

        execute("INSERT INTO ai_code_hashes VALUES ('n3', 'tab', \(millis(-1)));", at: path)
        (c, registry) = collector()
        try c.collect()
        XCTAssertEqual(value(registry, "molly_cursor_ai_code_events_total"), 1, "cursor persisted across restart")
    }

    func testMissingDatabaseDegrades() throws {
        let dir = makeTempFolder()
        let c = CursorCollector(settings: settings("cursor", ["databasePath": .string(dir.appendingPathComponent("none.db").path)]),
                                stateFolder: dir)
        let registry = MetricsRegistry()
        try c.start(registry: registry)
        XCTAssertThrowsError(try c.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
        XCTAssertEqual(value(registry, "molly_cursor_available"), 0)
    }

    func testMissingTableDoesNotFailOtherCounters() throws {
        let dir = makeTempFolder()
        let path = dir.appendingPathComponent("partial.db").path
        execute("CREATE TABLE ai_code_hashes (hash TEXT, createdAt INTEGER);", at: path)
        let c = CursorCollector(settings: settings("cursor", ["databasePath": .string(path)]), stateFolder: dir.appendingPathComponent("s"))
        try c.start(registry: MetricsRegistry())
        XCTAssertNoThrow(try c.collect())
    }
}

final class CodexCollectorTests: TempFolderTestCase {
    private let rollout = [
        #"{"timestamp":"2026-11-03T10:00:00Z","type":"session_meta","payload":{"id":"abc","cwd":"/secret/place"}}"#,
        #"{"timestamp":"2026-11-03T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#,
        #"{"timestamp":"2026-11-03T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"private prompt"}]}}"#,
        #"{"timestamp":"2026-11-03T10:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}"#,
        #"{"timestamp":"2026-11-03T10:00:04Z","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#,
        #"{"timestamp":"2026-11-03T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":150},"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":50,"total_tokens":150}}}}"#,
        #"{"timestamp":"2026-11-03T10:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":150},"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":50,"total_tokens":150}}}}"#,
        #"{"timestamp":"2026-11-03T10:00:07Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
    ]

    func testParseSkipsUnknownAndNullInfoLines() {
        XCTAssertEqual(CodexLine.parse(rollout[0]), nil)
        XCTAssertEqual(CodexLine.parse(rollout[1])?.model, "gpt-5-codex")
        XCTAssertEqual(CodexLine.parse(rollout[2])?.role, "user")
        XCTAssertNil(CodexLine.parse(rollout[4]))
        XCTAssertEqual(CodexLine.parse(rollout[5])?.usage, TokenUsage(input: 40, output: 50, cacheRead: 60, cacheCreation: 0))
        XCTAssertNil(CodexLine.parse(rollout[7]))
        XCTAssertEqual(CodexLine.parse(#"{"type":"message","role":"assistant","content":[]}"#)?.role, "assistant")
    }

    func testNewSessionIsCountedWithDuplicateTokenEventsSkipped() throws {
        let dir = makeTempFolder()
        let sessions = dir.appendingPathComponent("sessions")
        let day = sessions.appendingPathComponent("2026/11/03")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let collector = CodexCollector(settings: settings("codex", ["sessionsDir": .string(sessions.path)]),
                                       stateFolder: dir.appendingPathComponent("state"),
                                       startedAt: Date().addingTimeInterval(-1))
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try append(rollout.joined(separator: "\n") + "\n", to: day.appendingPathComponent("rollout-1.jsonl"))
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_codex_sessions_total"), 1)
        XCTAssertEqual(value(registry, "molly_codex_sessions_active"), 1)
        XCTAssertEqual(value(registry, "molly_codex_messages_total", ["role": "user"]), 1)
        XCTAssertEqual(value(registry, "molly_codex_messages_total", ["role": "assistant"]), 1)
        XCTAssertEqual(value(registry, "molly_codex_tokens_total", ["model": "gpt-5-codex", "kind": "input"]), 40)
        XCTAssertEqual(value(registry, "molly_codex_tokens_total", ["model": "gpt-5-codex", "kind": "cache_read"]), 60)
        XCTAssertEqual(value(registry, "molly_codex_tokens_total", ["model": "gpt-5-codex", "kind": "output"]), 50)
        XCTAssertFalse(registry.render().contains("private"))
    }

    func testMissingDirectoryIsUnavailable() {
        let collector = CodexCollector(settings: settings("codex", ["sessionsDir": .string("/nonexistent/codex")]),
                                       stateFolder: makeTempFolder())
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }
}

final class ProjectsCollectorTests: TempFolderTestCase {
    func testPublishesActiveProjectsWithinWindow() throws {
        let tracker = ProjectTracker()
        let now = Date()
        tracker.report(project: "acme/widgets", source: .git, at: now.addingTimeInterval(-60))
        tracker.report(project: "acme/widgets", source: .claude, at: now.addingTimeInterval(-10))
        tracker.report(project: "notes", source: .claude, at: now.addingTimeInterval(-7200))
        tracker.report(project: "ancient", source: .git, at: now.addingTimeInterval(-10 * 86400))

        let collector = try ProjectsCollector(settings: settings("projects"), tracker: tracker)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()

        XCTAssertEqual(value(registry, "molly_projects_active"), 1)
        XCTAssertEqual(value(registry, "molly_project_active", ["project": "acme/widgets"]), 1)
        XCTAssertNil(value(registry, "molly_project_active", ["project": "notes"]))
        XCTAssertEqual(try XCTUnwrap(value(registry, "molly_project_last_activity_timestamp_seconds", ["project": "acme/widgets", "source": "claude"])),
                       now.timeIntervalSince1970 - 10, accuracy: 1)
        XCTAssertNotNil(value(registry, "molly_project_last_activity_timestamp_seconds", ["project": "notes", "source": "claude"]))
        XCTAssertFalse(registry.render().contains("ancient"), "older than retentionSeconds")
    }

    func testPolicyRedactsAndCapsCardinality() throws {
        let tracker = ProjectTracker()
        for i in 0..<5 { tracker.report(project: "p\(i)", source: .git, at: Date().addingTimeInterval(Double(-i))) }
        let collector = try ProjectsCollector(settings: settings("projects", [
            "projects": .object(["patterns": strings(["p0"]), "maxCardinality": .number(3)]),
        ]), tracker: tracker)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_projects_active"), 5, "aggregate ignores the label cap")
        XCTAssertNotNil(value(registry, "molly_project_active", ["project": "redacted"]))
        XCTAssertNotNil(value(registry, "molly_project_active", ["project": "p1"]))
        XCTAssertNil(value(registry, "molly_project_active", ["project": "p4"]))
    }

    func testTrackerKeepsNewestTimestampPerSource() {
        let tracker = ProjectTracker()
        let t = Date()
        tracker.report(project: "x", source: .git, at: t)
        tracker.report(project: "x", source: .git, at: t.addingTimeInterval(-100))
        tracker.report(project: "", source: .git, at: t)
        XCTAssertEqual(tracker.snapshot()[.git]?["x"], t)
        XCTAssertEqual(tracker.snapshot()[.git]?.count, 1)
    }

    func testRegistryWiresGroupCCollectorsInOrder() throws {
        let names = try CollectorRegistry.makeCollectors(config: Config()).map(\.name)
        let groupC = names.filter { ["git", "claude_code", "cursor", "codex", "shell", "projects"].contains($0) }
        XCTAssertEqual(groupC, ["git", "claude_code", "cursor", "codex", "shell", "projects"])
        XCTAssertTrue(names.allSatisfy { CollectorRegistry.knownNames.contains($0) })
    }
}

final class LabelLimiterTests: XCTestCase {
    func testFoldsNewValuesIntoOtherAfterCap() throws {
        let filter = try LabelPolicy(enabled: true, maxCardinality: 2).compile()
        let limiter = LabelLimiter(filter: filter)
        XCTAssertEqual(limiter.label("a"), "a")
        XCTAssertEqual(limiter.label("b"), "b")
        XCTAssertEqual(limiter.label("c"), "other")
        XCTAssertEqual(limiter.label("a"), "a")
    }
}
