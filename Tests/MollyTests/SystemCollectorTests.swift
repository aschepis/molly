import XCTest
@testable import Molly

final class SystemCollectorTests: XCTestCase {
    func testCPUTicksDeltaHandlesWraparound() {
        let before = CPUTicks(user: UInt32.max - 5, system: 10, nice: 0, idle: 100)
        let after = CPUTicks(user: 4, system: 30, nice: 0, idle: 150)
        let d = after.delta(since: before)
        XCTAssertEqual(d, CPUTicks(user: 10, system: 20, nice: 0, idle: 50))
        XCTAssertEqual(d.busyRatio, 30.0 / 80.0, accuracy: 1e-9)
    }

    func testBusyRatioIsZeroWithoutTicks() {
        XCTAssertEqual(CPUTicks(user: 0, system: 0, nice: 0, idle: 0).busyRatio, 0)
    }

    func testDeltaTrackerBaselineWrapAndReset() {
        var plain = DeltaTracker()
        XCTAssertNil(plain.delta("a", 100))
        XCTAssertEqual(plain.delta("a", 150), 50)
        XCTAssertEqual(plain.delta("a", 10), 0)
        XCTAssertEqual(plain.delta("a", 25), 15)

        var wrapping = DeltaTracker(wrapAt: 256)
        XCTAssertNil(wrapping.delta("x", 250))
        XCTAssertEqual(wrapping.delta("x", 4), 10)
    }

    func testMemoryPagesToBytes() {
        let pages = MemoryPages(free: 1, active: 2, inactive: 3, wired: 4, compressed: 5)
        let bytes = pages.bytes(pageSize: 16384)
        XCTAssertEqual(bytes["free"], 16384)
        XCTAssertEqual(bytes["compressed"], 5 * 16384)
    }

    func testParseBatteryInfoOnBattery() throws {
        let power: [String: Any] = ["Current Capacity": 80, "Max Capacity": 100, "Is Charging": false,
                                    "Power Source State": "Battery Power", "Time to Empty": 120]
        let smart: [String: Any] = ["CycleCount": 119, "DesignCapacity": 6000, "AppleRawMaxCapacity": 5400, "MaxCapacity": 100]
        let info = try XCTUnwrap(parseBatteryInfo(power: power, smart: smart))
        XCTAssertEqual(info.percent, 80)
        XCTAssertFalse(info.charging)
        XCTAssertFalse(info.onAC)
        XCTAssertEqual(info.timeRemainingSeconds, 7200)
        XCTAssertEqual(info.cycleCount, 119)
        XCTAssertEqual(try XCTUnwrap(info.healthRatio), 0.9, accuracy: 1e-9)
    }

    func testParseBatteryInfoChargingUsesTimeToFullAndUnknownIsMinusOne() throws {
        let charging: [String: Any] = ["Current Capacity": 50, "Max Capacity": 100, "Is Charging": true,
                                       "Power Source State": "AC Power", "Time to Full Charge": 30]
        XCTAssertEqual(try XCTUnwrap(parseBatteryInfo(power: charging, smart: [:])).timeRemainingSeconds, 1800)
        let full: [String: Any] = ["Current Capacity": 100, "Max Capacity": 100, "Is Charging": false,
                                   "Power Source State": "AC Power", "Time to Empty": 0]
        let info = try XCTUnwrap(parseBatteryInfo(power: full, smart: ["MaxCapacity": 92]))
        XCTAssertEqual(info.timeRemainingSeconds, -1)
        XCTAssertEqual(try XCTUnwrap(info.healthRatio), 0.92, accuracy: 1e-9)
        XCTAssertNil(parseBatteryInfo(power: [:], smart: [:]))
    }

    func testParseDiskStats() {
        let stats: [String: Any] = ["Bytes (Read)": 10, "Bytes (Write)": 20, "Operations (Read)": 1, "Operations (Write)": 2]
        XCTAssertEqual(parseDiskStats(stats), DiskStats(readBytes: 10, writeBytes: 20, readOps: 1, writeOps: 2))
        XCTAssertNil(parseDiskStats(["Operations (Read)": 1]))
    }

    func testMountFiltering() {
        XCTAssertTrue(shouldReportMount(fstype: "apfs", mountPoint: "/", isLocal: true, totalBlocks: 100))
        XCTAssertTrue(shouldReportMount(fstype: "apfs", mountPoint: "/System/Volumes/Data", isLocal: true, totalBlocks: 100))
        XCTAssertFalse(shouldReportMount(fstype: "apfs", mountPoint: "/System/Volumes/VM", isLocal: true, totalBlocks: 100))
        XCTAssertFalse(shouldReportMount(fstype: "devfs", mountPoint: "/dev", isLocal: true, totalBlocks: 100))
        XCTAssertFalse(shouldReportMount(fstype: "autofs", mountPoint: "/System/Volumes/Data/home", isLocal: true, totalBlocks: 0))
        XCTAssertFalse(shouldReportMount(fstype: "smbfs", mountPoint: "/Volumes/nas", isLocal: false, totalBlocks: 100))
    }

    func testCollectPublishesCoreFamiliesAndCPURatioOnSecondRun() throws {
        let registry = MetricsRegistry()
        let collector = try SystemCollector(settings: CollectorSettings(name: "system", raw: [:]))
        try collector.start(registry: registry)
        try collector.collect()
        Thread.sleep(forTimeInterval: 0.2)
        try collector.collect()
        let names = registry.familyNames
        for expected in ["molly_cpu_cores", "molly_cpu_utilization_ratio", "molly_load_average", "molly_memory_total_bytes",
                         "molly_uptime_seconds", "molly_processes_count", "molly_disk_total_bytes", "molly_thermal_state"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
        let ratio = try XCTUnwrap(registry.gauge("molly_cpu_utilization_ratio", help: "").value())
        XCTAssertTrue((0...1).contains(ratio))
    }
}
