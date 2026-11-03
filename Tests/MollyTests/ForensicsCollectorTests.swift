import XCTest
@testable import Molly

// Fixtures follow real `last -y` output from macOS.
final class ForensicsParseTests: XCTestCase {
    private let rebootOutput = """
    reboot time                                Fri Sep 11 2026 15:55
    reboot time                                Fri Jul 10 2026 16:24
    reboot time                                Thu Jun 11 2026 07:40

    wtmp begins Thu Nov 13 21:48:39 EST 2025
    """

    private let shutdownOutput = """
    shutdown time                              Fri Sep 11 2026 15:45
    shutdown time                              Fri Jul 10 2026 16:20 still running

    wtmp begins Thu Nov 13 21:48:39 EST 2025
    """

    private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return try XCTUnwrap(Calendar.current.date(from: parts))
    }

    func testRebootEntriesSortedAndFooterSkipped() throws {
        let entries = ForensicsParse.lastEntries(rebootOutput, command: "reboot")
        XCTAssertEqual(entries.map(\.time), [try local(2026, 6, 11, 7, 40), try local(2026, 7, 10, 16, 24), try local(2026, 9, 11, 15, 55)])
    }

    func testShutdownEntriesIgnoreTrailingText() throws {
        let entries = ForensicsParse.lastEntries(shutdownOutput, command: "shutdown")
        XCTAssertEqual(entries.map(\.time), [try local(2026, 7, 10, 16, 20), try local(2026, 9, 11, 15, 45)])
    }

    func testOtherCommandAndYearlessLinesAreSkipped() {
        XCTAssertTrue(ForensicsParse.lastEntries(rebootOutput, command: "shutdown").isEmpty)
        XCTAssertTrue(ForensicsParse.lastEntries("reboot time   Fri Sep 11 15:55", command: "reboot").isEmpty)
        XCTAssertTrue(ForensicsParse.lastEntries("", command: "reboot").isEmpty)
    }

    func testClassifyEachExtension() {
        XCTAssertEqual(ForensicsParse.classify(filename: "Safari-2026-11-03-085449.ips")?.kind, .crash)
        XCTAssertEqual(ForensicsParse.classify(filename: "Safari-2026-11-03-085449.ips")?.process, "Safari")
        XCTAssertEqual(ForensicsParse.classify(filename: "Notes_2026-11-03.crash")?.kind, .crash)
        XCTAssertEqual(ForensicsParse.classify(filename: "Finder-2026-11-03-1.hang")?.kind, .hang)
        XCTAssertEqual(ForensicsParse.classify(filename: "Finder-2026-11-03-1.hang")?.process, "Finder")
        XCTAssertEqual(ForensicsParse.classify(filename: "Mail-2026-11-03-1.spin")?.kind, .spin)
        let panic = ForensicsParse.classify(filename: "Kernel-2026-06-26-133219.panic")
        XCTAssertEqual(panic?.kind, .panic)
        XCTAssertEqual(panic?.process, "kernel")
        XCTAssertEqual(ForensicsParse.classify(filename: "panic-full-2026-06-26-133219.0002.ips")?.kind, .panic)
    }

    func testClassifyRejectsNonReports() {
        XCTAssertNil(ForensicsParse.classify(filename: ".contents.panic"))
        XCTAssertNil(ForensicsParse.classify(filename: "Analytics-2026-11-02-190015.0004.core_analytics"))
        XCTAssertNil(ForensicsParse.classify(filename: "JetsamEvent-2026-11-03.diag"))
        XCTAssertNil(ForensicsParse.classify(filename: "Retired"))
        XCTAssertNil(ForensicsParse.classify(filename: "JetsamEvent-2026-11-03-085449.ips"))
    }

    func testHeaderProcessPrefersAppName() {
        XCTAssertEqual(ForensicsParse.headerProcess(firstLine: #"{"app_name":"Google Chrome","timestamp":"x"}"#), "Google Chrome")
        XCTAssertEqual(ForensicsParse.headerProcess(firstLine: #"{"name":"my-tool"}"#), "my-tool")
        XCTAssertNil(ForensicsParse.headerProcess(firstLine: "not json"))
        XCTAssertNil(ForensicsParse.headerProcess(firstLine: #"{"app_name":""}"#))
    }

    func testCursorCountsEachReportOnce() {
        func report(_ seconds: Double) -> CrashReport {
            CrashReport(kind: .crash, process: "x", modified: Date(timeIntervalSince1970: seconds), path: "/x")
        }
        let reports = [report(100), report(200), report(300)]
        let first = ForensicsParse.fresh(reports, after: 150)
        XCTAssertEqual(first.count, 2)
        let cursor = ForensicsParse.advanced(cursor: 150, past: first)
        XCTAssertEqual(cursor, 300)
        XCTAssertTrue(ForensicsParse.fresh(reports, after: cursor).isEmpty)
        XCTAssertEqual(ForensicsParse.advanced(cursor: 500, past: []), 500)
    }
}

final class ForensicsCollectorTests: TempFolderTestCase {
    private func touch(_ folder: URL, _ name: String, age: TimeInterval, contents: String = "{}") throws {
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func testBackfillLimitAndNoDoubleCounting() throws {
        let reports = makeTempFolder()
        try touch(reports, "Safari-a.ips", age: 3600, contents: #"{"app_name":"Safari"}"#)
        try touch(reports, "Old-b.crash", age: 10 * 86400)
        try touch(reports, "Finder-c.hang", age: 60)
        let collector = try ForensicsCollector(settings: settings("forensics"), stateFolder: makeTempFolder(), reportFolders: [reports.path])
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_crash_reports_total", ["kind": "crash"]), 1)
        XCTAssertEqual(value(registry, "molly_crash_reports_total", ["kind": "hang"]), 1)
        XCTAssertEqual(value(registry, "molly_crash_reports_by_process_total", ["kind": "crash", "process": "safari"]), 1)
        XCTAssertNotNil(value(registry, "molly_last_crash_timestamp_seconds"))
    }

    func testProcessSeriesAbsentWhenPolicyDisabled() throws {
        let reports = makeTempFolder()
        try touch(reports, "Safari-a.crash", age: 60)
        let raw: [String: JSONValue] = ["processes": .object(["enabled": .bool(false)])]
        let collector = try ForensicsCollector(settings: settings("forensics", raw), stateFolder: makeTempFolder(), reportFolders: [reports.path])
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_crash_reports_total", ["kind": "crash"]), 1)
        XCTAssertFalse(registry.render().contains("molly_crash_reports_by_process_total{"))
    }

    func testLiveCollectPublishesFamilies() throws {
        let userFolder = ForensicsCollector.userReportsFolder
        guard FileManager.default.isReadableFile(atPath: userFolder) else { throw XCTSkip("DiagnosticReports not readable here") }
        let collector = try ForensicsCollector(settings: settings("forensics"), stateFolder: makeTempFolder())
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        let text = registry.render()
        for family in ["molly_boot_timestamp_seconds", "molly_uptime_seconds", "molly_boots_total",
                       "molly_shutdowns_total", "molly_crash_reports_total"] {
            XCTAssertTrue(text.contains(family), family)
        }
    }
}
