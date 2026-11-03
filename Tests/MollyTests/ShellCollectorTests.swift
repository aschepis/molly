import XCTest
@testable import Molly

final class ShellParsingTests: XCTestCase {
    private func name(_ command: String) -> String? { ShellParsing.analyze(command, wantHosts: false).name }
    private func hosts(_ command: String) -> [String] { ShellParsing.analyze(command, wantHosts: true).hosts }

    func testCommandNameStripsEnvSudoTimeNohup() {
        XCTAssertEqual(name("git status"), "git")
        XCTAssertEqual(name("FOO=bar BAZ=1 make test"), "make")
        XCTAssertEqual(name("sudo rm -rf /tmp/x"), "rm")
        XCTAssertEqual(name("sudo -u root apt update"), "apt")
        XCTAssertEqual(name("time nohup /usr/bin/python3 run.py &"), "python3")
        XCTAssertEqual(name("sudo FOO=1 time ./build.sh"), "build.sh")
        XCTAssertEqual(name("'/opt/My Tools/tool' --flag"), "tool")
        XCTAssertNil(name("FOO=bar"))
        XCTAssertNil(name(""))
        XCTAssertNil(name("   "))
    }

    func testPipelinesAndChainsAttributeToFirstSegment() {
        XCTAssertEqual(name("cat f | grep x | wc -l"), "cat")
        XCTAssertEqual(name("cd build && cmake .. && make"), "cd")
        XCTAssertEqual(name("false || echo failed"), "false")
        XCTAssertEqual(name("make; make install"), "make")
        XCTAssertEqual(name("make 2>&1 | tee log"), "make")
        XCTAssertEqual(ShellParsing.segments("make 2>&1 | tee log").count, 2)
        XCTAssertEqual(ShellParsing.segments("make &> out.log").count, 1)
        XCTAssertEqual(ShellParsing.segments("sleep 5 &").count, 1)
        XCTAssertEqual(ShellParsing.segments("a |& b").count, 2)
    }

