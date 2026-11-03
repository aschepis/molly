import XCTest
@testable import Molly

final class LaunchAgentTests: XCTestCase {
    func testPlistContents() throws {
        let logs = URL(fileURLWithPath: "/Users/me/Library/Application Support/Molly")
        let data = try LaunchAgent.plist(executable: "/opt/molly", logDirectory: logs)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertEqual(plist["Label"] as? String, "com.aschepis.molly")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/opt/molly", "run"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["StandardOutPath"] as? String, "/Users/me/Library/Application Support/Molly/molly.out.log")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/Users/me/Library/Application Support/Molly/molly.err.log")
    }

    func testPrefersInstalledApp() {
        XCTAssertEqual(LaunchAgent.chooseExecutable(current: "/tmp/molly", fileExists: { _ in true }),
                       "/Applications/Molly.app/Contents/MacOS/molly")
        XCTAssertEqual(LaunchAgent.chooseExecutable(current: "/tmp/molly", fileExists: { _ in false }), "/tmp/molly")
    }

    func testTargetSummary() {
        let up = #"{"data":{"activeTargets":[{"labels":{"job":"prometheus"},"health":"up","lastError":""},{"labels":{"job":"molly"},"health":"up","lastError":""}]}}"#
        XCTAssertEqual(StatusCommand.targetSummary(from: Data(up.utf8)), "molly target up")

        let down = #"{"data":{"activeTargets":[{"labels":{"job":"molly"},"health":"down","lastError":"refused"}]}}"#
        XCTAssertEqual(StatusCommand.targetSummary(from: Data(down.utf8)), "molly target down: refused")

        XCTAssertNil(StatusCommand.targetSummary(from: Data(#"{"data":{"activeTargets":[]}}"#.utf8)))
    }
}
