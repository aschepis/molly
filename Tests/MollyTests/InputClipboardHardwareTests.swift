import AppKit
import XCTest
@testable import Molly

final class InputAggregatorTests: XCTestCase {
    func testDrainReturnsCountsSinceLastDrainAndResets() {
        var agg = InputAggregator()
        let t = Date()
        agg.record(.key, at: t)
        agg.record(.key, at: t)
        agg.record(.click, at: t)
        XCTAssertEqual(agg.drain(), [.key: 2, .click: 1])
        XCTAssertEqual(agg.drain(), [:])
    }

    func testWindowDropsOldEvents() {
        var agg = InputAggregator(window: 60)
        let t = Date()
        agg.record(.key, at: t.addingTimeInterval(-120))
        agg.record(.key, at: t.addingTimeInterval(-30))
        agg.record(.key, at: t)
        XCTAssertEqual(agg.countInWindow(.key, now: t), 2)
        XCTAssertEqual(agg.countInWindow(.scroll, now: t), 0)
        XCTAssertEqual(agg.countInWindow(.key, now: t.addingTimeInterval(61)), 0)
    }

    func testEventKindMapping() {
        XCTAssertEqual(InputAggregator.kind(of: .keyDown), .key)
        XCTAssertEqual(InputAggregator.kind(of: .flagsChanged), .key)
        XCTAssertEqual(InputAggregator.kind(of: .leftMouseDown), .click)
        XCTAssertEqual(InputAggregator.kind(of: .rightMouseDown), .click)
        XCTAssertEqual(InputAggregator.kind(of: .scrollWheel), .scroll)
        XCTAssertNil(InputAggregator.kind(of: .mouseMoved))
        XCTAssertNil(InputAggregator.kind(of: .keyUp))
    }

    /// The aggregator must not be able to hold anything keystroke-shaped.
    func testAggregatorHoldsOnlyCounts() {
        let mirror = Mirror(reflecting: InputAggregator())
        let labels = mirror.children.compactMap { $0.label }
        XCTAssertEqual(Set(labels), ["window", "totals", "recent"])
    }

    func testCollectorWithoutTapReportsUnavailable() throws {
        // On CI or without Accessibility, start() cannot create a tap; collect must degrade.
        let registry = MetricsRegistry()
        let collector = InputCollector(settings: Config().collector("input"))
        try collector.start(registry: registry)
        defer { collector.stop() }
        do {
            try collector.collect()
            XCTAssertEqual(registry.gauge("molly_input_available", help: "").value(), 1)
        } catch is CollectorUnavailable {
            XCTAssertEqual(registry.gauge("molly_input_available", help: "").value(), 0)
        }
        XCTAssertTrue(registry.familyNames.contains("molly_input_events_total"))
    }
}

final class ClipboardClassificationTests: XCTestCase {
    func testClassifyPrefersMostSpecificType() {
        XCTAssertEqual(ClipboardContentType.classify([.string, .fileURL]), .file)
        XCTAssertEqual(ClipboardContentType.classify([.string, .URL]), .url)
        XCTAssertEqual(ClipboardContentType.classify([.tiff, .string]), .image)
        XCTAssertEqual(ClipboardContentType.classify([.png]), .image)
        XCTAssertEqual(ClipboardContentType.classify([.rtf, .string]), .text)
        XCTAssertEqual(ClipboardContentType.classify([.string]), .text)
        XCTAssertEqual(ClipboardContentType.classify([NSPasteboard.PasteboardType("com.example.custom")]), .other)
        XCTAssertEqual(ClipboardContentType.classify([]), .other)
    }

    func testCollectorCountsOnlyChanges() throws {
        let registry = MetricsRegistry()
        let collector = ClipboardCollector(settings: Config().collector("clipboard"))
        try collector.start(registry: registry)
        try collector.collect()
        let changes = registry.counter("molly_clipboard_changes_total", help: "", labels: ["type"])
        let before = ClipboardContentType.allCases.map { changes.value(labels: ["type": $0.rawValue]) ?? 0 }.reduce(0, +)
        XCTAssertEqual(before, 0, "no change between start and first collect")
        // Writing to the general pasteboard would clobber the user's clipboard; skip the live change test.
    }
}

final class HardwareLogicTests: XCTestCase {
    private let batteryFixture: [String: Any] = [
        "Temperature": 3062, "Voltage": 13128,
        "InstantAmperage": UInt64(bitPattern: -1500), "Amperage": 0,
        "AppleRawCurrentCapacity": 4000, "AppleRawMaxCapacity": 5000, "DesignCapacity": 5200,
        "FullyCharged": false,
        "AppleRawAdapterDetails": ["Watts": 140, "Name": "140W USB-C\u{0}Power Adapter\n",
                                   "Description": "pd charger", "AdapterVoltage": 28000] as [String: Any],
    ]

