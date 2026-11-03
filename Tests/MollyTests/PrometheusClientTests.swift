import XCTest
@testable import Molly

final class PrometheusClientTests: XCTestCase {
    func testRejectsBadURL() {
        XCTAssertThrowsError(try PrometheusClient(baseURL: "not a url at all"))
    }

    func testQueriesLiveStackWhenAvailable() throws {
        let client = try PrometheusClient(baseURL: "http://localhost:9090")
        try XCTSkipUnless(client.isReady(), "local Prometheus not running")
        let samples = try client.query("up")
        XCTAssertFalse(samples.isEmpty)
        XCTAssertNotNil(samples.first?.labels["job"])
        let series = try client.queryRange("up", from: Date().addingTimeInterval(-300), to: Date(), step: 60)
        XCTAssertFalse(series.isEmpty)
        XCTAssertThrowsError(try client.query("up{"))
        XCTAssertNil(try client.scalar("absent_metric_xyz"))
    }
}
