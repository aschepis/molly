import XCTest
@testable import Molly

final class EnergyCollectorTests: XCTestCase {
    private let fixture = """
    Processes: 500 total
    PID    COMMAND          POWER
    598    WindowServer     0.0
    22878  com.apple.Virtua 0.0

    Processes: 500 total
    PID    COMMAND          POWER
    598    WindowServer     25.5
    22878  com.apple.Virtua 25.2
    4001   Google Chrome He 3.5
    1285   avconferenced    16.9
    """

    func testSkipsFirstSampleAndKeepsSecond() {
        let rows = EnergyParse.rows(fixture)
        XCTAssertEqual(rows.map { $0.pid }, [598, 22878, 4001, 1285])
        XCTAssertEqual(rows.first, EnergyRow(pid: 598, command: "WindowServer", impact: 25.5))
    }

    func testCommandWithSpacesIsKeptWhole() {
        let row = EnergyParse.row("4001   Google Chrome He 3.5 ")
        XCTAssertEqual(row, EnergyRow(pid: 4001, command: "Google Chrome He", impact: 3.5))
    }

    func testSingleBlockYieldsNothing() {
        XCTAssertTrue(EnergyParse.rows("PID COMMAND POWER\n1 launchd 2.0\n").isEmpty)
    }

    func testByNameSumsHelpersAndTopKeepsLargest() {
        let rows = [EnergyRow(pid: 1, command: "a", impact: 1), EnergyRow(pid: 2, command: "a", impact: 2),
                    EnergyRow(pid: 3, command: "b", impact: 2.5), EnergyRow(pid: 4, command: "c", impact: 0.1)]
        let sums = EnergyMath.byName(rows) { $0.command }
        XCTAssertEqual(sums, ["a": 3, "b": 2.5, "c": 0.1])
        XCTAssertEqual(EnergyMath.top(sums, n: 2), ["a": 3, "b": 2.5])
    }

    func testCollectPublishesMetricFamilies() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/top") else { throw XCTSkip("top not present") }
        let collector = try EnergyCollector(settings: CollectorSettings(name: "energy", raw: [:]))
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        let text = registry.render()
        XCTAssertTrue(text.contains("molly_energy_impact_sum"))
        XCTAssertTrue(text.contains("molly_energy_impact{"))
    }
}
