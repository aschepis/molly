import XCTest
@testable import Molly

// Fixture lines are real `pmset -g log` output captured on this machine,
// trimmed after the reason text. Fields are separated by a tab.
final class PowerParseTests: XCTestCase {
    private func line(_ time: String, _ type: String, _ detail: String) -> String {
        "\(time) \(type.padding(toLength: 20, withPad: " ", startingAt: 0))\t\(detail)"
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(PowerParse.timestamp(text))
    }

    private var fixture: String {
        [
            line("2026-11-02 09:46:05 -0500", "Assertions", "PID 23563(Google Chrome) Created NoDisplaySleepAssertion \"Video Wake Lock\" 00:00:00"),
            line("2026-11-02 09:55:04 -0500", "Sleep", "Entering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using AC (Charge:100%) 7 secs"),
            line("2026-11-02 09:55:06 -0500", "Wake Requests", "[process=mDNSResponder request=Maintenance deltaSecs=7199]"),
            line("2026-11-02 09:55:11 -0500", "DarkWake", "DarkWake from Deep Idle [CDNPB] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty Using AC (Charge:100%) 45 secs"),
            line("2026-11-02 09:55:11 -0500", "WakeDetails", "DriverReason:smc.sysState.Wake(0x70070000) - DriverDetails:"),
            line("2026-11-02 10:09:17 -0500", "Wake", "DarkWake to FullWake from Deep Idle [CDNVA] : due to HID Activity Using AC (Charge:100%)"),
            line("2026-11-02 11:00:00 -0500", "Sleep", "Entering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 7 secs"),
            line("2026-11-02 18:34:39 -0500", "Wake", "Wake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty RTP.multi-touch/HID Activity Using AC"),
            "not a log line",
            "",
        ].joined(separator: "\n")
    }

    func testTimestampUsesOffset() throws {
        let t = try date("2026-11-03 08:41:12 -0500")
        XCTAssertEqual(try date("2026-11-03 13:41:12 +0000"), t)
        XCTAssertNil(PowerParse.timestamp("yesterday"))
    }

    func testEventsKeepOnlySleepWakeDarkWake() {
        let events = PowerParse.events(fixture)
        XCTAssertEqual(events.map(\.kind), [.sleep, .darkwake, .wake, .sleep, .wake])
    }

    func testWakeReasonsAreNormalised() {
        let events = PowerParse.events(fixture)
        XCTAssertEqual(events.filter { $0.kind == .wake }.map(\.reason), ["user activity", "lid"])
        XCTAssertEqual(events.filter { $0.kind != .wake }.map(\.reason), ["", "", ""])
    }

    func testWakeReasonTable() {
        XCTAssertEqual(PowerParse.wakeReason("Wake from Normal Sleep : due to Power Button Using AC"), "power button")
        XCTAssertEqual(PowerParse.wakeReason("due to EC.PWRB"), "power button")
        XCTAssertEqual(PowerParse.wakeReason("DarkWake to FullWake : due to Notification"), "notification")
        XCTAssertEqual(PowerParse.wakeReason("Wake from Deep Idle : due to RTC (Alarm)"), "scheduled")
        XCTAssertEqual(PowerParse.wakeReason("Wake : due to XHC1 USB device /secret-host"), "other")
        XCTAssertEqual(PowerParse.wakeReason(""), "other")
    }

    func testBootTimeAndNewBoot() throws {
        let boot = try XCTUnwrap(PowerParse.bootTime(sysctl: "kern.boottime: { sec = 1789156556, usec = 652 } Fri Sep 11 15:55:56 2026"))
        XCTAssertEqual(boot.timeIntervalSince1970, 1_789_156_556)
        XCTAssertNil(PowerParse.bootTime(sysctl: "garbage"))
        XCTAssertTrue(PowerParse.isNewBoot(100, lastSeen: nil, floor: 50))
        XCTAssertFalse(PowerParse.isNewBoot(40, lastSeen: nil, floor: 50))
        XCTAssertFalse(PowerParse.isNewBoot(100, lastSeen: 100, floor: 50))
        XCTAssertTrue(PowerParse.isNewBoot(200, lastSeen: 100, floor: 50))
    }

    // MARK: day totals

    private func event(_ time: String, _ kind: PowerEventKind) throws -> PowerEvent {
        PowerEvent(time: try date("2026-11-03 \(time) +0000"), kind: kind, reason: "")
    }

    func testAwakeAndSleepSecondsFromPairs() throws {
        let events = [
            try event("01:00:00", .sleep),   // awake from midnight until 01:00 (inferred): 3600
            try event("03:00:00", .darkwake), // still asleep
            try event("04:00:00", .wake),
            try event("05:30:00", .sleep),   // awake 1.5h
            try event("06:00:00", .wake),    // awake until now (07:00): 1h
        ]
        let totals = try XCTUnwrap(PowerParse.dayTotals(events: events, now: date("2026-11-03 07:00:00 +0000"),
                                                        dayStart: date("2026-11-03 00:00:00 +0000")))
        XCTAssertEqual(totals.awake, 3600 + 5400 + 3600)
        XCTAssertEqual(totals.asleep, 3 * 3600 + 1800)
        XCTAssertEqual(totals.awake + totals.asleep, 7 * 3600)
    }