    func testQuotesProtectOperatorsAndSpaces() {
        XCTAssertEqual(ShellParsing.segments(#"echo "a | b && c" 'd; e'"#), [["echo", "a | b && c", "d; e"]])
        XCTAssertEqual(ShellParsing.segments(#"echo "say \"hi\" | there""#), [["echo", #"say "hi" | there"#]])
        XCTAssertEqual(ShellParsing.segments(#"echo a\ b | cat"#), [["echo", "a b"], ["cat"]])
        XCTAssertEqual(ShellParsing.segments("echo hi # | not a pipe"), [["echo", "hi"]])
        XCTAssertEqual(ShellParsing.segments("echo a#b"), [["echo", "a#b"]])
        XCTAssertEqual(ShellParsing.segments(#"echo "unterminated | quote"#), [["echo", "unterminated | quote"]])
        XCTAssertEqual(name(#"grep "a|b" file"#), "grep")
    }

    func testUrlHosts() {
        XCTAssertEqual(hosts("curl -H 'X: y' https://API.Example.com:8443/v1?x=1 | jq ."), ["api.example.com"])
        XCTAssertEqual(hosts("git clone https://user:pw@github.com/a/b.git && cd b"), ["github.com"])
        XCTAssertEqual(hosts("open http://localhost:3000/"), ["localhost"])
        XCTAssertEqual(hosts("curl http://[::1]:8080/x"), ["::1"])
        XCTAssertEqual(hosts("echo ok # curl https://ignored.example.com"), [])
        XCTAssertEqual(hosts("curl https://a.com/x https://a.com/y https://b.org"), ["a.com", "b.org"])
    }

    func testNetworkToolArguments() {
        XCTAssertEqual(hosts("ssh -i ~/.ssh/key -p 2222 user@box.local ls"), ["box.local"])
        XCTAssertEqual(hosts("ssh -o StrictHostKeyChecking=no admin@10.0.0.5"), ["10.0.0.5"])
        XCTAssertEqual(hosts("scp file.txt user@host.example.com:/tmp/"), ["host.example.com"])
        XCTAssertEqual(hosts("scp -r -P 22 host2:/a ./b"), ["host2"])
        XCTAssertEqual(hosts("sftp deploy@files.example.net"), ["files.example.net"])
        XCTAssertEqual(hosts("wget -O out.html example.org/file"), ["example.org"])
        XCTAssertEqual(hosts("curl -X POST -d '{}' localhost:3000/api"), ["localhost"])
        XCTAssertEqual(hosts("ping -c 3 1.1.1.1"), ["1.1.1.1"])
        XCTAssertEqual(hosts("dig @8.8.8.8 example.com MX"), ["example.com"])
        XCTAssertEqual(hosts("nslookup example.com 8.8.8.8"), ["example.com"])
        XCTAssertEqual(hosts("telnet mail.example.com 25"), ["mail.example.com"])
        XCTAssertEqual(hosts("nc -l 8080"), [])
        XCTAssertEqual(hosts("nc -w 2 db.internal 5432"), ["db.internal"])
        XCTAssertEqual(hosts("sudo FOO=1 ssh root@srv"), ["srv"])
        XCTAssertEqual(hosts("cat notes.txt | ssh jump 'cat > x'"), ["jump"])
        XCTAssertEqual(hosts("ls -la"), [])
        XCTAssertEqual(hosts("ssh"), [])
    }

    func testNormalizeHost() {
        XCTAssertEqual(ShellParsing.normalizeHost("User@Host.Example.COM:22"), "host.example.com")
        XCTAssertEqual(ShellParsing.normalizeHost("[2001:db8::1]:443"), "2001:db8::1")
        XCTAssertEqual(ShellParsing.normalizeHost("example.com."), "example.com")
        XCTAssertNil(ShellParsing.normalizeHost("-flag"))
        XCTAssertNil(ShellParsing.normalizeHost("$HOST"))
        XCTAssertNil(ShellParsing.normalizeHost("8080"))
        XCTAssertNil(ShellParsing.normalizeHost("~/file"))
        XCTAssertNil(ShellParsing.normalizeHost(""))
    }

    func testZshExtendedHistoryWithMultilineAndSplitBatches() {
        var parser = ShellParsing.ZshParser()
        let first = parser.feed([
            ": 1793655695:0;brew upgrade claude-code@latest",
            ": 1793655700:2;echo one \\",
            "  two \\",
        ])
        XCTAssertEqual(first, [ShellParsing.Entry(command: "brew upgrade claude-code@latest", timestamp: 1_793_655_695)])
        let second = parser.feed(["  three", ": 1793655800:0;ls", "plain line without header"])
        XCTAssertEqual(second.map(\.timestamp), [1_793_655_700, 1_793_655_800, nil])
        XCTAssertEqual(ShellParsing.analyze(second[0].command, wantHosts: false).name, "echo")
        XCTAssertEqual(second[2].command, "plain line without header")
    }

    func testBashHistoryWithAndWithoutTimestamps() {
        let entries = ShellParsing.parseBash(["ls", "#1793655695", "make", "", "pwd"])
        XCTAssertEqual(entries, [
            ShellParsing.Entry(command: "ls", timestamp: nil),
            ShellParsing.Entry(command: "make", timestamp: 1_793_655_695),
            ShellParsing.Entry(command: "pwd", timestamp: nil),
        ])
    }

    func testFishHistory() {
        let entries = ShellParsing.parseFish([
            "- cmd: git status", "  when: 1793655695",
            "- cmd: cat x.txt", "  paths:", "    - x.txt", "  when: 1793655800",
            "  when: 5",
        ])
        XCTAssertEqual(entries.map(\.command), ["git status", "cat x.txt"])
        XCTAssertEqual(entries.map(\.timestamp), [1_793_655_695, 1_793_655_800])
    }
}

final class ShellCollectorTests: TempFolderTestCase {
    private func makeCollector(history: URL, state: URL, extra: [String: JSONValue] = [:]) throws -> (ShellCollector, MetricsRegistry) {
        var raw: [String: JSONValue] = [
            "shells": strings(["zsh"]),
            "zshHistory": .string(history.path),
        ]
        raw.merge(extra) { $1 }
        let collector = try ShellCollector(settings: settings("shell", raw), stateFolder: state,
                                           startedAt: Date().addingTimeInterval(-100))
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        return (collector, registry)
    }

    private func zshLine(_ command: String, secondsAgo: Int = 0) -> String {
        ": \(Int(Date().timeIntervalSince1970) - secondsAgo):0;\(command)\n"
    }

    func testCountsOnlyNewCommandsAndSeedsTodayFromHistory() throws {
        let dir = makeTempFolder()
        let history = dir.appendingPathComponent("zsh_history")
        let earlierToday = Int(Clock.startOfToday().timeIntervalSince1970) + 1
        try append(": \(earlierToday):0;old command\n", to: history)
        try backdate(history)
        let (collector, registry) = try makeCollector(history: history, state: dir.appendingPathComponent("state"))

        try collector.collect()
        XCTAssertEqual(value(registry, "molly_shell_commands_total", ["shell": "zsh"]), 0)
        XCTAssertEqual(value(registry, "molly_shell_commands_today", ["shell": "zsh"]), 1)

        try append(zshLine("ls -la") + zshLine("git status | cat && echo done"), to: history)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_shell_commands_total", ["shell": "zsh"]), 2)
        XCTAssertEqual(value(registry, "molly_shell_commands_today", ["shell": "zsh"]), 3)

        try collector.collect()
        XCTAssertEqual(value(registry, "molly_shell_commands_total", ["shell": "zsh"]), 2)
        XCTAssertFalse(registry.render().contains("molly_shell_command_names_total"), "commands policy is off by default")
        XCTAssertFalse(registry.render().contains("molly_shell_network_hosts_total"), "hosts policy is off by default")
    }

    func testRewrittenHistoryDoesNotReplayOldEntries() throws {
        let dir = makeTempFolder()
        let history = dir.appendingPathComponent("zsh_history")
        try append(zshLine("a", secondsAgo: 5000) + zshLine("b", secondsAgo: 4000), to: history)
        try backdate(history)
        let (collector, registry) = try makeCollector(history: history, state: dir.appendingPathComponent("state"))
        try collector.collect()
        // zsh merging other sessions appends entries older than what we have seen
        try append(zshLine("c", secondsAgo: 3000) + zshLine("d"), to: history)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_shell_commands_total", ["shell": "zsh"]), 1)
    }

    func testCommandAndHostPoliciesWhenEnabled() throws {
        let dir = makeTempFolder()
        let history = dir.appendingPathComponent("zsh_history")
        try Data().write(to: history)
        try backdate(history)
        let (collector, registry) = try makeCollector(history: history, state: dir.appendingPathComponent("state"), extra: [
            "commands": .object(["enabled": .bool(true), "mode": .string("allowlist"), "patterns": strings(["git", "curl"])]),
            "hosts": .object(["enabled": .bool(true)]),
        ])
        try collector.collect()
        try append(zshLine("git push") + zshLine("curl https://api.example.com/x | jq .") + zshLine("secret-tool --token abc"), to: history)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_shell_command_names_total", ["command": "git"]), 1)
        XCTAssertEqual(value(registry, "molly_shell_command_names_total", ["command": "curl"]), 1)
        XCTAssertEqual(value(registry, "molly_shell_command_names_total", ["command": "other"]), 1)
        XCTAssertEqual(value(registry, "molly_shell_network_hosts_total", ["remote_host": "api.example.com"]), 1)
        XCTAssertFalse(registry.render().contains("secret"))
        XCTAssertFalse(registry.render().contains("token"))
    }

    func testMissingHistoryIsUnavailable() throws {
        let dir = makeTempFolder()
        let (collector, _) = try makeCollector(history: dir.appendingPathComponent("nope"), state: dir)
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }
}