    func testBatteryDetailParsesUnitsAndNegativeAmperage() throws {
        let d = try XCTUnwrap(BatteryDetailParser.parse(batteryFixture))
        XCTAssertEqual(try XCTUnwrap(d.temperatureCelsius), 30.62, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(d.voltageVolts), 13.128, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(d.currentAmperes), -1.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(d.powerWatts), -19.692, accuracy: 0.001)
        XCTAssertEqual(d.currentMAh, 4000)
        XCTAssertEqual(d.maxMAh, 5000)
        XCTAssertEqual(d.designMAh, 5200)
        XCTAssertEqual(d.fullyCharged, false)
        XCTAssertEqual(d.adapter?.name, "140W USB-CPower Adapter")
        XCTAssertEqual(try XCTUnwrap(d.adapter?.voltageVolts), 28, accuracy: 0.0001)
    }

    func testBatteryAmperageHandlesPositiveAndThirtyTwoBitComplement() {
        XCTAssertEqual(BatteryDetailParser.signed(2000), 2000)
        XCTAssertEqual(BatteryDetailParser.signed(-300), -300)
        XCTAssertEqual(BatteryDetailParser.signed(UInt32(bitPattern: -750)), -750)
    }

    func testBatteryDetailFallsBackToAmperageAndNilWithoutBattery() throws {
        var props = batteryFixture
        props["InstantAmperage"] = nil
        props["Amperage"] = 900
        XCTAssertEqual(try XCTUnwrap(BatteryDetailParser.parse(props)?.currentAmperes), 0.9, accuracy: 0.0001)
        XCTAssertNil(BatteryDetailParser.parse([:]))
    }

    func testAdapterNameIsCapped() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(BatteryDetailParser.sanitize(long).count, BatteryDetailParser.maxLabelLength)
    }

    func testDockedNeedsEnoughExternalDisplays() {
        XCTAssertTrue(DockState.docked(externalDisplays: 1, minExternalDisplays: 1))
        XCTAssertTrue(DockState.docked(externalDisplays: 2, minExternalDisplays: 1))
        XCTAssertFalse(DockState.docked(externalDisplays: 0, minExternalDisplays: 1))
        XCTAssertFalse(DockState.docked(externalDisplays: 1, minExternalDisplays: 2))
        XCTAssertFalse(DockState.docked(externalDisplays: 5, minExternalDisplays: 0))
    }

    func testUSBFilterDropsInternalPlumbing() {
        XCTAssertFalse(USBFilter.isExternal(vendor: 0x1234, deviceClass: USBFilter.hubClass, builtIn: false, productName: "Hub"))
        XCTAssertFalse(USBFilter.isExternal(vendor: 0x1234, deviceClass: 0, builtIn: true, productName: "Camera"))
        XCTAssertFalse(USBFilter.isExternal(vendor: USBFilter.appleVendor, deviceClass: 0, builtIn: false, productName: nil))
        XCTAssertTrue(USBFilter.isExternal(vendor: USBFilter.appleVendor, deviceClass: 0, builtIn: false, productName: "Magic Mouse"))
        XCTAssertTrue(USBFilter.isExternal(vendor: 0x046d, deviceClass: 0, builtIn: false, productName: "USB Receiver"))
    }

    func testCollectorPublishesCountsWithoutDeviceNamesByDefault() throws {
        let registry = MetricsRegistry()
        let collector = try HardwareCollector(settings: Config().collector("hardware"))
        try collector.start(registry: registry)
        try collector.collect()
        let text = registry.render()
        XCTAssertTrue(text.contains("molly_external_displays"), text)
        XCTAssertTrue(text.contains("molly_docked"), text)
        XCTAssertTrue(text.contains("molly_power_adapter_watts"), text)
        XCTAssertTrue(text.contains("molly_audio_devices{direction=\"output\"}"), text)
        XCTAssertFalse(text.contains("molly_usb_device_info{"), "device names are off by default")
        XCTAssertFalse(text.contains("molly_audio_default_output_info{"), "device names are off by default")
    }

    func testDeviceNamesAppearWhenPolicyEnabled() throws {
        let json = #"{"collectors": {"hardware": {"devices": {"enabled": true}}}}"#
        let config = try Config.parse(Data(json.utf8))
        let registry = MetricsRegistry()
        let collector = try HardwareCollector(settings: config.collector("hardware"))
        try collector.start(registry: registry)
        try collector.collect()
        let text = registry.render()
        guard let summary = CoreAudioProbe.deviceSummary(), summary.outputs > 0 else { throw XCTSkip("no audio output device") }
        XCTAssertTrue(text.contains("molly_audio_default_output_info{"), text)
    }
}
