import XCTest
@testable import Molly

final class SettingsRequestTests: XCTestCase {
    func testTabNamesParseCaseInsensitively() {
        XCTAssertEqual(SettingsTab.parse("Privacy"), .privacy)
        XCTAssertEqual(SettingsTab.parse("maintenance"), .maintenance)
        XCTAssertNil(SettingsTab.parse("bogus"))
    }

    func testCommandParsing() throws {
        XCTAssertEqual(try SettingsCommand.parse([]).get(), SettingsRequest())
        XCTAssertEqual(try SettingsCommand.parse(["server"]).get(), SettingsRequest(tab: .server))
        XCTAssertEqual(try SettingsCommand.parse(["--close"]).get(), SettingsRequest(close: true))
        XCTAssertEqual(try SettingsCommand.parse(["agents", "--snapshot", "/tmp/a.png"]).get(),
                       SettingsRequest(tab: .agents, snapshotPath: "/tmp/a.png"))
        XCTAssertThrowsError(try SettingsCommand.parse(["--snapshot"]).get())
        XCTAssertThrowsError(try SettingsCommand.parse(["nope"]).get())
        XCTAssertThrowsError(try SettingsCommand.parse(["server", "agents"]).get())
    }

    func testPayloadRoundTrips() {
        for request in [SettingsRequest(), SettingsRequest(tab: .agents), SettingsRequest(close: true),
                        SettingsRequest(tab: .server, snapshotPath: "/tmp/s.png")] {
            XCTAssertEqual(SettingsRequest(userInfo: request.userInfo), request)
        }
        XCTAssertNil(SettingsRequest(userInfo: ["tab": "zzz"]).tab)
    }
}
