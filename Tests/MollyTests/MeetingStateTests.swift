import XCTest
@testable import Molly

final class MeetingStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testAccumulatesSecondsAndTransitions() {
        var state = MeetingState()
        XCTAssertEqual(state.advance(to: t0, microphone: false, camera: false), MeetingDeltas())

        let micOn = state.advance(to: t0.addingTimeInterval(5), microphone: true, camera: false)
        XCTAssertEqual(micOn.microphoneActivations, 1)
        XCTAssertEqual(micOn.meetingStarts, 1)
        XCTAssertEqual(micOn.meetingSeconds, 0) // credited from the next interval

        let cameraOn = state.advance(to: t0.addingTimeInterval(10), microphone: true, camera: true)
        XCTAssertEqual(cameraOn.microphoneSeconds, 5)
        XCTAssertEqual(cameraOn.cameraSeconds, 0)
        XCTAssertEqual(cameraOn.cameraActivations, 1)
        XCTAssertEqual(cameraOn.meetingStarts, 0)

        let micOff = state.advance(to: t0.addingTimeInterval(15), microphone: false, camera: true)
        XCTAssertEqual(micOff.microphoneSeconds, 5)
        XCTAssertEqual(micOff.cameraSeconds, 5)
        XCTAssertEqual(micOff.meetingSeconds, 5)
        XCTAssertTrue(state.meetingActive)

        let allOff = state.advance(to: t0.addingTimeInterval(20), microphone: false, camera: false)
        XCTAssertEqual(allOff.meetingSeconds, 5)
        XCTAssertFalse(state.meetingActive)
    }

    func testLongGapIsNotCredited() {
        var state = MeetingState(maxGap: 30)
        _ = state.advance(to: t0, microphone: true, camera: false)
        let d = state.advance(to: t0.addingTimeInterval(600), microphone: true, camera: false)
        XCTAssertEqual(d.microphoneSeconds, 0)
    }

    func testCollectPublishesFamilies() throws {
        let registry = MetricsRegistry()
        let collector = MeetingCollector(settings: CollectorSettings(name: "meeting", raw: [:]))
        try collector.start(registry: registry)
        do { try collector.collect() } catch is CollectorUnavailable { throw XCTSkip("no audio or camera devices") }
        XCTAssertNotNil(registry.gauge("molly_meeting_active", help: "").value())
    }
}
