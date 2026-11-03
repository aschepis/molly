import XCTest
@testable import Molly

final class ShellEventTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func make() throws -> (EventsCollector, MetricsRegistry) {
        let config = try Config.parse(Data(#"{"collectors": {"events": {}}}"#.utf8))
        let collector = try EventsCollector(settings: config.collector("events"), now: { self.clock })
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        return (collector, registry)
    }

    private func prompt(shell: String = "zsh", exit: Int = 0, cwd: String? = "/Users/me/src/github.com/aschepis/molly") -> Data {
        var o: [String: JSONValue] = ["source": .string("shell"), "event": .string("prompt"),
                                      "shell": .string(shell), "exit": .number(Double(exit))]
        if let cwd { o["cwd"] = .string(cwd) }
        return try! JSONEncoder().encode(JSONValue.object(o))
    }

    func testShellPromptCountsAndReportsProject() throws {
        let (c, r) = try make()
        XCTAssertEqual(c.handle(body: prompt(), authorization: nil), .accepted)
        XCTAssertEqual(c.handle(body: prompt(exit: 1), authorization: nil), .accepted)
        XCTAssertEqual(c.handle(body: prompt(shell: "fish", exit: 127), authorization: nil), .accepted)
        let prompts = r.counter("molly_shell_prompts_total", help: "", labels: ["shell"])
        XCTAssertEqual(prompts.value(labels: ["shell": "zsh"]), 2)
        XCTAssertEqual(prompts.value(labels: ["shell": "fish"]), 1)
        let failures = r.counter("molly_shell_last_exit_nonzero_total", help: "", labels: ["shell"])
        XCTAssertEqual(failures.value(labels: ["shell": "zsh"]), 1)
        XCTAssertEqual(failures.value(labels: ["shell": "fish"]), 1)
        XCTAssertEqual(r.counter("molly_events_total", help: "", labels: ["source", "event"]).value(labels: ["source": "shell", "event": "prompt"]), 3)
        XCTAssertEqual(ProjectTracker.shared.snapshot()[.shell]?["aschepis/molly"], clock)
        XCTAssertFalse(r.render().contains("/Users/me"))
    }

    func testShellPromptWithoutCwdStillCounts() throws {
        let (c, r) = try make()
        XCTAssertEqual(c.handle(body: prompt(shell: "bash", cwd: nil), authorization: nil), .accepted)
        XCTAssertEqual(r.counter("molly_shell_prompts_total", help: "", labels: ["shell"]).value(labels: ["shell": "bash"]), 1)
    }

    func testShellPromptDoesNotTouchClaudeHookMetrics() throws {
        let (c, r) = try make()
        _ = c.handle(body: prompt(), authorization: nil)
        XCTAssertNil(r.gauge("molly_claude_hook_last_event_timestamp_seconds", help: "").value())
    }
}

final class ShellHookCommandTests: XCTestCase {
    private let endpoint = ShellHookCommand.Endpoint(url: "http://127.0.0.1:9777/event")