    func testStateAtMidnightComesFromLastEarlierEvent() throws {
        let events = [try event("23:00:00", .wake).shifted(days: -1), try event("02:00:00", .sleep)]
        let totals = try XCTUnwrap(PowerParse.dayTotals(events: events, now: date("2026-11-03 03:00:00 +0000"),
                                                        dayStart: date("2026-11-03 00:00:00 +0000")))
        XCTAssertEqual(totals.awake, 2 * 3600)
        XCTAssertEqual(totals.asleep, 3600)
    }

    func testNoEventsGivesNoTotals() throws {
        XCTAssertNil(PowerParse.dayTotals(events: [], now: Date(), dayStart: Date().addingTimeInterval(-3600)))
    }

    func testFutureEventsAreIgnored() throws {
        let totals = try XCTUnwrap(PowerParse.dayTotals(events: [try event("08:00:00", .sleep), try event("09:00:00", .wake)],
                                                        now: date("2026-11-03 08:30:00 +0000"),
                                                        dayStart: date("2026-11-03 00:00:00 +0000")))
        XCTAssertEqual(totals.awake, 8 * 3600)
        XCTAssertEqual(totals.asleep, 1800)
    }
}

private extension PowerEvent {
    func shifted(days: Int) -> PowerEvent {
        PowerEvent(time: time.addingTimeInterval(Double(days) * 86400), kind: kind, reason: reason)
    }
}

final class BuildsLogicTests: XCTestCase {
    func testDefaultsMatchExactNamesOnly() {
        let tools = BuildMatcher.defaults
        XCTAssertEqual(BuildMatcher.tools(for: "swift-frontend", config: tools), ["swift"])
        XCTAssertEqual(BuildMatcher.tools(for: "go", config: tools), ["go"])
        XCTAssertEqual(BuildMatcher.tools(for: "gopls", config: tools), [])
        XCTAssertEqual(BuildMatcher.tools(for: "clangd", config: tools), [])
        XCTAssertEqual(BuildMatcher.tools(for: "clang-17", config: tools), ["clang"])
        XCTAssertEqual(BuildMatcher.tools(for: "Make", config: tools), ["make"])
        XCTAssertEqual(BuildMatcher.tools(for: "java", config: tools), [])
        XCTAssertEqual(BuildMatcher.tools(for: "buildkitd", config: tools), [])
    }

    func testConfigOverridesAndDisables() {
        let merged = BuildMatcher.merged(config: ["go": .array([]), "bazel": .array([.string("bazel")]), "make": .array([.string("remake")])])
        XCTAssertNil(merged["go"])
        XCTAssertEqual(merged["bazel"], ["bazel"])
        XCTAssertEqual(merged["make"], ["remake"])
        XCTAssertEqual(merged["swift"], BuildMatcher.defaults["swift"])
    }

    func testTrackerAccumulatesSecondsAndCountsStarts() {
        var tracker = BuildTracker()
        var update = tracker.observe(counts: ["swift": 0, "go": 0], elapsed: 0)
        XCTAssertEqual(update, BuildTracker.Update())
        XCTAssertFalse(tracker.anyActive)

        update = tracker.observe(counts: ["swift": 2, "go": 0], elapsed: 15)
        XCTAssertEqual(update.started, ["swift"])
        XCTAssertEqual(update.seconds, ["swift": 15])
        XCTAssertTrue(tracker.anyActive)

        update = tracker.observe(counts: ["swift": 1, "go": 0], elapsed: 15)
        XCTAssertEqual(update.started, [])
        XCTAssertEqual(update.seconds, ["swift": 15])

        update = tracker.observe(counts: ["swift": 0, "go": 0], elapsed: 15)
        XCTAssertEqual(update, BuildTracker.Update())
        XCTAssertFalse(tracker.anyActive)

        update = tracker.observe(counts: ["swift": 3, "go": 1], elapsed: 15)
        XCTAssertEqual(update.started, ["go", "swift"])
    }

