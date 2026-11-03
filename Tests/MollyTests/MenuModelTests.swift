import XCTest
@testable import Molly

final class MenuModelTests: XCTestCase {
    func testHasInsightsOnlyWithADailyReport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("molly-menu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(MenuModel.hasInsights(folder: folder))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "notes".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertFalse(MenuModel.hasInsights(folder: folder))
        try "# day".write(to: folder.appendingPathComponent("2026-11-03.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(MenuModel.hasInsights(folder: folder))
    }

    func testStatusLinesDescribeEachState() {
        let now = Date()
        var ok = CollectorManager.Status(name: "focus", interval: 5)
        ok.lastSuccess = now.addingTimeInterval(-3)
        var flaky = CollectorManager.Status(name: "git", interval: 120)
        flaky.lastSuccess = now.addingTimeInterval(-10)
        flaky.errors = 2
        var down = CollectorManager.Status(name: "codex", interval: 120)
        down.unavailable = true
        var broken = CollectorManager.Status(name: "mail", interval: 120)
        broken.errors = 4
        let fresh = CollectorManager.Status(name: "power", interval: 300)
        XCTAssertEqual(MenuModel.statusLines([ok, flaky, down, broken, fresh], now: now), [
            "focus · ok 3s ago",
            "git · ok 10s ago · 2 errors",
            "codex · unavailable",
            "mail · 4 errors",
            "power · waiting",
        ])
    }

    func testDoctorSummary() {
        let pass = DoctorCommand.Check(name: "config", ok: true, detail: "")
        let fail1 = DoctorCommand.Check(name: "prometheus", ok: false, detail: "")
        let fail2 = DoctorCommand.Check(name: "grafana", ok: false, detail: "")
        XCTAssertEqual(MenuModel.doctorSummary([pass, pass]), "All 2 checks passed")
        XCTAssertEqual(MenuModel.doctorSummary([pass, fail1, fail2]), "1 ok, 2 failing: prometheus, grafana")
    }

    func testIsBundled() {
        XCTAssertTrue(MenuModel.isBundled(bundleURL: URL(fileURLWithPath: "/Applications/Molly.app")))
        XCTAssertFalse(MenuModel.isBundled(bundleURL: URL(fileURLWithPath: "/repo/.build/debug")))
    }
}
