import XCTest
@testable import Molly

private struct FakeProvider: SensorProvider {
    var temps: Result<[SensorReading], Error> = .success([])
    var lux: Double?
    var fanReadings: Result<[SensorReading], Error> = .success([])
    var rails: Result<[SensorReading], Error> = .success([])
    var brightness: Result<Double, Error> = .failure(CollectorUnavailable(reason: "no display"))
    var lid: Result<Double, Error> = .failure(CollectorUnavailable(reason: "no lid"))

    func temperatures() throws -> [SensorReading] { try temps.get() }
    func ambientLight() throws -> Double? { lux }
    func fans() throws -> [SensorReading] { try fanReadings.get() }
    func power() throws -> [SensorReading] { try rails.get() }
    func displayBrightness() throws -> Double { try brightness.get() }
    func lidAngle() throws -> Double { try lid.get() }
}

final class SensorsLogicTests: XCTestCase {
    func testTemperatureFilterDropsOutOfRangeAndNaN() {
        let input = [("a", 40.0), ("b", -127.0), ("c", 150.0), ("d", 150.1), ("e", .nan), ("f", -40.0), ("g", 32767.0)]
            .map { SensorReading(name: $0.0, value: $0.1) }
        XCTAssertEqual(SensorFilter.validTemperatures(input).map(\.name), ["a", "c", "f"])
    }

    func testNamesAreTrimmedCollapsedAndDeduplicated() {
        let input = ["  PMU   tdie1 ", "PMU tdie1", "", "NAND CH0 temp"].map { SensorReading(name: $0, value: 1) }
        XCTAssertEqual(SensorFilter.normaliseNames(input).map(\.name),
                       ["PMU tdie1", "PMU tdie1 #2", "unknown", "NAND CH0 temp"])
    }

    func testMaxValue() {
        XCTAssertNil(SensorFilter.maxValue([]))
        XCTAssertEqual(SensorFilter.maxValue([SensorReading(name: "a", value: 3), SensorReading(name: "b", value: 9)]), 9)
    }

    func testSMCFloatDecodesLittleEndian() throws {
        // 2400.0 as an IEEE float is 0x45160000, stored little-endian by Apple Silicon SMC.
        let value = try XCTUnwrap(SMCDecode.value(type: "flt ", bytes: [0x00, 0x00, 0x16, 0x45]))
        XCTAssertEqual(value, 2400.0)
        XCTAssertNil(SMCDecode.value(type: "flt ", bytes: [0x00, 0x00, 0x80, 0x7F]), "infinity is not a reading")
        XCTAssertNil(SMCDecode.value(type: "flt ", bytes: [0, 0]))
    }

    func testSMCIntegerAndFixedPointTypesAreBigEndian() {
        XCTAssertEqual(SMCDecode.value(type: "ui8 ", bytes: [2]), 2)
        XCTAssertEqual(SMCDecode.value(type: "ui16", bytes: [0x01, 0x02]), 258)
        XCTAssertEqual(SMCDecode.value(type: "ui32", bytes: [0, 0, 1, 0]), 256)
        XCTAssertEqual(SMCDecode.value(type: "sp78", bytes: [0x19, 0x80]), 25.5)
        XCTAssertEqual(SMCDecode.value(type: "fpe2", bytes: [0x0B, 0xB8]), 750)
        XCTAssertNil(SMCDecode.value(type: "zzzz", bytes: [1, 2, 3, 4]))
    }

    func testFourCCRoundTrip() throws {
        let code = try XCTUnwrap(SMCDecode.fourCC("F0Ac"))
        XCTAssertEqual(code, 0x4630_4163)
        XCTAssertEqual(SMCDecode.string(fourCC: code), "F0Ac")
        XCTAssertNil(SMCDecode.fourCC("abc"))
    }

    func testLidAngleDecodesBytesOneAndTwoLittleEndian() {
        XCTAssertEqual(LidAngleDecode.degrees(report: [1, 0x5A, 0x00]), 90)
        XCTAssertEqual(LidAngleDecode.degrees(report: [1, 0x2C, 0x01]), 300)
        XCTAssertEqual(LidAngleDecode.degrees(report: [1, 0, 0]), 0)
        XCTAssertNil(LidAngleDecode.degrees(report: [1, 0xFF, 0xFF]), "out of range")
        XCTAssertNil(LidAngleDecode.degrees(report: [1, 0]), "too short")
    }

    func testSourceListParsing() {
        XCTAssertEqual(SensorsCollector.parseSources(["smc", "HID", "bogus"]), [.hid, .smc])
        XCTAssertEqual(SensorsCollector.parseSources(["lid_angle"]), [.lidAngle])
    }
}

final class SensorsCollectorTests: XCTestCase {
    private func run(_ provider: SensorProvider, json: String = "{}") throws -> (String, Error?) {
        let config = try Config.parse(Data(json.utf8))
        let registry = MetricsRegistry()
        let collector = try SensorsCollector(settings: config.collector("sensors"), provider: provider)
        try collector.start(registry: registry)
        var thrown: Error?
        do { try collector.collect() } catch { thrown = error }
        return (registry.render(), thrown)
    }

