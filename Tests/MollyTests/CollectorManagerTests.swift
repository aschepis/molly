import XCTest
@testable import Molly

private final class FakeCollector: Collector {
    let name: String
    let interval: TimeInterval
    var started = 0
    var stopped = 0
    var collected = 0
    var failWith: Error?
    var startError: Error?

    init(name: String, interval: TimeInterval = 0) {
        self.name = name
        self.interval = interval
    }

    func start(registry: MetricsRegistry) throws {
        if let startError { throw startError }
        started += 1
        registry.gauge("fake_\(name)", help: "").set(1)
    }

    func collect() throws {
        collected += 1
        if let failWith { throw failWith }
    }

    func stop() { stopped += 1 }
}

private struct Boom: Error {}

final class CollectorManagerTests: XCTestCase {
    func testCollectAllRunsEveryCollectorAndRecordsFailures() {
        let registry = MetricsRegistry()
        let good = FakeCollector(name: "good")
        let bad = FakeCollector(name: "bad")
        bad.failWith = Boom()
        let manager = CollectorManager(registry: registry, collectors: [good, bad])
        manager.startAll()
        let failures = manager.collectAll()
        XCTAssertEqual(good.collected, 1)
        XCTAssertEqual(bad.collected, 1)
        XCTAssertEqual(Array(failures.keys), ["bad"])

        XCTAssertEqual(registry.counter("molly_collector_runs_total", help: "", labels: ["collector"]).value(labels: ["collector": "good"]), 1)
        XCTAssertEqual(registry.counter("molly_collector_errors_total", help: "", labels: ["collector"]).value(labels: ["collector": "bad"]), 1)
        XCTAssertEqual(registry.counter("molly_collector_errors_total", help: "", labels: ["collector"]).value(labels: ["collector": "good"]), 0)
        XCTAssertNotNil(registry.gauge("molly_collector_last_success_timestamp_seconds", help: "", labels: ["collector"]).value(labels: ["collector": "good"]))

        let statuses = manager.allStatuses
        XCTAssertEqual(statuses.map { $0.name }, ["bad", "good"])
        XCTAssertEqual(statuses[0].errors, 1)
        XCTAssertNotNil(statuses[0].lastError)
        XCTAssertNotNil(statuses[1].lastSuccess)

        manager.stopAll()
        XCTAssertEqual(good.stopped, 1)
        XCTAssertEqual(bad.stopped, 1)
    }

    func testStartFailureDisablesCollectorButKeepsOthers() {
        let registry = MetricsRegistry()
        let broken = FakeCollector(name: "broken")
        broken.startError = Boom()
        let fine = FakeCollector(name: "fine")
        let manager = CollectorManager(registry: registry, collectors: [broken, fine])
        manager.startAll()
        let enabled = registry.gauge("molly_collector_enabled", help: "", labels: ["collector"])
        XCTAssertEqual(enabled.value(labels: ["collector": "broken"]), 0)
        XCTAssertEqual(enabled.value(labels: ["collector": "fine"]), 1)
        manager.stopAll()
    }

    func testScheduledCollectorRunsOnInterval() {
        let registry = MetricsRegistry()
        let ticking = FakeCollector(name: "tick", interval: 0.2)
        let manager = CollectorManager(registry: registry, collectors: [ticking])
        manager.startAll()
        let deadline = Date().addingTimeInterval(3)
        while ticking.collected < 2 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThanOrEqual(ticking.collected, 2)
        manager.pause()
        XCTAssertEqual(registry.gauge("molly_paused", help: "").value(), 1)
        manager.resume()
        XCTAssertEqual(registry.gauge("molly_paused", help: "").value(), 0)
        manager.stopAll()
    }

    func testUnavailableErrorsAreNotRepeatedlyLogged() {
        // Behavioural contract: an unavailable source is marked as such in status.
        let registry = MetricsRegistry()
        let c = FakeCollector(name: "u")
        c.failWith = CollectorUnavailable(reason: "no permission")
        let manager = CollectorManager(registry: registry, collectors: [c])
        manager.startAll()
        _ = manager.collectAll()
        _ = manager.collectAll()
        XCTAssertTrue(manager.allStatuses[0].unavailable)
        XCTAssertEqual(manager.allStatuses[0].errors, 0)
        XCTAssertNotNil(manager.allStatuses[0].lastError)
        manager.stopAll()
    }

    func testUnavailableIsAGaugeNotAnError() {
        let registry = MetricsRegistry()
        let absent = FakeCollector(name: "absent")
        absent.failWith = CollectorUnavailable(reason: "no such folder")
        let fine = FakeCollector(name: "fine")
        let manager = CollectorManager(registry: registry, collectors: [absent, fine])
        manager.startAll()
        let unavailable = registry.gauge("molly_collector_unavailable", help: "", labels: ["collector"])
        let errors = registry.counter("molly_collector_errors_total", help: "", labels: ["collector"])
        XCTAssertEqual(unavailable.value(labels: ["collector": "fine"]), 0)
        XCTAssertEqual(unavailable.value(labels: ["collector": "absent"]), 0)
        _ = manager.collectAll()
        _ = manager.collectAll()
        XCTAssertEqual(unavailable.value(labels: ["collector": "absent"]), 1)
        XCTAssertEqual(unavailable.value(labels: ["collector": "fine"]), 0)
        XCTAssertEqual(errors.value(labels: ["collector": "absent"]), 0)

        absent.failWith = nil
        _ = manager.collectAll()
        XCTAssertEqual(unavailable.value(labels: ["collector": "absent"]), 0)
        manager.stopAll()
    }
}
