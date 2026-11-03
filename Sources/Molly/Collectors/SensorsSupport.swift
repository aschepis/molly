import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

// Everything that touches a private Apple interface lives in this file. Private
// symbols are resolved with dlsym at runtime so a missing one degrades to
// CollectorUnavailable instead of a link error or a launch crash.

struct SensorReading: Equatable {
    var name: String
    var value: Double
}

enum SensorSourceID: String, CaseIterable {
    case hid, smc, display
    case lidAngle = "lid_angle"
}

// MARK: - Pure logic (unit-tested)

enum SensorFilter {
    static let temperatureRange: ClosedRange<Double> = -40...150

    /// Drops NaN and values outside the physical range; failed sensors report
    /// sentinels like -127 or 0x7fff that would wreck a graph.
    static func validTemperatures(_ readings: [SensorReading]) -> [SensorReading] {
        readings.filter { $0.value.isFinite && temperatureRange.contains($0.value) }
    }

    /// Trims and collapses whitespace, and numbers repeated names so two
    /// sensors never overwrite each other's series.
    static func normaliseNames(_ readings: [SensorReading]) -> [SensorReading] {
        var seen: [String: Int] = [:]
        return readings.map { reading in
            let words = reading.name.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            let base = words.isEmpty ? "unknown" : words.joined(separator: " ")
            seen[base, default: 0] += 1
            let n = seen[base] ?? 1
            return SensorReading(name: n == 1 ? base : "\(base) #\(n)", value: reading.value)
        }
    }

    static func maxValue(_ readings: [SensorReading]) -> Double? {
        readings.map(\.value).max()
    }
}

enum SMCDecode {
    /// Decodes an SMC value by its four-character type. Apple Silicon "flt "
    /// is little-endian; the integer and fixed-point types are big-endian.
    static func value(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let v = Double(Float(bitPattern: bits))
            return v.isFinite ? v : nil
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }

    static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.utf8)
        guard scalars.count == 4 else { return nil }
        return scalars.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func string(fourCC: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: fourCC >> UInt32($0)) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum LidAngleDecode {
    static let validRange: ClosedRange<Double> = 0...360

    /// Bytes 1-2 of the feature report, little-endian, in degrees.
    static func degrees(report: [UInt8]) -> Double? {
        guard report.count >= 3 else { return nil }
        let angle = Double(UInt16(report[1]) | UInt16(report[2]) << 8)
        return validRange.contains(angle) ? angle : nil
    }
}

// MARK: - dlopen / dlsym

private struct Dylib {
    let path: String
    let handle: UnsafeMutableRawPointer

    init(path: String) throws {
        guard let handle = dlopen(path, RTLD_LAZY) else {
            throw CollectorUnavailable(reason: "cannot dlopen \(path)")
        }
        self.path = path
        self.handle = handle
    }

    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw CollectorUnavailable(reason: "missing symbol \(name) in \(path)")
        }
        return unsafeBitCast(pointer, to: type)
    }
}

// MARK: - HID temperature and ambient light

final class HIDSensorSource {
    private typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias FloatValueFn = @convention(c) (UnsafeRawPointer, Int32) -> Double

    private static let iokitPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
    private static let usagePage = 0xff00
    private static let temperatureUsage = 5
    private static let ambientLightUsage = 4
    private static let temperatureEventType: Int64 = 15
    private static let ambientLightEventType: Int64 = 12

    private let client: UnsafeMutableRawPointer
    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let floatValue: FloatValueFn

