import XCTest
@testable import Molly

final class MetricsTests: XCTestCase {
    func testRendersGaugesAndCountersWithConstLabels() {
        let r = MetricsRegistry(constLabels: ["user": "adam", "host": "mbp"])
        let g = r.gauge("molly_focus_app", help: "Frontmost app.", labels: ["app"])
        g.set(1, labels: ["app": "Safari \"beta\""])
        let c = r.counter("molly_events_total", help: "Events.\nSecond line")
        c.inc()
        c.add(2.5)
        let text = r.render()
        XCTAssertEqual(text, """
        # HELP molly_events_total Events.\\nSecond line
        # TYPE molly_events_total counter
        molly_events_total{host="mbp",user="adam"} 3.5
        # HELP molly_focus_app Frontmost app.
        # TYPE molly_focus_app gauge
        molly_focus_app{host="mbp",user="adam",app="Safari \\"beta\\""} 1

        """)
    }

    func testEmptyFamiliesAreNotRendered() {
        let r = MetricsRegistry()
        _ = r.gauge("empty", help: "nothing")
        XCTAssertEqual(r.render(), "")
    }

    func testReRegisteringReturnsSameFamily() {
        let r = MetricsRegistry()
        r.gauge("x", help: "a").set(1)
        r.gauge("x", help: "a").add(1)
        XCTAssertEqual(r.gauge("x", help: "a").value(), 2)
    }

    func testGaugeResetAndReplaceAll() {
        let r = MetricsRegistry()
        let g = r.gauge("apps", help: "", labels: ["app"])
        g.set(5, labels: ["app": "old"])
        g.replaceAll(["a": 1, "b": 2], label: "app")
        XCTAssertNil(g.value(labels: ["app": "old"]))
        XCTAssertEqual(g.value(labels: ["app": "b"]), 2)
        g.remove(labels: ["app": "a"])
        XCTAssertNil(g.value(labels: ["app": "a"]))
    }

    func testNumberFormatting() {
        XCTAssertEqual(Metrics.format(3), "3")
        XCTAssertEqual(Metrics.format(3.25), "3.25")
        XCTAssertEqual(Metrics.format(1e20), "1e+20")
        XCTAssertEqual(Metrics.format(.nan), "NaN")
        XCTAssertEqual(Metrics.format(.infinity), "+Inf")
    }

    func testNameValidation() {
        XCTAssertTrue(Metrics.isValidMetricName("molly_cpu:rate5m"))
        XCTAssertFalse(Metrics.isValidMetricName("1bad"))
        XCTAssertTrue(Metrics.isValidLabelName("app_name"))
        XCTAssertFalse(Metrics.isValidLabelName("__reserved"))
        XCTAssertFalse(Metrics.isValidLabelName("has-dash"))
    }

    func testConcurrentUpdatesDoNotLoseCounts() {
        let r = MetricsRegistry()
        let c = r.counter("hits", help: "", labels: ["k"])
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            c.inc(labels: ["k": String(i % 4)])
        }
        let total = (0..<4).map { c.value(labels: ["k": String($0)]) ?? 0 }.reduce(0, +)
        XCTAssertEqual(total, 1000)
    }

    func testSelfCollectorPublishesLocalUTCOffset() throws {
        let registry = MetricsRegistry(constLabels: [:])
        let collector = ProcessSelfCollector(settings: CollectorSettings(name: "process", raw: [:]))
        try collector.start(registry: registry)
        try collector.collect()
        let expected = "molly_local_utc_offset_seconds \(TimeZone.current.secondsFromGMT())"
        XCTAssertTrue(registry.render().contains(expected), registry.render())
    }
}

final class HistogramTests: XCTestCase {
    func testRendersCumulativeBucketsSumAndCountWithConstLabels() {
        let r = MetricsRegistry(constLabels: ["host": "mbp"])
        let h = r.histogram("molly_op_seconds", help: "Op time.", labels: ["op"], buckets: [1, 5])
        h.observe(0.5, labels: ["op": "a"])
        h.observe(1, labels: ["op": "a"])
        h.observe(3, labels: ["op": "a"])
        h.observe(9, labels: ["op": "a"])
        XCTAssertEqual(r.render(), """
        # HELP molly_op_seconds Op time.
        # TYPE molly_op_seconds histogram
        molly_op_seconds_bucket{host="mbp",op="a",le="1"} 2
        molly_op_seconds_bucket{host="mbp",op="a",le="5"} 3
        molly_op_seconds_bucket{host="mbp",op="a",le="+Inf"} 4
        molly_op_seconds_sum{host="mbp",op="a"} 13.5
        molly_op_seconds_count{host="mbp",op="a"} 4

        """)
    }

    func testUnlabeledHistogramAndEmptyIsHidden() {
        let r = MetricsRegistry()
        let h = r.histogram("molly_x_seconds", help: "x", buckets: [2])
        XCTAssertEqual(r.render(), "")
        h.observe(2)
        XCTAssertTrue(r.render().contains("molly_x_seconds_bucket{le=\"2\"} 1\n"))
        XCTAssertTrue(r.render().contains("molly_x_seconds_count 1\n"))
        XCTAssertEqual(r.stats().first?.type, .histogram)
    }
}