    func testPublishesEverySourceFromFakeReadings() throws {
        var fake = FakeProvider()
        fake.temps = .success([SensorReading(name: "PMU tdie1", value: 60), SensorReading(name: "bad", value: -127),
                               SensorReading(name: "NAND", value: 41)])
        fake.lux = 12
        fake.fanReadings = .success([SensorReading(name: "0", value: 2400)])
        fake.rails = .success([SensorReading(name: "system", value: 25), SensorReading(name: "battery", value: 1.5)])
        fake.brightness = .success(0.5)
        fake.lid = .success(110)
        let (text, error) = try run(fake)
        XCTAssertNil(error)
        XCTAssertTrue(text.contains("molly_sensor_temperature_celsius{"), text)
        XCTAssertTrue(text.contains("sensor=\"pmu tdie1\"} 60"), text)
        XCTAssertFalse(text.contains("sensor=\"bad\""), text)
        XCTAssertTrue(text.contains("molly_sensor_temperature_max_celsius 60\n"), text)
        XCTAssertTrue(text.contains("molly_sensor_ambient_light_lux 12\n"), text)
        XCTAssertTrue(text.contains("molly_sensor_fan_rpm{") && text.contains("fan=\"0\"} 2400"), text)
        XCTAssertTrue(text.contains("molly_sensor_system_power_watts 25\n"), text)
        XCTAssertTrue(text.contains("rail=\"battery\"} 1.5"), text)
        XCTAssertTrue(text.contains("molly_display_brightness_ratio 0.5\n"), text)
        XCTAssertTrue(text.contains("molly_lid_angle_degrees 110\n"), text)
        for source in ["hid", "smc", "display", "lid_angle"] {
            XCTAssertTrue(text.contains("molly_sensor_source_available{source=\"\(source)\"} 1"), text)
        }
    }

    func testMissingSourceIsReportedAndOthersStillWork() throws {
        var fake = FakeProvider()
        fake.temps = .success([SensorReading(name: "A", value: 50)])
        fake.fanReadings = .failure(CollectorUnavailable(reason: "AppleSMC refused"))
        let (text, error) = try run(fake)
        XCTAssertNil(error)
        XCTAssertTrue(text.contains("source=\"smc\"} 0"), text)
        XCTAssertTrue(text.contains("source=\"hid\"} 1"), text)
        XCTAssertFalse(text.contains("molly_sensor_fan_rpm{"), text)
    }

    func testAllSourcesUnavailableThrowsCollectorUnavailable() throws {
        var fake = FakeProvider()
        fake.temps = .failure(CollectorUnavailable(reason: "missing symbol IOHIDEventSystemClientCreate"))
        fake.fanReadings = .failure(CollectorUnavailable(reason: "smc"))
        let (_, error) = try run(fake)
        let unavailable = try XCTUnwrap(error as? CollectorUnavailable)
        XCTAssertTrue(unavailable.reason.contains("IOHIDEventSystemClientCreate"), unavailable.reason)
    }

    func testUnexpectedErrorsAreNotUnavailable() throws {
        var fake = FakeProvider()
        fake.temps = .failure(SensorsFailure(description: "boom"))
        let (_, error) = try run(fake, json: #"{"collectors": {"sensors": {"sources": ["hid"]}}}"#)
        XCTAssertTrue(error is SensorsFailure)
    }

    func testSensorPolicyCapsCardinalityKeepingHottestAndDisabledPolicyHidesNames() throws {
        var fake = FakeProvider()
        fake.temps = .success((1...50).map { SensorReading(name: "s\($0)", value: Double($0)) })
        let (capped, _) = try run(fake, json: #"{"collectors": {"sensors": {"sources": ["hid"], "sensors": {"maxCardinality": 3}}}}"#)
        XCTAssertTrue(capped.contains("sensor=\"s50\""), capped)
        XCTAssertFalse(capped.contains("sensor=\"s47\""), capped)
        XCTAssertTrue(capped.contains("molly_sensor_temperature_max_celsius 50\n"), capped)

        let (hidden, _) = try run(fake, json: #"{"collectors": {"sensors": {"sources": ["hid"], "sensors": {"enabled": false}}}}"#)
        XCTAssertFalse(hidden.contains("molly_sensor_temperature_celsius{"), hidden)
        XCTAssertTrue(hidden.contains("molly_sensor_temperature_max_celsius "), "the aggregate survives a disabled policy")
    }

    func testLiveCollectOnThisMachine() throws {
        let registry = MetricsRegistry()
        let collector = try SensorsCollector(settings: Config().collector("sensors"))
        try collector.start(registry: registry)
        do {
            try collector.collect()
        } catch is CollectorUnavailable {
            throw XCTSkip("no sensor source available on this machine")
        }
        let text = registry.render()
        XCTAssertTrue(text.contains("molly_sensor_source_available{"), text)
    }
}