    init() throws {
        let lib = try Dylib(path: Self.iokitPath)
        let create = try lib.symbol("IOHIDEventSystemClientCreate", as: CreateFn.self)
        setMatching = try lib.symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self)
        copyServices = try lib.symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self)
        copyProperty = try lib.symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self)
        copyEvent = try lib.symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self)
        floatValue = try lib.symbol("IOHIDEventGetFloatValue", as: FloatValueFn.self)
        guard let client = create(nil) else {
            throw CollectorUnavailable(reason: "IOHIDEventSystemClientCreate returned NULL")
        }
        self.client = client
    }

    deinit { Unmanaged<AnyObject>.fromOpaque(client).release() }

    func temperatures() -> [SensorReading] {
        readings(usage: Self.temperatureUsage, eventType: Self.temperatureEventType)
    }

    /// Raw level of the first ALS service; 0 is a real reading in a dark room.
    func ambientLight() -> Double? {
        readings(usage: Self.ambientLightUsage, eventType: Self.ambientLightEventType)
            .map(\.value).first { $0.isFinite && $0 >= 0 }
    }

    private func readings(usage: Int, eventType: Int64) -> [SensorReading] {
        let matching = ["PrimaryUsagePage": Self.usagePage, "PrimaryUsage": usage] as CFDictionary
        _ = setMatching(client, Unmanaged.passUnretained(matching).toOpaque())
        guard let raw = copyServices(client) else { return [] }
        let services = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        let field = Int32(truncatingIfNeeded: eventType << 16)
        var out: [SensorReading] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, index),
                  let event = copyEvent(service, eventType, 0, 0) else { continue }
            defer { Unmanaged<AnyObject>.fromOpaque(event).release() }
            out.append(SensorReading(name: productName(service), value: floatValue(event, field)))
        }
        return out
    }

    private func productName(_ service: UnsafeRawPointer) -> String {
        let key = "Product" as CFString
        guard let raw = copyProperty(service, Unmanaged.passUnretained(key).toOpaque()) else { return "unknown" }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue() as? String ?? "unknown"
    }
}

// MARK: - SMC fans and power

final class SMCSource {
    private static let service = "AppleSMC"
    private static let handleYPCEvent: UInt32 = 2
    private static let structSize = 80
    private static let readKeyInfoCommand: UInt8 = 9
    private static let readBytesCommand: UInt8 = 5
    private static let resultOffset = 40
    private static let commandOffset = 42
    private static let dataSizeOffset = 28
    private static let dataTypeOffset = 32
    private static let bytesOffset = 48
    private static let maxFans = 4

    private var connection: io_connect_t = 0
    private var keyInfo: [UInt32: (size: UInt32, type: UInt32)] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(Self.service))
        guard service != 0 else { throw CollectorUnavailable(reason: "AppleSMC service not found") }
        defer { IOObjectRelease(service) }
        let rc = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard rc == KERN_SUCCESS else {
            throw CollectorUnavailable(reason: "IOServiceOpen(AppleSMC) refused: 0x\(String(UInt32(bitPattern: rc), radix: 16))")
        }
    }

    deinit { IOServiceClose(connection) }

    func read(_ key: String) -> Double? {
        guard let code = SMCDecode.fourCC(key), let info = lookup(code) else { return nil }
        var input = [UInt8](repeating: 0, count: Self.structSize)
        store(code, at: 0, in: &input)
        store(info.size, at: Self.dataSizeOffset, in: &input)
        input[Self.commandOffset] = Self.readBytesCommand
        guard let output = call(input), output[Self.resultOffset] == 0 else { return nil }
        let size = min(Int(info.size), 32)
        let bytes = Array(output[Self.bytesOffset..<(Self.bytesOffset + size)])
        return SMCDecode.value(type: SMCDecode.string(fourCC: info.type), bytes: bytes)
    }

    func fans() -> [SensorReading] {
        let count = Int(read("FNum") ?? Double(Self.maxFans))
        return (0..<min(count, Self.maxFans)).compactMap { index in
            read("F\(index)Ac").map { SensorReading(name: String(index), value: $0) }
        }
    }

    func power(keys: [(key: String, rail: String)]) -> [SensorReading] {
        keys.compactMap { entry in read(entry.key).map { SensorReading(name: entry.rail, value: $0) } }
    }

    private func lookup(_ code: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = keyInfo[code] { return cached }
        var input = [UInt8](repeating: 0, count: Self.structSize)
        store(code, at: 0, in: &input)
        input[Self.commandOffset] = Self.readKeyInfoCommand
        guard let output = call(input), output[Self.resultOffset] == 0 else { return nil }
        let info = (size: load(at: Self.dataSizeOffset, in: output), type: load(at: Self.dataTypeOffset, in: output))
        guard info.size > 0 else { return nil }
        keyInfo[code] = info
        return info
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let rc = input.withUnsafeBytes { inp in
            output.withUnsafeMutableBytes { out in
                IOConnectCallStructMethod(connection, Self.handleYPCEvent, inp.baseAddress, Self.structSize, out.baseAddress, &outputSize)
            }
        }
        return rc == KERN_SUCCESS ? output : nil
    }

    private func store(_ value: UInt32, at offset: Int, in buffer: inout [UInt8]) {
        withUnsafeBytes(of: value) { raw in
            for (i, byte) in raw.enumerated() { buffer[offset + i] = byte }
        }
    }

    private func load(at offset: Int, in buffer: [UInt8]) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[offset + $1]) << UInt32(8 * $1) }
    }
}

