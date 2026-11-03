import XCTest
@testable import Molly

final class GroupARegistrationTests: XCTestCase {
    /// The registry traps on a name registered with different labels, which would
    /// kill the daemon at startup; this catches collisions between collectors.
    func testAllDefaultCollectorsRegisterTogether() throws {
        let registry = MetricsRegistry()
        let collectors = try CollectorRegistry.makeCollectors(config: Config())
        for name in ["system", "processes", "focus", "docker", "meeting"] {
            XCTAssertTrue(collectors.contains { $0.name == name }, "\(name) not wired")
        }
        for collector in collectors { try collector.start(registry: registry) }
        for collector in collectors { collector.stop() }
    }
}