    func testXcodeNewBuildsUseCursorAndDedupe() {
        let base = Date(timeIntervalSince1970: 1000)
        let a = XcodeLogs.Entry(path: "/dd/App-x/Logs/Build/A.xcactivitylog", modified: base.addingTimeInterval(10))
        let b = XcodeLogs.Entry(path: "/dd/App-x/Logs/Build/B.xcactivitylog", modified: base.addingTimeInterval(20))
        let old = XcodeLogs.Entry(path: "/dd/App-x/Logs/Build/Old.xcactivitylog", modified: base.addingTimeInterval(-5))
        let manifest = XcodeLogs.Entry(path: "/dd/App-x/Logs/Build/LogStoreManifest.plist", modified: base.addingTimeInterval(30))

        var result = XcodeLogs.newBuilds(entries: [a, old, manifest], cursor: base, counted: [])
        XCTAssertEqual(result.fresh, [a])
        XCTAssertEqual(result.cursor, a.modified)

        result = XcodeLogs.newBuilds(entries: [a, b], cursor: result.cursor, counted: [a.path])
        XCTAssertEqual(result.fresh, [b])
        XCTAssertEqual(result.cursor, b.modified)

        result = XcodeLogs.newBuilds(entries: [a, b], cursor: result.cursor, counted: [a.path, b.path])
        XCTAssertTrue(result.fresh.isEmpty)
    }

    func testDuOutput() {
        XCTAssertEqual(XcodeLogs.bytes(duOutput: "2048\t/Users/x/DerivedData\n"), 2048 * 1024)
        XCTAssertNil(XcodeLogs.bytes(duOutput: ""))
        XCTAssertNil(XcodeLogs.bytes(duOutput: "du: cannot read"))
    }

    func testCollectRunsAndPublishesFamilies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("molly-builds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let collector = BuildsCollector(settings: CollectorSettings(name: "builds", raw: ["xcode": .bool(false)]), stateFolder: folder)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        let text = registry.render()
        XCTAssertTrue(text.contains("molly_build_active 0") || text.contains("molly_build_active 1"))
        XCTAssertTrue(text.contains("molly_build_processes{tool=\"swift\"}"))
    }
}

final class TabsParseTests: XCTestCase {
    func testCountsFromFlattenedList() {
        XCTAssertEqual(TabsParse.counts(osascript: "2, 5, 3\n"), TabCounts(windows: 2, tabs: 8))
        XCTAssertEqual(TabsParse.counts(osascript: "1, 12"), TabCounts(windows: 1, tabs: 12))
        XCTAssertEqual(TabsParse.counts(osascript: "0\n"), TabCounts(windows: 0, tabs: 0))
    }

    func testCountsRejectNonNumbers() {
        XCTAssertNil(TabsParse.counts(osascript: ""))
        XCTAssertNil(TabsParse.counts(osascript: "missing value"))
        XCTAssertNil(TabsParse.counts(osascript: "2, x"))
        XCTAssertNil(TabsParse.counts(osascript: "-1"))
    }

    func testScriptAsksForCountsOnly() {
        let script = TabsParse.script(bundleID: "com.google.Chrome")
        XCTAssertEqual(script, "tell application id \"com.google.Chrome\" to return (count of windows) & (count of tabs of windows)")
        XCTAssertFalse(script.contains("URL"))
        XCTAssertFalse(script.contains("title"))
    }

    func testSelectionNeverIncludesBrowsersThatAreNotRunning() {
        let running: Set<String> = ["com.google.Chrome", "com.apple.Finder"]
        XCTAssertEqual(TabsParse.selected(labels: [], running: running).map(\.label), ["chrome"])
        XCTAssertEqual(TabsParse.selected(labels: ["safari"], running: running), [])
        XCTAssertEqual(TabsParse.selected(labels: ["chrome", "safari"], running: running).map(\.label), ["chrome"])
    }

    func testCollectorPublishesPerBrowserAndSkipsFailures() throws {
        var asked: [String] = []
        let collector = TabsCollector(
            settings: CollectorSettings(name: "tabs", raw: [:]),
            running: { ["com.google.Chrome", "com.apple.Safari"] },
            runScript: { script in
                asked.append(script)
                if script.contains("com.apple.Safari") { return ShellResult(status: 1, stdout: "", stderr: "not authorized") }
                return ShellResult(status: 0, stdout: "2, 5, 3\n", stderr: "")
            })
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        let text = registry.render()
        XCTAssertTrue(text.contains("molly_browser_windows{browser=\"chrome\"} 2"))
        XCTAssertTrue(text.contains("molly_browser_tabs{browser=\"chrome\"} 8"))
        XCTAssertFalse(text.contains("browser=\"safari\"} "))
        XCTAssertEqual(asked.count, 2)
    }

    func testCollectorThrowsUnavailableWhenEveryBrowserFails() {
        let collector = TabsCollector(settings: CollectorSettings(name: "tabs", raw: [:]),
                                      running: { ["com.google.Chrome"] },
                                      runScript: { _ in ShellResult(status: 1, stdout: "", stderr: "denied") })
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }

    func testCollectorDoesNothingWhenNoBrowserRuns() throws {
        let collector = TabsCollector(settings: CollectorSettings(name: "tabs", raw: [:]),
                                      running: { [] },
                                      runScript: { _ in XCTFail("must not run a script"); return ShellResult(status: 0, stdout: "", stderr: "") })
        XCTAssertNoThrow(try collector.collect())
    }
}