// MARK: - Display brightness

final class DisplayBrightnessSource {
    private typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private let getBrightness: GetBrightnessFn

    init() throws {
        getBrightness = try Dylib(path: Self.path).symbol("DisplayServicesGetBrightness", as: GetBrightnessFn.self)
    }

    func brightness() throws -> Double {
        var value: Float = 0
        let rc = getBrightness(CGMainDisplayID(), &value)
        guard rc == 0, value.isFinite, (0...1).contains(value) else {
            throw CollectorUnavailable(reason: "DisplayServicesGetBrightness returned \(rc)")
        }
        return Double(value)
    }
}

// MARK: - Lid angle (public IOHIDManager API, undocumented device)

final class LidAngleSource {
    private static let sensorUsagePage = 0x20
    private static let lidAngleUsage = 0x8A
    private static let reportID = 1
    private static let reportLength = 8

    private let manager: IOHIDManager
    private var device: IOHIDDevice?

    init() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kIOHIDDeviceUsagePageKey: Self.sensorUsagePage, kIOHIDDeviceUsageKey: Self.lidAngleUsage] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw CollectorUnavailable(reason: "IOHIDManagerOpen refused for the lid angle sensor")
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let first = devices.first else {
            throw CollectorUnavailable(reason: "no HID device with usage page 0x20 usage 0x8A (not a MacBook?)")
        }
        device = first
    }

    deinit { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    func angle() throws -> Double {
        guard let device else { throw CollectorUnavailable(reason: "lid angle device gone") }
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        var length = Self.reportLength
        let rc = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(Self.reportID), &report, &length)
        guard rc == kIOReturnSuccess else {
            throw CollectorUnavailable(reason: "lid angle feature report failed: 0x\(String(UInt32(bitPattern: rc), radix: 16))")
        }
        guard let degrees = LidAngleDecode.degrees(report: Array(report.prefix(length))) else {
            throw CollectorUnavailable(reason: "lid angle report not decodable")
        }
        return degrees
    }
}

// MARK: - Live provider

/// Builds each backend on first use and remembers a failed one, so a machine
/// without a sensor does not retry dlopen every interval.
final class LiveSensorProvider: SensorProvider {
    static let powerKeys: [(key: String, rail: String)] = [
        ("PSTR", "system"), ("PPBR", "battery"), ("PCPC", "cpu"), ("PGPC", "gpu"), ("PDTR", "dc_in"),
    ]

    private var hid: Result<HIDSensorSource, CollectorUnavailable>?
    private var smc: Result<SMCSource, CollectorUnavailable>?
    private var display: Result<DisplayBrightnessSource, CollectorUnavailable>?
    private var lid: Result<LidAngleSource, CollectorUnavailable>?

    func temperatures() throws -> [SensorReading] { try backend(&hid, HIDSensorSource.init).temperatures() }
    func ambientLight() throws -> Double? { try backend(&hid, HIDSensorSource.init).ambientLight() }

    func fans() throws -> [SensorReading] { try backend(&smc, SMCSource.init).fans() }
    func power() throws -> [SensorReading] { try backend(&smc, SMCSource.init).power(keys: Self.powerKeys) }

    func displayBrightness() throws -> Double { try backend(&display, DisplayBrightnessSource.init).brightness() }
    func lidAngle() throws -> Double { try backend(&lid, LidAngleSource.init).angle() }

    private func backend<T>(_ slot: inout Result<T, CollectorUnavailable>?, _ make: () throws -> T) throws -> T {
        if let slot { return try slot.get() }
        do {
            let made = try make()
            slot = .success(made)
            return made
        } catch let unavailable as CollectorUnavailable {
            slot = .failure(unavailable)
            throw unavailable
        }
    }
}