    func testSnippetsAreDelimitedAndPostTheRightShape() {
        for shell in ShellHookCommand.ShellKind.allCases {
            let s = ShellHookCommand.snippet(for: shell, endpoint: endpoint)
            XCTAssertTrue(s.hasPrefix(ShellHookCommand.beginMarker), shell.rawValue)
            XCTAssertTrue(s.hasSuffix(ShellHookCommand.endMarker), shell.rawValue)
            XCTAssertTrue(s.contains("curl -s -m 0.3"), shell.rawValue)
            XCTAssertTrue(s.contains("http://127.0.0.1:9777/event"), shell.rawValue)
            XCTAssertTrue(s.contains(#"\"shell\":\"\#(shell.rawValue)\""#), shell.rawValue)
            XCTAssertTrue(s.contains(#"\"cwd\":\"$PWD\""#), shell.rawValue)
            XCTAssertTrue(s.contains(#"\"exit\":$exit"#), shell.rawValue)
            XCTAssertTrue(s.contains(ShellHookCommand.optOutVariable), shell.rawValue)
            XCTAssertFalse(s.contains("Authorization"), shell.rawValue)
        }
        XCTAssertTrue(ShellHookCommand.snippet(for: .zsh, endpoint: endpoint).contains("add-zsh-hook precmd"))
        XCTAssertTrue(ShellHookCommand.snippet(for: .bash, endpoint: endpoint).contains("PROMPT_COMMAND"))
        XCTAssertTrue(ShellHookCommand.snippet(for: .fish, endpoint: endpoint).contains("--on-event fish_prompt"))
    }

    func testSnippetCarriesTokenWhenConfigured() throws {
        let config = try Config.parse(Data(#"{"server": {"port": 9000}, "collectors": {"events": {"token": "abc"}}}"#.utf8))
        let s = ShellHookCommand.snippet(for: .zsh, endpoint: ShellHookCommand.Endpoint(config: config))
        XCTAssertTrue(s.contains("-H 'Authorization: Bearer abc'"))
        XCTAssertTrue(s.contains("http://127.0.0.1:9000/event"))
    }

    func testAddingIsIdempotentAndPreservesOtherContent() {
        let block = ShellHookCommand.snippet(for: .zsh, endpoint: endpoint)
        let original = "export PATH=/x:$PATH\nalias ll='ls -l'\n"
        let once = ShellHookCommand.adding(block: block, to: original)
        XCTAssertTrue(once.hasPrefix(original))
        XCTAssertTrue(once.hasSuffix(ShellHookCommand.endMarker + "\n"))
        let twice = ShellHookCommand.adding(block: block, to: once)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice.components(separatedBy: ShellHookCommand.beginMarker).count, 2)
    }

    func testAddingReplacesAnOlderBlock() {
        let old = ShellHookCommand.snippet(for: .zsh, endpoint: ShellHookCommand.Endpoint(url: "http://127.0.0.1:1/event"))
        let new = ShellHookCommand.snippet(for: .zsh, endpoint: endpoint)
        let contents = "a\n" + old + "\n" + "b\n"
        let updated = ShellHookCommand.adding(block: new, to: contents)
        XCTAssertFalse(updated.contains("127.0.0.1:1/"))
        XCTAssertTrue(updated.contains("127.0.0.1:9777/"))
        XCTAssertTrue(updated.hasPrefix("a\nb\n"))
    }

    func testRemovingLeavesEverythingElse() {
        let block = ShellHookCommand.snippet(for: .bash, endpoint: endpoint)
        let original = "# mine\nexport A=1\n"
        let withBlock = ShellHookCommand.adding(block: block, to: original)
        XCTAssertEqual(ShellHookCommand.removing(from: withBlock), original)
        XCTAssertEqual(ShellHookCommand.removing(from: original), original)
        XCTAssertEqual(ShellHookCommand.removing(from: ""), "")
    }

    func testAddingToEmptyFile() {
        let block = ShellHookCommand.snippet(for: .fish, endpoint: endpoint)
        XCTAssertEqual(ShellHookCommand.adding(block: block, to: ""), block + "\n")
    }

    func testInstallAndUninstallOnTempHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("molly-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".zshrc")
        try "export A=1\n".write(to: rc, atomically: true, encoding: .utf8)

        ShellHookCommand.install(shell: .zsh, endpoint: endpoint, home: home)
        let installed = try String(contentsOf: rc, encoding: .utf8)
        XCTAssertTrue(installed.hasPrefix("export A=1\n"))
        XCTAssertTrue(installed.contains(ShellHookCommand.beginMarker))
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.contains("molly-backup") }
        XCTAssertEqual(backups.count, 1)

        ShellHookCommand.install(shell: .zsh, endpoint: endpoint, home: home)
        XCTAssertEqual(try String(contentsOf: rc, encoding: .utf8), installed)

        ShellHookCommand.uninstall(shell: .zsh, home: home)
        XCTAssertEqual(try String(contentsOf: rc, encoding: .utf8), "export A=1\n")

        // A missing rc file is created rather than failing.
        ShellHookCommand.install(shell: .fish, endpoint: endpoint, home: home)
        let fishRC = ShellHookCommand.rcURL(shell: .fish, home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fishRC.path))
        XCTAssertTrue(try String(contentsOf: fishRC, encoding: .utf8).contains("fish_prompt"))
    }
}
