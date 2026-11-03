import XCTest
@testable import Molly

final class ProcessesCollectorTests: XCTestCase {
    private func sample(_ pid: Int32, _ name: String, cpu: Double, rss: Double = 0) -> ProcessSample {
        ProcessSample(pid: pid, name: name, cpuSeconds: cpu, residentBytes: rss)
    }

    func testCPURatiosFromDeltas() {
        let ratios = ProcessMath.cpuRatios(previous: [1: 10, 2: 50, 3: 5],
                                           current: [sample(1, "a", cpu: 12), sample(2, "b", cpu: 10), sample(4, "new", cpu: 99)],
                                           wallSeconds: 4)
        XCTAssertEqual(ratios[1], 0.5)
        XCTAssertEqual(ratios[2], 0) // CPU time went backwards: pid reuse
        XCTAssertEqual(ratios[4], 0) // no baseline
        XCTAssertNil(ratios[3])
        XCTAssertTrue(ProcessMath.cpuRatios(previous: [1: 1], current: [sample(1, "a", cpu: 2)], wallSeconds: 0).isEmpty)
    }

    func testSummarizeMergesNamesAndTopRanks() {
        let samples = [sample(1, "chrome", cpu: 0, rss: 100), sample(2, "chrome", cpu: 0, rss: 50),
                       sample(3, "node", cpu: 0, rss: 120), sample(4, "zsh", cpu: 0, rss: 5)]
        let summary = ProcessMath.summarize(samples, ratios: [1: 0.25, 2: 0.25, 3: 0.4, 4: 0])
        XCTAssertEqual(summary["chrome"], ProcessSummary(cpuRatio: 0.5, residentBytes: 150, count: 2))
        XCTAssertEqual(ProcessMath.top(summary, n: 2) { $0.cpuRatio }, ["chrome", "node"])
        XCTAssertEqual(ProcessMath.top(summary, n: 1) { $0.residentBytes }, ["chrome"])
    }

    func testAgentMatchingIsCaseInsensitiveSubstring() {
        let agents = AgentMatcher.merged(config: nil)
        XCTAssertEqual(AgentMatcher.matches(name: "Cursor Helper (Renderer)", agents: agents), ["cursor"])
        XCTAssertEqual(AgentMatcher.matches(name: "Claude", agents: agents), ["claude"])
        XCTAssertEqual(AgentMatcher.matches(name: "ollama", agents: agents), ["ollama"])
        XCTAssertEqual(AgentMatcher.matches(name: "zsh", agents: agents), [])
    }

    func testAgentConfigOverridesAndDisables() {
        let config: [String: JSONValue] = ["claude": .array([.string("claude-code")]), "gemini": .array([]),
                                           "custom": .array([.string("mytool")])]
        let agents = AgentMatcher.merged(config: config)
        XCTAssertEqual(agents["claude"], ["claude-code"])
        XCTAssertNil(agents["gemini"])
        XCTAssertEqual(agents["custom"], ["mytool"])
        XCTAssertEqual(agents["codex"], ["codex"])
    }

    func testCollectPublishesTopProcessesAndAgents() throws {
        let registry = MetricsRegistry()
        let collector = try ProcessesCollector(settings: CollectorSettings(name: "processes", raw: [:]))
        try collector.start(registry: registry)
        try collector.collect()
        Thread.sleep(forTimeInterval: 0.2)
        try collector.collect()
        XCTAssertTrue(registry.familyNames.contains("molly_process_rss_bytes"))
        let agentGauge = registry.gauge("molly_agent_processes", help: "", labels: ["agent"])
        XCTAssertNotNil(agentGauge.value(labels: ["agent": "aider"]))
        XCTAssertNotNil(registry.gauge("molly_agent_process_cpu_ratio", help: "", labels: ["agent"]).value(labels: ["agent": "aider"]))
    }

    func testDisabledNamePolicyPublishesNoPerNameSeries() throws {
        let raw: [String: JSONValue] = ["names": .object(["enabled": .bool(false)])]
        let registry = MetricsRegistry()
        let collector = try ProcessesCollector(settings: CollectorSettings(name: "processes", raw: raw))
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertFalse(registry.render().contains("molly_process_rss_bytes"))
        XCTAssertTrue(registry.render().contains("molly_agent_processes"))
    }
}
