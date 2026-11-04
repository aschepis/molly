import XCTest
@testable import MollyHealthCore

final class CatalogAndPayloadTests: XCTestCase {
    /// Copied from the Mac's HealthType; scripts/check-health-types.sh compares the real files.
    private let macTypes = """
    steps stand_hours active_energy_kcal exercise_minutes resting_heart_rate_bpm heart_rate_bpm hrv_ms
    sleep_minutes sleep_in_bed_minutes bedtime wake_time walking_distance_m flights_climbed daylight_minutes
    headphone_audio_db vo2max body_mass_kg respiratory_rate blood_oxygen_ratio wrist_temperature_delta_c mindful_minutes
    """

    func testCatalogNamesMatchTheMac() {
        let expected = macTypes.split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(MollyHealthType.allCases.map(\.rawValue), expected)
    }

    func testEveryTypeHasAHealthKitIdentifier() {
        for type in MollyHealthType.allCases {
            let spec = type.spec
            let prefix = spec.isCategory ? "HKCategoryTypeIdentifier" : "HKQuantityTypeIdentifier"
            XCTAssertTrue(spec.healthKitIdentifier.hasPrefix(prefix), type.rawValue)
            XCTAssertEqual(spec.unit.isEmpty, spec.isCategory, type.rawValue)
        }
    }

    func testPayloadMatchesTheShapeTheMacAccepts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600) ?? .gmt
        let bedtime = ISO8601DateFormatter().date(from: "2026-11-03T04:30:00Z") ?? Date()
        let payload = HealthPayload.make(
            device: "iphone", date: "2026-11-03",
            totals: [.steps: .number(8120), .bedtime: .timestamp(bedtime), .vo2max: .number(.nan)],
            calendar: calendar)
        let data = try payload.encoded()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["device"] as? String, "iphone")
        XCTAssertEqual(object["date"] as? String, "2026-11-03")
        let totals = try XCTUnwrap(object["totals"] as? [String: Any])
        XCTAssertEqual(totals["steps"] as? Double, 8120)
        XCTAssertEqual(totals["bedtime"] as? String, "2026-11-02T23:30:00-05:00")
        XCTAssertNil(totals["vo2max"])
        XCTAssertEqual(Set(object.keys), ["device", "date", "totals"])
    }

    func testOversizedBodyIsRefusedBeforeSending() {
        let big = Dictionary(uniqueKeysWithValues: (0..<5000).map { ("k\($0)_" + String(repeating: "x", count: 20), HealthPayload.Value.number(1)) })
        XCTAssertThrowsError(try HealthPayload(device: "iphone", date: "2026-11-03", totals: big).encoded())
    }

    func testDayKeyUsesTheCalendarsZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600) ?? .gmt
        let instant = ISO8601DateFormatter().date(from: "2026-11-03T03:00:00Z") ?? Date()
        XCTAssertEqual(DayKey.string(for: instant, calendar: calendar), "2026-11-02")
    }

    func testSettingsDefaultsAndURLs() {
        var settings = AppSettings()
        XCTAssertEqual(settings.enabledTypes.count, MollyHealthType.allCases.count)
        XCTAssertEqual(settings.endpoint("/healthz")?.absoluteString,
                       "http://adams-macbook-pro.tail853834.ts.net:9765/healthz")
        settings.serverURL = " http://mac.local:9765/ "
        XCTAssertEqual(settings.endpoint("/health")?.absoluteString, "http://mac.local:9765/health")
        settings.serverURL = "not a url"
        XCTAssertNil(settings.baseURL)
        settings.deviceName = "Adam's iPhone!"
        XCTAssertEqual(settings.sanitizedDeviceName, "adamsiphone")
    }

    func testLogRingKeepsTheLast200Lines() {
        let log = LogRing()
        for i in 0..<250 { log.append("line \(i)") }
        XCTAssertEqual(log.lines.count, 200)
        XCTAssertTrue(log.lines.first?.hasSuffix("line 50") ?? false)
    }
}
