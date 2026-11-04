import XCTest
@testable import MollyHealthCore

final class DayTotalsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: -5 * 3600) ?? .gmt
        return c
    }()

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso) ?? Date(timeIntervalSince1970: 0) }

    /// Local day 2026-11-03 at UTC-5.
    private var window: DayWindow { DayKey.window(for: date("2026-11-03T15:00:00Z"), calendar: calendar) }

    private func sample(_ start: String, _ end: String, _ value: Double = 0) -> SamplePoint {
        SamplePoint(start: date(start), end: date(end), value: value)
    }

    func testStatisticTypesPassThroughAndMissingReadingsAreOmitted() {
        let totals = DayTotalsBuilder.build(window: window, readings: [
            .steps: .statistic(8120), .restingHeartRateBpm: .statistic(57), .headphoneAudioDb: .statistic(82.5),
        ])
        XCTAssertEqual(totals[.steps], .number(8120))
        XCTAssertEqual(totals[.restingHeartRateBpm], .number(57))
        XCTAssertEqual(totals[.headphoneAudioDb], .number(82.5))
        XCTAssertNil(totals[.hrvMs])
    }

    func testEmptyCumulativeTypesSendZeroAndEmptyPointTypesAreOmitted() {
        let totals = DayTotalsBuilder.build(window: window, readings: [
            .steps: .statistic(nil), .activeEnergyKcal: .statistic(nil), .exerciseMinutes: .statistic(nil),
            .walkingDistanceM: .statistic(nil), .flightsClimbed: .statistic(nil), .daylightMinutes: .statistic(nil),
            .standHours: .samples([]), .mindfulMinutes: .samples([]),
            .heartRateBpm: .statistic(nil), .bodyMassKg: .statistic(nil), .sleepMinutes: .samples([]),
            .bedtime: .samples([]),
        ])
        for type in [MollyHealthType.steps, .activeEnergyKcal, .exerciseMinutes, .walkingDistanceM,
                     .flightsClimbed, .daylightMinutes, .standHours, .mindfulMinutes] {
            XCTAssertEqual(totals[type], .number(0), type.rawValue)
        }
        for type in [MollyHealthType.heartRateBpm, .bodyMassKg, .sleepMinutes, .bedtime] {
            XCTAssertNil(totals[type], type.rawValue)
        }
    }

    func testSumAverageAndMaximumFromSamples() {
        let points = [
            SamplePoint(start: date("2026-11-03T14:00:00Z"), end: date("2026-11-03T14:30:00Z"), value: 100),
            SamplePoint(start: date("2026-11-03T16:00:00Z"), end: date("2026-11-03T16:30:00Z"), value: 300),
            // Started yesterday local time, so it belongs to another day.
            SamplePoint(start: date("2026-11-03T04:00:00Z"), end: date("2026-11-03T04:30:00Z"), value: 999),
        ]
        let totals = DayTotalsBuilder.build(window: window, readings: [
            .steps: .samples(points), .heartRateBpm: .samples(points), .headphoneAudioDb: .samples(points),
        ])
        XCTAssertEqual(totals[.steps], .number(400))
        XCTAssertEqual(totals[.heartRateBpm], .number(200))
        XCTAssertEqual(totals[.headphoneAudioDb], .number(300))
    }

    func testWristTemperatureIsTheChangeFromBaseline() {
        let totals = DayTotalsBuilder.build(window: window, readings: [
            .wristTemperatureDeltaC: .deltaStatistic(today: 35.9, baseline: 36.1),
        ])
        guard case .number(let delta)? = totals[.wristTemperatureDeltaC] else { return XCTFail("missing") }
        XCTAssertEqual(delta, -0.2, accuracy: 0.0001)
        let noBaseline = DayTotalsBuilder.build(window: window, readings: [
            .wristTemperatureDeltaC: .deltaStatistic(today: 35.9, baseline: nil),
        ])
        XCTAssertNil(noBaseline[.wristTemperatureDeltaC])
    }

    func testStandHoursCountOnlyStoodSamplesThatStartedToday() {
        let totals = DayTotalsBuilder.build(window: window, readings: [
            .standHours: .samples([
                sample("2026-11-03T14:00:00Z", "2026-11-03T15:00:00Z", 0),
                sample("2026-11-03T15:00:00Z", "2026-11-03T16:00:00Z", 1),
                sample("2026-11-03T16:00:00Z", "2026-11-03T17:00:00Z", 0),
                sample("2026-11-02T14:00:00Z", "2026-11-02T15:00:00Z", 0),
            ]),
        ])
        XCTAssertEqual(totals[.standHours], .number(2))
    }

    func testMindfulMinutesSumDurations() {
        let totals = DayTotalsBuilder.build(window: window, readings: [
            .mindfulMinutes: .samples([
                sample("2026-11-03T14:00:00Z", "2026-11-03T14:10:00Z"),
                sample("2026-11-03T20:00:00Z", "2026-11-03T20:05:00Z"),
            ]),
        ])
        XCTAssertEqual(totals[.mindfulMinutes], .number(15))
    }

    func testSleepSpanningMidnightBelongsToTheWakeUpDay() {
        // 23:00 local on the 2nd to 07:00 local on the 3rd, split into stages, with a watch/phone overlap.
        let stages = [
            sample("2026-11-03T04:00:00Z", "2026-11-03T12:30:00Z", 0),  // in bed 23:00-07:30
            sample("2026-11-03T04:30:00Z", "2026-11-03T08:00:00Z", 3),  // core 23:30-03:00
            sample("2026-11-03T08:00:00Z", "2026-11-03T09:00:00Z", 4),  // deep 03:00-04:00
            sample("2026-11-03T09:00:00Z", "2026-11-03T12:00:00Z", 5),  // REM 04:00-07:00
            sample("2026-11-03T08:30:00Z", "2026-11-03T09:30:00Z", 1),  // phone, overlaps 30 min
            sample("2026-11-03T10:00:00Z", "2026-11-03T10:20:00Z", 2),  // awake, ignored
            sample("2026-11-02T04:30:00Z", "2026-11-02T12:00:00Z", 3),  // previous night, ended yesterday
        ]
        let totals = DayTotalsBuilder.build(window: window, readings: [
            .sleepMinutes: .samples(stages), .sleepInBedMinutes: .samples(stages),
            .bedtime: .samples(stages), .wakeTime: .samples(stages),
        ])
        // Asleep union is 04:30Z-12:00Z (450 min) because the phone sample overlaps the watch stages.
        XCTAssertEqual(totals[.sleepMinutes], .number(450))
        XCTAssertEqual(totals[.sleepInBedMinutes], .number(510))
        XCTAssertEqual(totals[.bedtime], .timestamp(date("2026-11-03T04:30:00Z")))
        XCTAssertEqual(totals[.wakeTime], .timestamp(date("2026-11-03T12:00:00Z")))
    }

    func testSleepEndingTomorrowIsNotCountedToday() {
        let late = [sample("2026-11-04T04:30:00Z", "2026-11-04T12:00:00Z", 3)]
        let totals = DayTotalsBuilder.build(window: window, readings: [.sleepMinutes: .samples(late)])
        XCTAssertNil(totals[.sleepMinutes])
    }
}
