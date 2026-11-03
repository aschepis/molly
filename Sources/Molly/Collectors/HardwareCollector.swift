import CoreAudio
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

// MARK: - Pure logic (unit-tested)

enum DockState {
    /// "Docked" means the laptop is at a desk: enough external displays are
    /// attached. USB count alone is too noisy (a mouse dongle is not a dock).
    static func docked(externalDisplays: Int, minExternalDisplays: Int) -> Bool {
        minExternalDisplays > 0 && externalDisplays >= minExternalDisplays
    }
}

struct AudioDeviceSummary: Equatable {
    var inputs = 0
    var outputs = 0
}

/// Decides whether a USB registry entry is a device the user plugged in.
/// Hubs and devices flagged built-in are internal plumbing, and so are
/// unnamed Apple-vendor devices (the laptop's own keyboard and trackpad).
enum USBFilter {
    static let hubClass = 9
    static let appleVendor = 0x05ac

    static func isExternal(vendor: Int, deviceClass: Int, builtIn: Bool, productName: String?) -> Bool {
        if deviceClass == hubClass || builtIn { return false }
        if vendor == appleVendor && (productName ?? "").isEmpty { return false }
        return true
    }
}

// MARK: - Collector

/// What is plugged in: USB devices, audio devices, external displays, the
/// power adapter, the lid. "Docked at the desk" versus "on the couch" is a
/// genuinely different work mode and this captures it for free.
final class HardwareCollector: Collector {
    let name = "hardware"
    let interval: TimeInterval
    private let minExternalDisplays: Int
    private let devices: LabelFilter

    private var usbCount: Gauge?
    private var usbInfo: Gauge?
    private var audioDevices: Gauge?
    private var audioOutputInfo: Gauge?
    private var audioInputInfo: Gauge?
    private var externalDisplays: Gauge?
    private var docked: Gauge?
    private var adapterWatts: Gauge?
    private var lidClosed: Gauge?
    private var skipped: Set<String> = []

    init(settings: CollectorSettings) throws {
        interval = settings.interval(default: 30)
        minExternalDisplays = settings.int("dockedMinExternalDisplays", default: 1)
        devices = try settings.filter("devices", defaults: LabelPolicy(enabled: false, mode: .denylist, maxCardinality: 20))
    }

    func start(registry r: MetricsRegistry) throws {
        usbCount = r.gauge("molly_usb_devices", help: "USB devices attached (count only).")
        usbInfo = r.gauge("molly_usb_device_info", help: "1 per attached USB device; only with the devices policy enabled.", labels: ["name"])
        audioDevices = r.gauge("molly_audio_devices", help: "Audio devices by direction.", labels: ["direction"])
        audioOutputInfo = r.gauge("molly_audio_default_output_info", help: "1 for the default output device; only with the devices policy enabled.", labels: ["name"])
        audioInputInfo = r.gauge("molly_audio_default_input_info", help: "1 for the default input device; only with the devices policy enabled.", labels: ["name"])
        externalDisplays = r.gauge("molly_external_displays", help: "Attached displays that are not built in.")
        docked = r.gauge("molly_docked", help: "1 when at least dockedMinExternalDisplays external displays are attached.")
        adapterWatts = r.gauge("molly_power_adapter_watts", help: "Rated watts of the connected power adapter, -1 when none or unknown.")
        lidClosed = r.gauge("molly_lid_closed", help: "1 when the clamshell is closed.")
    }

    func collect() throws {
        collectUSB()
        collectAudio()
        collectDisplays()
        collectPowerAdapter()
        collectLid()
    }

    private func collectUSB() {
        guard let names = IOKitProbe.usbDeviceNames() else { return skip("usb", "IOKit USB matching failed") }
        usbCount?.set(names.count)
        usbInfo?.reset()
        guard devices.enabled else { return }
        var counts: [String: Double] = [:]
        for n in names { counts[n, default: 0] += 1 }
        for (label, n) in devices.labels(counts) { usbInfo?.set(n, labels: ["name": label]) }
    }

    private func collectAudio() {
        guard let summary = CoreAudioProbe.deviceSummary() else { return skip("audio", "device list unreadable") }
        audioDevices?.set(summary.inputs, labels: ["direction": "input"])
        audioDevices?.set(summary.outputs, labels: ["direction": "output"])
        audioOutputInfo?.reset()
        audioInputInfo?.reset()
        guard devices.enabled else { return }
        if let out = CoreAudioProbe.defaultDevice(input: false), let n = CoreAudioProbe.deviceName(out) {
            audioOutputInfo?.set(1, labels: ["name": devices.label(n)])
        }
        if let inp = CoreAudioProbe.defaultDevice(input: true), let n = CoreAudioProbe.deviceName(inp) {
            audioInputInfo?.set(1, labels: ["name": devices.label(n)])
        }
    }

    private func collectDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return skip("displays", "CGGetActiveDisplayList failed") }
        let external = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
        externalDisplays?.set(external)
        docked?.set(DockState.docked(externalDisplays: external, minExternalDisplays: minExternalDisplays) ? 1 : 0)
    }

    private func collectPowerAdapter() {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let watts = details[kIOPSPowerAdapterWattsKey as String] as? Int else {
            adapterWatts?.set(-1)
            return
        }
        adapterWatts?.set(watts)
    }

    private func collectLid() {
        guard let closed = IOKitProbe.clamshellClosed() else {
            lidClosed?.reset()
            return skip("lid", "AppleClamshellState not available")
        }
        lidClosed?.set(closed ? 1 : 0)
    }

    private func skip(_ source: String, _ reason: String) {
        guard skipped.insert(source).inserted else { return }
        Log.debug("hardware: \(source) skipped: \(reason)")
    }
}

// MARK: - Probes

enum IOKitProbe {
    /// Product names of attached external USB devices. nil if IOKit refuses;
    /// an empty list is a valid answer.
    static func usbDeviceNames() -> [String]? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOUSBHostDevice"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            let productName = property(device, "USB Product Name") as? String ?? property(device, "kUSBProductString") as? String
            let external = USBFilter.isExternal(vendor: property(device, "idVendor") as? Int ?? 0,
                                                deviceClass: property(device, "bDeviceClass") as? Int ?? 0,
                                                builtIn: property(device, "Built-In") as? Bool ?? false,
                                                productName: productName)
            if external { names.append(productName ?? "unknown") }
        }
        return names
    }

    static func clamshellClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return property(root, "AppleClamshellState") as? Bool
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

extension CoreAudioProbe {
    private static func globalAddress(_ selector: AudioObjectPropertySelector,
                                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDevices() -> [AudioDeviceID]? {
        var addr = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else { return nil }
        return devices
    }

    static func streamCount(_ device: AudioDeviceID, input: Bool) -> Int {
        var addr = globalAddress(kAudioDevicePropertyStreams, scope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func deviceSummary() -> AudioDeviceSummary? {
        guard let devices = allDevices() else { return nil }
        var summary = AudioDeviceSummary()
        for d in devices {
            if streamCount(d, input: true) > 0 { summary.inputs += 1 }
            if streamCount(d, input: false) > 0 { summary.outputs += 1 }
        }
        return summary
    }

    static func deviceName(_ device: AudioDeviceID) -> String? {
        var addr = globalAddress(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let rc = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name)
        guard rc == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
