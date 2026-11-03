import XCTest
@testable import Molly

final class FocusStateTests: XCTestCase {
    private let safari = FocusApp(name: "Safari", bundleID: "com.apple.Safari")
    private let xcode = FocusApp(name: "Xcode", bundleID: "com.apple.dt.Xcode")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func start(_ state: inout FocusState) {
        _ = state.advance(to: t0, frontmost: safari, idleSeconds: 0, locked: false, asleep: false)
    }

    func testFirstAdvanceCreditsNothing() {
        var state = FocusState()
        let d = state.advance(to: t0, frontmost: safari, idleSeconds: 0, locked: false, asleep: false)
        XCTAssertEqual(d, FocusDeltas())
        XCTAssertEqual(state.frontmost, safari)
        XCTAssertTrue(state.userActive)
    }

    func testActiveTimeIsCreditedToFrontmostApp() {
        var state = FocusState()
        start(&state)
        let d = state.advance(to: at(5), frontmost: safari, idleSeconds: 1, locked: false, asleep: false)
        XCTAssertEqual(d.focusSeconds, [safari: 5])
        XCTAssertEqual(d.activeSeconds, 5)
        XCTAssertEqual(d.idleSeconds, 0)
        XCTAssertEqual(state.sessionSeconds(at: at(5)), 5)
    }

    func testSwitchSplitsTimeAndCountsOnce() {
        var state = FocusState()
        start(&state)
        let d = state.advance(to: at(3), frontmost: xcode, idleSeconds: 0, locked: false, asleep: false)
        XCTAssertEqual(d.focusSeconds, [safari: 3]) // the interval belongs to the app that was frontmost
        XCTAssertEqual(d.switches, 1)
        let next = state.advance(to: at(8), frontmost: xcode, idleSeconds: 0, locked: false, asleep: false)
        XCTAssertEqual(next.focusSeconds, [xcode: 5])
        XCTAssertEqual(next.switches, 0)
        XCTAssertEqual(state.sessionSeconds(at: at(8)), 5)
    }

    func testIdleStopsFocusCreditAfterThreshold() {
        var state = FocusState(idleThreshold: 300)
        start(&state)
        _ = state.advance(to: at(5), frontmost: safari, idleSeconds: 400, locked: false, asleep: false)
        XCTAssertFalse(state.userActive)
        let d = state.advance(to: at(10), frontmost: safari, idleSeconds: 405, locked: false, asleep: false)
        XCTAssertEqual(d.focusSeconds, [:])
        XCTAssertEqual(d.idleSeconds, 5)
        XCTAssertEqual(d.activeSeconds, 0)
    }

    func testLockedScreenIsNotActiveAndCountsEventOnce() {
        var state = FocusState()
        start(&state)
        let lock = state.advance(to: at(2), frontmost: safari, idleSeconds: 0, locked: true, asleep: false)
        XCTAssertEqual(lock.lockEvents, 1)
        XCTAssertEqual(lock.focusSeconds, [safari: 2])
        let still = state.advance(to: at(7), frontmost: safari, idleSeconds: 0, locked: true, asleep: false)
        XCTAssertEqual(still.lockEvents, 0)
        XCTAssertEqual(still.focusSeconds, [:])
        XCTAssertEqual(still.idleSeconds, 5)
    }

    func testSleepCreditsNothingAndWakeIsCounted() {
        var state = FocusState()
        start(&state)
        let sleep = state.advance(to: at(2), frontmost: safari, idleSeconds: 0, locked: false, asleep: true)
        XCTAssertEqual(sleep.sleepEvents, 1)
        // 50s asleep is within maxGap but must still not be credited.
        let wake = state.advance(to: at(52), frontmost: safari, idleSeconds: 0, locked: false, asleep: false)
        XCTAssertEqual(wake.wakeEvents, 1)
        XCTAssertEqual(wake.activeSeconds, 0)
        XCTAssertEqual(wake.idleSeconds, 0)
        XCTAssertTrue(state.userActive)
    }

    func testGapsLongerThanMaxGapAreDropped() {
        var state = FocusState(maxGap: 60)
        start(&state)
        let d = state.advance(to: at(3600), frontmost: safari, idleSeconds: 0, locked: false, asleep: false)
        XCTAssertEqual(d.activeSeconds, 0)
        XCTAssertEqual(d.focusSeconds, [:])
    }

    func testCardinalityGuardFoldsNewLabelsIntoOther() {
        var guardrail = CardinalityGuard(limit: 2)
        XCTAssertEqual(guardrail.admit("a"), "a")
        XCTAssertEqual(guardrail.admit("b"), "b")
        XCTAssertEqual(guardrail.admit("c"), "other")
        XCTAssertEqual(guardrail.admit("a"), "a")
        var unlimited = CardinalityGuard(limit: 0)
        XCTAssertEqual(unlimited.admit("z"), "z")
    }

    func testCollectorPublishesAtMostOneFocusSeries() throws {
        let registry = MetricsRegistry()
        let collector = try FocusCollector(settings: CollectorSettings(name: "focus", raw: [:]))
        try collector.start(registry: registry)
        defer { collector.stop() }
        try collector.collect()
        try collector.collect()
        let lines = registry.render().split(separator: "\n").filter { $0.hasPrefix("molly_focus_app{") }
        XCTAssertLessThanOrEqual(lines.count, 1)
        XCTAssertTrue(registry.familyNames.contains("molly_idle_seconds"))
        XCTAssertTrue(registry.familyNames.contains("molly_windows_on_screen"))
    }
}
