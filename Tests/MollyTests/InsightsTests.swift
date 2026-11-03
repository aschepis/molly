import XCTest
@testable import Molly

private struct FakeCompleter: NarrativeCompleter {
    let name: String
    var reply = "## Narrative\nA fine day.\n\n## Recommendations\n- a\n- b\n- c\n\n## Pattern to watch\nNone."
    var error: Error?
    var calls: UnsafeMutablePointer<Int>

    func complete(system: String, prompt: String) throws -> String {
        calls.pointee += 1
        if let error { throw error }
        return reply
    }
}

private struct Boom: Error {}

final class InsightsTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func date(_ text: String, _ time: String = "12:00") -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(text) \(time)")!
    }

    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("molly-insights-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixtureDigest() -> InsightsDigest {
        var d = InsightsDigest(kind: .day, date: "2026-11-03", user: "adam", host: "mbp",
                               from: date("2026-11-03", "00:00"), to: date("2026-11-03", "18:30"),
                               generatedAt: date("2026-11-03", "18:30"))
        d.scalars = ["active_hours": 5.25, "focus_switches": 142, "claude_cost_usd": 3.5, "cpu_avg": 0.21]
        d.breakdowns = ["focus_top_apps": ["google chrome": 120, "iterm2": 95.5, "": 3],
                        "commits_by_repo": ["aschepis/molly": 11]]
        d.missing = ["mail_received", "input_keys_per_minute_avg"]
        return d
    }

    // MARK: queries

    func testQueryTableIsWellFormed() {
        var keys = Set<String>()
        for q in DigestQueries.all {
            XCTAssertTrue(keys.insert(q.key).inserted, "duplicate key \(q.key)")
            XCTAssertTrue(q.promql.contains("{s}") || q.promql.contains("{s,"), "\(q.key) lacks selector placeholder")
            XCTAssertTrue(q.promql.contains("[{r}"), "\(q.key) lacks range placeholder")
            if case .breakdown(let label) = q.shape {
                XCTAssertTrue(q.promql.contains("by (\(label))"), "\(q.key) must group by \(label)")
            }
        }
        XCTAssertGreaterThan(DigestQueries.all.count, 40)
    }

    func testQueryRendering() {
        let q = DigestQueries.all[0]
        let rendered = q.rendered(selector: DigestQueries.selector(user: "u", host: "h"), range: "3600s")
        XCTAssertEqual(rendered, "sum(increase(molly_active_seconds_total{user=\"u\",host=\"h\"}[3600s])) / 3600")
        let sent = DigestQueries.all.first { $0.key == "messages_sent" }!
        XCTAssertEqual(sent.rendered(selector: "user=\"u\",host=\"h\"", range: "1d"),
                       "sum(increase(molly_messages_total{user=\"u\",host=\"h\",direction=\"sent\"}[1d]))")
        XCTAssertEqual(DigestQueries.range(from: date("2026-11-03", "00:00"), to: date("2026-11-03", "01:00")), "3600s")
        XCTAssertEqual(DigestQueries.range(from: Date(), to: Date()), "60s")
    }

    // MARK: windows

    func testDayWindowEndsAtMidnightOrNow() {
        let now = date("2026-11-03", "15:00")
        let today = DigestBuilder.window(kind: .day, containing: now, now: now, calendar: calendar)
        XCTAssertEqual(today.from, date("2026-11-03", "00:00"))
        XCTAssertEqual(today.to, now)
        XCTAssertEqual(today.label, "2026-11-03")
        let yesterday = DigestBuilder.window(kind: .day, containing: date("2026-11-02"), now: now, calendar: calendar)
        XCTAssertEqual(yesterday.to, date("2026-11-03", "00:00"))
    }

    func testWeekWindowStartsOnMonday() {
        let now = date("2026-11-10", "09:00")
        // 2026-11-05 is a Thursday; its week starts Monday 2026-11-02.
        let w = DigestBuilder.window(kind: .week, containing: date("2026-11-05"), now: now, calendar: calendar)
        XCTAssertEqual(w.label, "2026-11-02")
        XCTAssertEqual(w.from, date("2026-11-02", "00:00"))
        XCTAssertEqual(w.to, date("2026-11-09", "00:00"))
        let sunday = DigestBuilder.window(kind: .week, containing: date("2026-11-08"), now: now, calendar: calendar)
        XCTAssertEqual(sunday.label, "2026-11-02")
    }

    // MARK: rendering

    func testMarkdownRendersScalarsBreakdownsAndMissing() {
        let md = fixtureDigest().markdown()
        XCTAssertTrue(md.hasPrefix("## Digest: day 2026-11-03 (adam@mbp)\n"))
        XCTAssertTrue(md.contains("- Active hours: 5.25 h\n"))
        XCTAssertTrue(md.contains("- Focus switches: 142\n"))
        XCTAssertTrue(md.contains("- Claude estimated cost: 3.50 USD\n"))
        XCTAssertTrue(md.contains("- CPU utilization (avg): 0.21 (0-1)\n"))
        XCTAssertTrue(md.contains("- Top apps by focus: google chrome 120 min, iterm2 95.50 min, (none) 3 min\n"))
        XCTAssertTrue(md.contains("- Commits by repo (mine): aschepis/molly 11\n"))
        XCTAssertTrue(md.contains("No data for: input_keys_per_minute_avg, mail_received\n"))
        XCTAssertFalse(md.contains("Idle hours"))
    }

    func testJSONRoundTrip() throws {
        let digest = fixtureDigest()
        let data = try digest.json()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(InsightsDigest.self, from: data)
        XCTAssertEqual(back.scalars, digest.scalars)
        XCTAssertEqual(back.breakdowns, digest.breakdowns)
    }

    func testPromptAsksForThreeSectionsAndEmbedsDigest() {
        let prompt = InsightsPrompt.user(digest: fixtureDigest())
        XCTAssertTrue(prompt.contains("## Narrative"))
        XCTAssertTrue(prompt.contains("## Recommendations"))
        XCTAssertTrue(prompt.contains("## Pattern to watch"))
        XCTAssertTrue(prompt.contains("- Active hours: 5.25 h"))
        XCTAssertTrue(prompt.contains("this day"))
        XCTAssertFalse(InsightsPrompt.system.isEmpty)
    }

    func testReportRenderWrapsDigestInDetails() {
        let text = InsightsGenerator.render(narrative: "  Hello.\n", digest: fixtureDigest(), backend: "cli")
        XCTAssertTrue(text.hasPrefix("# Molly insights for 2026-11-03\n\nHello.\n\n<details>"))
        XCTAssertTrue(text.contains("via cli"))
        XCTAssertTrue(text.contains("- Active hours: 5.25 h"))
        XCTAssertTrue(text.hasSuffix("</details>\n"))
    }

    // MARK: store

    func testStoreNamesFilesAndFindsLatest() throws {
        let store = InsightsStore(folder: tempFolder())
        XCTAssertNil(store.latest())
        try store.write("a", kind: .day, date: "2026-11-01")
        try store.write("b", kind: .day, date: "2026-11-03")
        try store.write("w", kind: .week, date: "2026-11-09")
        try store.write("junk", kind: .day, date: "notes")
        XCTAssertEqual(store.url(kind: .week, date: "2026-11-09").lastPathComponent, "2026-11-09-week.md")
        XCTAssertEqual(store.latest()?.date, "2026-11-03")
        XCTAssertEqual(store.latest()?.text, "b")
        XCTAssertEqual(store.latest(kind: .week)?.date, "2026-11-09")
        XCTAssertTrue(store.exists(kind: .day, date: "2026-11-01"))
        XCTAssertFalse(store.exists(kind: .week, date: "2026-11-01"))
    }

    // MARK: generator caching

    func testGeneratorUsesCacheUnlessForced() throws {
        let store = InsightsStore(folder: tempFolder())
        let now = date("2026-11-03", "21:30")
        try store.write("# cached report\n", kind: .day, date: "2026-11-03")
        let calls = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        calls.pointee = 0
        defer { calls.deallocate() }
        let client = try PrometheusClient(baseURL: "http://127.0.0.1:1")
        let generator = InsightsGenerator(client: client, store: store, user: "u", host: "h",
                                          makeCompleter: { FakeCompleter(name: "fake", calls: calls) })
        let registry = MetricsRegistry()
        generator.register(on: registry)
        let result = try generator.generate(kind: .day, date: now, now: now)
        XCTAssertTrue(result.cached)
        XCTAssertEqual(result.markdown, "# cached report\n")
        XCTAssertEqual(calls.pointee, 0)
        XCTAssertEqual(registry.counter("molly_insights_generations_total", help: "", labels: ["kind", "status"])
            .value(labels: ["kind": "day", "status": "cached"]), 1)

        // Forcing with an unreachable Prometheus yields an empty digest, which is an error, never a call.
        XCTAssertThrowsError(try generator.generate(kind: .day, date: now, force: true, now: now))
        XCTAssertEqual(calls.pointee, 0)
        XCTAssertEqual(registry.counter("molly_insights_generations_total", help: "", labels: ["kind", "status"])
            .value(labels: ["kind": "day", "status": "error"]), 1)
    }

    func testGeneratorWritesReportFromCompleter() throws {
        let client = try PrometheusClient(baseURL: "http://localhost:9090")
        try XCTSkipUnless(client.isReady(), "local Prometheus not running")
        let store = InsightsStore(folder: tempFolder())
        let now = Date()
        let calls = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        calls.pointee = 0
        defer { calls.deallocate() }
        let generator = InsightsGenerator(client: client, store: store, user: Config.defaultUser, host: Config.defaultHost,
                                          makeCompleter: { FakeCompleter(name: "fake", calls: calls) })
        let registry = MetricsRegistry()
        generator.register(on: registry)
        let result = try generator.generate(kind: .day, date: now, now: now)
        XCTAssertFalse(result.cached)
        XCTAssertEqual(calls.pointee, 1)
        XCTAssertTrue(result.markdown.contains("A fine day."))
        XCTAssertTrue(store.exists(kind: .day, date: result.date))
        XCTAssertNotNil(registry.gauge("molly_insights_last_generated_timestamp_seconds", help: "").value())
    }

    func testCompleterFailureIsCountedAndRethrown() throws {
        let client = try PrometheusClient(baseURL: "http://localhost:9090")
        try XCTSkipUnless(client.isReady(), "local Prometheus not running")
        let store = InsightsStore(folder: tempFolder())
        let calls = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        calls.pointee = 0
        defer { calls.deallocate() }
        let generator = InsightsGenerator(client: client, store: store, user: Config.defaultUser, host: Config.defaultHost,
                                          makeCompleter: { FakeCompleter(name: "fake", error: Boom(), calls: calls) })
        let registry = MetricsRegistry()
        generator.register(on: registry)
        XCTAssertThrowsError(try generator.generate(kind: .day, date: Date()))
        XCTAssertFalse(store.exists(kind: .day, date: DigestBuilder.dateLabel(Date())))
        XCTAssertEqual(registry.counter("molly_insights_generations_total", help: "", labels: ["kind", "status"])
            .value(labels: ["kind": "day", "status": "error"]), 1)
    }

    // MARK: backends

    func testBackendSelection() throws {
        let noEnv: [String: String] = [:]
        let withKey = ["ANTHROPIC_API_KEY": "sk-test"]
        XCTAssertEqual(try NarrativeBackend.make(choice: .auto, apiKey: nil, model: "m", environment: withKey, cliLocator: { nil }).name, "api:m")
        XCTAssertEqual(try NarrativeBackend.make(choice: .auto, apiKey: "cfg", model: "m", environment: noEnv, cliLocator: { "/x/claude" }).name, "api:m")
        XCTAssertEqual(try NarrativeBackend.make(choice: .auto, apiKey: "", model: "m", environment: noEnv, cliLocator: { "/x/claude" }).name, "cli")
        XCTAssertEqual(try NarrativeBackend.make(choice: .cli, apiKey: "cfg", model: "m", environment: withKey, cliLocator: { "/x/claude" }).name, "cli")
        XCTAssertThrowsError(try NarrativeBackend.make(choice: .auto, apiKey: nil, model: "m", environment: noEnv, cliLocator: { nil }))
        XCTAssertThrowsError(try NarrativeBackend.make(choice: .api, apiKey: nil, model: "m", environment: noEnv, cliLocator: { "/x/claude" }))
        XCTAssertThrowsError(try NarrativeBackend.make(choice: .cli, apiKey: "k", model: "m", environment: withKey, cliLocator: { nil }))
    }

    func testAPICompleterBuildsRequestAndParsesResponse() throws {
        var completer = ClaudeAPICompleter(apiKey: "sk-test", model: "claude-sonnet-5-5")
        var captured: URLRequest?
        completer.transport = { request in
            captured = request
            let body = #"{"content":[{"type":"text","text":"Hello "},{"type":"text","text":"world"}],"stop_reason":"end_turn"}"#
            return (200, Data(body.utf8))
        }
        let text = try completer.complete(system: "sys", prompt: "ask")
        XCTAssertEqual(text, "Hello \nworld")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        let body = try JSONSerialization.jsonObject(with: captured!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertEqual(body["max_tokens"] as? Int, 1500)

        completer.transport = { _ in (400, Data(#"{"error":{"message":"bad model"}}"#.utf8)) }
        XCTAssertThrowsError(try completer.complete(system: "s", prompt: "p")) { error in
            XCTAssertTrue("\(error)".contains("bad model"))
        }
        completer.transport = { _ in (200, Data(#"{"content":[],"stop_reason":"refusal","stop_details":{"explanation":"nope"}}"#.utf8)) }
        XCTAssertThrowsError(try completer.complete(system: "s", prompt: "p")) { error in
            XCTAssertTrue("\(error)".contains("nope"))
        }
    }

    func testCLICompleterRunsScriptWithPromptOnStdin() throws {
        let folder = tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("claude")
        try "#!/bin/sh\ncat | tr a-z A-Z\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let completer = ClaudeCLICompleter(executable: script.path)
        XCTAssertEqual(try completer.complete(system: "sys", prompt: "hello"), "SYS\n\nHELLO")
        let failing = folder.appendingPathComponent("broken")
        try "#!/bin/sh\necho bad >&2\nexit 3\n".write(to: failing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing.path)
        XCTAssertThrowsError(try ClaudeCLICompleter(executable: failing.path).complete(system: "s", prompt: "p"))
        XCTAssertNil(ClaudeCLICompleter.findExecutable(home: folder).flatMap { Shell.which("claude") == nil ? $0 : nil })
    }

    // MARK: CLI options

    func testOptionParsing() throws {
        XCTAssertEqual(try InsightsOptions.parse([]), InsightsOptions())
        let o = try InsightsOptions.parse(["--day", "2026-11-02", "--week", "--force", "--digest-only", "--backend", "cli"])
        XCTAssertEqual(o, InsightsOptions(day: "2026-11-02", week: true, force: true, digestOnly: true, backend: .cli))
        XCTAssertThrowsError(try InsightsOptions.parse(["--day", "yesterday"]))
        XCTAssertThrowsError(try InsightsOptions.parse(["--backend", "auto"]))
        XCTAssertThrowsError(try InsightsOptions.parse(["--nope"]))
    }

    // MARK: schedule

    func testScheduleDecision() {
        var files = Set<String>()
        let exists: (InsightsDigest.Kind, String) -> Bool = { kind, date in files.contains("\(kind.rawValue):\(date)") }
        // Tuesday 2026-11-03, before the hour.
        XCTAssertEqual(InsightsSchedule.due(now: date("2026-11-03", "20:59"), dailyAtHour: 21, weekly: true, exists: exists, calendar: calendar),
                       .init(day: false, week: false))
        // After the hour.
        XCTAssertEqual(InsightsSchedule.due(now: date("2026-11-03", "21:00"), dailyAtHour: 21, weekly: true, exists: exists, calendar: calendar),
                       .init(day: true, week: false))
        files.insert("day:2026-11-03")
        XCTAssertEqual(InsightsSchedule.due(now: date("2026-11-03", "23:00"), dailyAtHour: 21, weekly: true, exists: exists, calendar: calendar),
                       .init(day: false, week: false))
        // Monday 2026-11-09 morning: last week's report (week of 11-02) is due, the day is not.
        XCTAssertEqual(InsightsSchedule.due(now: date("2026-11-09", "08:00"), dailyAtHour: 21, weekly: true, exists: exists, calendar: calendar),
                       .init(day: false, week: true))
        files.insert("week:2026-11-02")
        XCTAssertEqual(InsightsSchedule.due(now: date("2026-11-09", "08:00"), dailyAtHour: 21, weekly: true, exists: exists, calendar: calendar),
                       .init(day: false, week: false))
        XCTAssertEqual(InsightsSchedule.due(now: date("2026-11-16", "08:00"), dailyAtHour: 21, weekly: false, exists: exists, calendar: calendar),
                       .init(day: false, week: false))
    }

    // MARK: settings and routes

    func testSettingsDefaultsAndOverrides() throws {
        let config = try Config.parse(Data(#"{"collectors":{"insights":{"enabled":true,"dailyAtHour":30,"backend":"cli","apiKey":"k","model":"m","prometheusURL":"http://p:1"}}}"#.utf8))
        let s = InsightsSettings(settings: config.collector("insights"), links: config.links)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.dailyAtHour, 23)
        XCTAssertEqual(s.backend, .cli)
        XCTAssertEqual(s.apiKey, "k")
        XCTAssertEqual(s.model, "m")
        XCTAssertEqual(s.prometheusURL, "http://p:1")
        let d = InsightsSettings(settings: Config().collector("insights"), links: Config().links)
        XCTAssertFalse(d.enabled)
        XCTAssertEqual(d.dailyAtHour, 21)
        XCTAssertEqual(d.interval, 300)
        XCTAssertNil(d.apiKey)
        XCTAssertEqual(d.backend, .auto)
        XCTAssertEqual(d.prometheusURL, "http://localhost:9090")
        XCTAssertTrue(d.weekly)
    }

    func testConfigRouteRedactsAPIKey() throws {
        let json = try JSONValue.parse(Data(#"{"insights":{"apiKey":"secret","salt":"s","model":"m","token":""}}"#.utf8))
        let redacted = Routes.redactSalts(json)
        XCTAssertEqual(redacted["insights"]?["apiKey"], .string("***"))
        XCTAssertEqual(redacted["insights"]?["salt"], .string("***"))
        XCTAssertEqual(redacted["insights"]?["model"], .string("m"))
    }

    func testPrefixRouteServesReports() {
        let router = Router()
        router.get("/insights/latest") { _ in .text("latest") }
        router.get(prefix: "/insights/") { request in .text("file:" + request.path) }
        func get(_ path: String) -> HTTPResponse {
            router.route(HTTPRequest(method: "GET", path: path, query: [:], headers: [:], body: Data()))
        }
        XCTAssertEqual(String(decoding: get("/insights/latest").body, as: UTF8.self), "latest")
        XCTAssertEqual(String(decoding: get("/insights/2026-11-03").body, as: UTF8.self), "file:/insights/2026-11-03")
        XCTAssertEqual(get("/insights/").status, 404)
        XCTAssertEqual(get("/other").status, 404)
    }
}
