import AppKit
import CoreAudio
import CoreGraphics
import CoreWLAN
import Foundation
import IOBluetooth
import IOKit
import IOKit.ps

// MARK: - Pure helpers (unit-tested)

/// Turns an ever-growing raw counter into increments. The first sample only
/// sets the baseline so a counter never claims history from before Molly ran.
struct DeltaTracker {
    private var previous: [String: Double] = [:]
    /// Modulus for counters that wrap (32-bit interface counters).
    let wrapAt: Double?

    init(wrapAt: Double? = nil) { self.wrapAt = wrapAt }

    mutating func delta(_ key: String, _ value: Double) -> Double? {
        defer { previous[key] = value }
        guard let before = previous[key] else { return nil }
        if value >= before { return value - before }
        if let wrapAt { return value + wrapAt - before }
        return 0 // the source was reset (device re-attached); rebase quietly
    }
}

/// Cumulative CPU ticks of one core (or the sum of all cores).
struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var nice: UInt32
    var idle: UInt32

    /// Ticks since `previous`, tolerant of 32-bit wraparound.
    func delta(since previous: CPUTicks) -> CPUTicks {
        CPUTicks(user: user &- previous.user, system: system &- previous.system,
                 nice: nice &- previous.nice, idle: idle &- previous.idle)
    }

    var total: UInt64 { UInt64(user) + UInt64(system) + UInt64(nice) + UInt64(idle) }

    /// Share of the interval spent not idle, 0 when no ticks elapsed.
    var busyRatio: Double {
        let all = total
        guard all > 0 else { return 0 }
        return Double(all - UInt64(idle)) / Double(all)
    }

    static func + (a: CPUTicks, b: CPUTicks) -> CPUTicks {
        CPUTicks(user: a.user &+ b.user, system: a.system &+ b.system,
                 nice: a.nice &+ b.nice, idle: a.idle &+ b.idle)
    }
}

struct MemoryPages {
    var free: UInt64
    var active: UInt64
    var inactive: UInt64
    var wired: UInt64
    var compressed: UInt64

    func bytes(pageSize: UInt64) -> [String: Double] {
        ["free": Double(free * pageSize), "active": Double(active * pageSize),
         "inactive": Double(inactive * pageSize), "wired": Double(wired * pageSize),
         "compressed": Double(compressed * pageSize)]
    }
}

struct BatteryInfo: Equatable {
    var percent: Double
    var charging: Bool
    var onAC: Bool
    var timeRemainingSeconds: Double
    var cycleCount: Double?
    var healthRatio: Double?
}

/// Builds a BatteryInfo from the IOPS description dictionary and the
/// AppleSmartBattery registry properties. Nil when there is no battery.
func parseBatteryInfo(power: [String: Any], smart: [String: Any]) -> BatteryInfo? {
    func number(_ dict: [String: Any], _ key: String) -> Double? { (dict[key] as? NSNumber)?.doubleValue }
    guard let current = number(power, "Current Capacity") else { return nil }
    let maxCapacity = number(power, "Max Capacity") ?? 100
    guard maxCapacity > 0 else { return nil }
    let charging = (power["Is Charging"] as? NSNumber)?.boolValue ?? false
    let onAC = (power["Power Source State"] as? String) == "AC Power"
    let minutes = number(power, charging ? "Time to Full Charge" : "Time to Empty") ?? -1
    let seconds = minutes > 0 ? minutes * 60 : -1 // 0 means "not applicable" on AC

    // Apple Silicon reports MaxCapacity as a percentage; the raw mAh value is separate.
    var health: Double?
    if let design = number(smart, "DesignCapacity"), design > 0 {
        let rawMax = number(smart, "AppleRawMaxCapacity") ?? number(smart, "NominalChargeCapacity")
        if let rawMax, rawMax > 0 { health = rawMax / design }
    }
    if health == nil, let pct = number(smart, "MaxCapacity"), pct > 0, pct <= 100 {
        health = pct / 100
    }
    return BatteryInfo(percent: current / maxCapacity * 100, charging: charging, onAC: onAC,
                       timeRemainingSeconds: seconds, cycleCount: number(smart, "CycleCount"),
                       healthRatio: health)
}

struct DiskStats: Equatable {
    var readBytes: Double
    var writeBytes: Double
    var readOps: Double
    var writeOps: Double
}

/// Reads the IOBlockStorageDriver "Statistics" dictionary.
func parseDiskStats(_ stats: [String: Any]) -> DiskStats? {
    func n(_ key: String) -> Double? { (stats[key] as? NSNumber)?.doubleValue }
    guard let rb = n("Bytes (Read)"), let wb = n("Bytes (Write)") else { return nil }
    return DiskStats(readBytes: rb, writeBytes: wb, readOps: n("Operations (Read)") ?? 0,
                     writeOps: n("Operations (Write)") ?? 0)
}

/// Which mounted filesystems deserve a disk-space series.
func shouldReportMount(fstype: String, mountPoint: String, isLocal: Bool, totalBlocks: UInt64) -> Bool {
    guard isLocal, totalBlocks > 0 else { return false }
    if ["devfs", "autofs", "nullfs", "fdesc"].contains(fstype) { return false }
    // Preboot, VM, Update, ... share the container with Data and add only noise.
    if mountPoint.hasPrefix("/System/Volumes/"), mountPoint != "/System/Volumes/Data" { return false }
    return true
}

struct InterfaceAddress: Equatable {
    enum Kind { case ipv4, ipv6, ipv6LinkLocal }
    let name: String
    let kind: Kind
}

/// macOS keeps link-local-only utun interfaces up permanently; a real tunnel
/// has a routable address.
func isVPNActive(_ addresses: [InterfaceAddress]) -> Bool {
    let prefixes = ["utun", "ipsec", "ppp", "tun", "tap"]
    return addresses.contains { addr in
        addr.kind != .ipv6LinkLocal && prefixes.contains { addr.name.hasPrefix($0) }
    }
}

func isLinkLocalIPv6(_ bytes: [UInt8]) -> Bool {
    bytes.count >= 2 && bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
}

// MARK: - Collector

/// CPU, memory, disk, network, battery, displays and other machine vitals.
/// A source that is missing or fails is skipped (logged once at debug) so one
/// flaky API never blanks the whole collector.
final class SystemCollector: Collector {
    let name = "system"
    let interval: TimeInterval

    private static let clockTicksPerSecond = 100.0
    private static let thirtyTwoBit = 4_294_967_296.0

    private let wifiFilter: LabelFilter
    private let bluetoothEnabled: Bool
    private var skipped: Set<String> = []

    private var previousCPU: [CPUTicks] = []
    private var diskDeltas = DeltaTracker()
    private var netDeltas = DeltaTracker(wrapAt: SystemCollector.thirtyTwoBit)

    private var m: Instruments?

    init(settings: CollectorSettings) throws {
        interval = settings.interval(default: 15)
        wifiFilter = try settings.filter("wifi", defaults: LabelPolicy(enabled: false))
        bluetoothEnabled = settings.bool("bluetooth", default: true)
    }

    /// All gauges and counters, created once in `start`.
    private struct Instruments {
        let cpuSeconds: Counter
        let cpuUtilization: Gauge
        let cpuCores: Gauge
        let load: Gauge
        let memory: Gauge
        let memoryTotal: Gauge
        let memoryPressure: Gauge
        let swap: Gauge
        let swapTotal: Gauge
        let uptime: Gauge
        let bootTime: Gauge
        let processes: Gauge
        let thermal: Gauge
        let diskTotal: Gauge
        let diskFree: Gauge
        let diskReadBytes: Counter
        let diskWriteBytes: Counter
        let diskReadOps: Counter
        let diskWriteOps: Counter
        let netRxBytes: Counter
        let netTxBytes: Counter
        let netRxPackets: Counter
        let netTxPackets: Counter
        let netRxErrors: Counter
        let netTxErrors: Counter
        let vpn: Gauge
        let wifiInfo: Gauge
        let wifiConnected: Gauge
        let batteryPercent: Gauge
        let batteryCharging: Gauge
        let batteryOnAC: Gauge
        let batteryTime: Gauge
        let batteryCycles: Gauge
        let batteryHealth: Gauge
        let displays: Gauge
        let displayInfo: Gauge
        let darkMode: Gauge
        let bluetooth: Gauge
        let audioVolume: Gauge
    }

    func start(registry r: MetricsRegistry) throws {
        let iface = ["interface"]
        let dev = ["device"]
        let mount = ["mount", "fstype"]
        m = Instruments(
            cpuSeconds: r.counter("molly_cpu_seconds_total", help: "CPU time by core and mode; cpu=total sums all cores.", labels: ["cpu", "mode"]),
            cpuUtilization: r.gauge("molly_cpu_utilization_ratio", help: "Busy share of all cores since the previous run (0..1)."),
            cpuCores: r.gauge("molly_cpu_cores", help: "Logical CPU cores."),
            load: r.gauge("molly_load_average", help: "Load average.", labels: ["period"]),
            memory: r.gauge("molly_memory_bytes", help: "Memory by state.", labels: ["state"]),
            memoryTotal: r.gauge("molly_memory_total_bytes", help: "Installed physical memory."),
            memoryPressure: r.gauge("molly_memory_pressure_level", help: "1 normal, 2 warning, 4 critical."),
            swap: r.gauge("molly_swap_bytes", help: "Swap by state.", labels: ["state"]),
            swapTotal: r.gauge("molly_swap_total_bytes", help: "Total swap space."),
            uptime: r.gauge("molly_uptime_seconds", help: "Seconds since boot."),
            bootTime: r.gauge("molly_boot_time_seconds", help: "Unix time of the last boot."),
            processes: r.gauge("molly_processes_count", help: "Running processes."),
            thermal: r.gauge("molly_thermal_state", help: "0 nominal, 1 fair, 2 serious, 3 critical."),
            diskTotal: r.gauge("molly_disk_total_bytes", help: "Volume size.", labels: mount),
            diskFree: r.gauge("molly_disk_free_bytes", help: "Volume space available to users.", labels: mount),
            diskReadBytes: r.counter("molly_disk_read_bytes_total", help: "Bytes read from storage.", labels: dev),
            diskWriteBytes: r.counter("molly_disk_write_bytes_total", help: "Bytes written to storage.", labels: dev),
            diskReadOps: r.counter("molly_disk_read_ops_total", help: "Read operations.", labels: dev),
            diskWriteOps: r.counter("molly_disk_write_ops_total", help: "Write operations.", labels: dev),
            netRxBytes: r.counter("molly_network_receive_bytes_total", help: "Bytes received.", labels: iface),
            netTxBytes: r.counter("molly_network_transmit_bytes_total", help: "Bytes sent.", labels: iface),
            netRxPackets: r.counter("molly_network_receive_packets_total", help: "Packets received.", labels: iface),
            netTxPackets: r.counter("molly_network_transmit_packets_total", help: "Packets sent.", labels: iface),
            netRxErrors: r.counter("molly_network_receive_errors_total", help: "Receive errors.", labels: iface),
            netTxErrors: r.counter("molly_network_transmit_errors_total", help: "Transmit errors.", labels: iface),
            vpn: r.gauge("molly_network_vpn_active", help: "1 when a VPN tunnel interface has a routable address."),
            wifiInfo: r.gauge("molly_network_wifi_info", help: "Connected Wi-Fi network (ssid label needs the wifi policy).", labels: ["ssid"]),
            wifiConnected: r.gauge("molly_network_wifi_connected", help: "1 when Wi-Fi is associated with a network."),
            batteryPercent: r.gauge("molly_battery_percent", help: "Battery charge, 0..100."),
            batteryCharging: r.gauge("molly_battery_charging", help: "1 while charging."),
            batteryOnAC: r.gauge("molly_battery_on_ac", help: "1 on AC power."),
            batteryTime: r.gauge("molly_battery_time_remaining_seconds", help: "Seconds to empty (or full when charging); -1 unknown."),
            batteryCycles: r.gauge("molly_battery_cycle_count", help: "Battery charge cycles."),
            batteryHealth: r.gauge("molly_battery_health_ratio", help: "Maximum over design capacity."),
            displays: r.gauge("molly_displays", help: "Active displays."),
            displayInfo: r.gauge("molly_display_info", help: "One series per display.", labels: ["display", "width", "height", "scale"]),
            darkMode: r.gauge("molly_dark_mode", help: "1 when the system appearance is dark."),
            bluetooth: r.gauge("molly_bluetooth_devices_connected", help: "Connected Bluetooth devices."),
            audioVolume: r.gauge("molly_audio_output_volume_ratio", help: "Default output volume, 0..1.")
        )
    }

    func collect() throws {
        guard let m else { return }
        collectCPU(m)
        collectLoad(m)
        collectMemory(m)
        collectSwap(m)
        collectUptime(m)
        collectProcessCount(m)
        m.thermal.set(Double(ProcessInfo.processInfo.thermalState.rawValue))
        collectDisks(m)
        collectDiskIO(m)
        collectNetwork(m)
        collectWiFi(m)
        collectBattery(m)
        collectDisplays(m)
        m.darkMode.set(UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? 1 : 0)
        if bluetoothEnabled { collectBluetooth(m) }
        collectAudio(m)
    }

    private func skip(_ source: String, _ reason: String) {
        guard skipped.insert(source).inserted else { return }
        Log.debug("system: \(source) unavailable: \(reason)")
    }

    // MARK: CPU

    private func readCPUTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let rc = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard rc == KERN_SUCCESS, let info else { return nil }
        defer {
            let bytes = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), bytes)
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { core in
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[core * stride + Int(state)]) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                            nice: tick(CPU_STATE_NICE), idle: tick(CPU_STATE_IDLE))
        }
    }

    private func collectCPU(_ m: Instruments) {
        guard let cores = readCPUTicks() else { return skip("cpu", "host_processor_info failed") }
        m.cpuCores.set(Double(cores.count))
        if previousCPU.count == cores.count {
            var totalDelta = CPUTicks(user: 0, system: 0, nice: 0, idle: 0)
            for (index, ticks) in cores.enumerated() {
                let d = ticks.delta(since: previousCPU[index])
                totalDelta = totalDelta + d
                addCPU(m, cpu: String(index), d)
            }
            addCPU(m, cpu: "total", totalDelta)
            m.cpuUtilization.set(totalDelta.busyRatio)
        } else {
            for mode in ["user", "system", "nice", "idle"] { m.cpuSeconds.touch(labels: ["cpu": "total", "mode": mode]) }
        }
        previousCPU = cores
    }

    private func addCPU(_ m: Instruments, cpu: String, _ d: CPUTicks) {
        let modes: [(String, UInt32)] = [("user", d.user), ("system", d.system), ("nice", d.nice), ("idle", d.idle)]
        for (mode, ticks) in modes {
            m.cpuSeconds.add(Double(ticks) / SystemCollector.clockTicksPerSecond, labels: ["cpu": cpu, "mode": mode])
        }
    }

    private func collectLoad(_ m: Instruments) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return skip("load", "getloadavg failed") }
        for (period, value) in zip(["1m", "5m", "15m"], loads) { m.load.set(value, labels: ["period": period]) }
    }

    // MARK: Memory

    private func readMemoryPages() -> MemoryPages? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        return MemoryPages(free: UInt64(stats.free_count), active: UInt64(stats.active_count),
                           inactive: UInt64(stats.inactive_count), wired: UInt64(stats.wire_count),
                           compressed: UInt64(stats.compressor_page_count))
    }

    private func collectMemory(_ m: Instruments) {
        if let pages = readMemoryPages() {
            for (state, bytes) in pages.bytes(pageSize: UInt64(getpagesize())) {
                m.memory.set(bytes, labels: ["state": state])
            }
        } else {
            skip("memory", "host_statistics64 failed")
        }
        var total: UInt64 = 0
        if Sysctl.read("hw.memsize", into: &total) { m.memoryTotal.set(Double(total)) }
        var pressure: Int32 = 0
        if Sysctl.read("kern.memorystatus_vm_pressure_level", into: &pressure) {
            m.memoryPressure.set(Double(pressure))
        } else {
            skip("memory pressure", "sysctl missing")
        }
    }

    private func collectSwap(_ m: Instruments) {
        var swap = xsw_usage()
        guard Sysctl.read("vm.swapusage", into: &swap) else { return skip("swap", "sysctl failed") }
        m.swap.set(Double(swap.xsu_used), labels: ["state": "used"])
        m.swap.set(Double(swap.xsu_avail), labels: ["state": "free"])
        m.swapTotal.set(Double(swap.xsu_total))
    }

    // MARK: Uptime and processes

    private func collectUptime(_ m: Instruments) {
        var boot = timeval()
        guard Sysctl.read("kern.boottime", into: &boot) else { return skip("uptime", "kern.boottime failed") }
        let bootSeconds = Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6
        m.bootTime.set(bootSeconds)
        m.uptime.set(Date().timeIntervalSince1970 - bootSeconds)
    }

    private func collectProcessCount(_ m: Instruments) {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return skip("process count", "proc_listpids failed") }
        m.processes.set(Double(Int(bytes) / MemoryLayout<pid_t>.size))
    }

    // MARK: Disks

    private func collectDisks(_ m: Instruments) {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return skip("disk space", "getmntinfo failed") }
        m.diskTotal.reset()
        m.diskFree.reset()
        for var fs in UnsafeBufferPointer(start: mounts, count: Int(count)) {
            let fstype = withUnsafePointer(to: &fs.f_fstypename) { cString($0) }
            let mountPoint = withUnsafePointer(to: &fs.f_mntonname) { cString($0) }
            guard shouldReportMount(fstype: fstype, mountPoint: mountPoint,
                                    isLocal: fs.f_flags & UInt32(MNT_LOCAL) != 0, totalBlocks: fs.f_blocks) else { continue }
            let labels = ["mount": mountPoint, "fstype": fstype]
            m.diskTotal.set(Double(fs.f_blocks) * Double(fs.f_bsize), labels: labels)
            m.diskFree.set(Double(fs.f_bavail) * Double(fs.f_bsize), labels: labels)
        }
    }

    private func cString<T>(_ pointer: UnsafePointer<T>) -> String {
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }

    private func collectDiskIO(_ m: Instruments) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return skip("disk io", "IOBlockStorageDriver lookup failed")
        }
        defer { IOObjectRelease(iterator) }
        var index = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service); index += 1 }
            guard let raw = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let dict = raw as? [String: Any], let stats = parseDiskStats(dict) else { continue }
            let device = bsdName(of: service) ?? "disk\(index)"
            let labels = ["device": device]
            let readings: [(String, Counter, Double)] = [
                ("rb", m.diskReadBytes, stats.readBytes), ("wb", m.diskWriteBytes, stats.writeBytes),
                ("ro", m.diskReadOps, stats.readOps), ("wo", m.diskWriteOps, stats.writeOps),
            ]
            for (kind, counter, value) in readings {
                if let d = diskDeltas.delta("\(device)/\(kind)", value) {
                    counter.add(d, labels: labels)
                } else {
                    counter.touch(labels: labels)
                }
            }
        }
    }

    private func bsdName(of service: io_registry_entry_t) -> String? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if let name = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                return name
            }
        }
        return nil
    }

    // MARK: Network

    private func collectNetwork(_ m: Instruments) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return skip("network", "getifaddrs failed") }
        defer { freeifaddrs(head) }
        var addresses: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let ifa = entry.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                guard !name.hasPrefix("lo"), let data = ifa.ifa_data else { continue }
                recordInterface(m, name: name, data: data.assumingMemoryBound(to: if_data.self).pointee)
            case AF_INET:
                addresses.append(InterfaceAddress(name: name, kind: .ipv4))
            case AF_INET6:
                let bytes = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                    withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
                }
                addresses.append(InterfaceAddress(name: name, kind: isLinkLocalIPv6(bytes) ? .ipv6LinkLocal : .ipv6))
            default:
                continue
            }
        }
        m.vpn.set(isVPNActive(addresses) ? 1 : 0)
    }

    private func recordInterface(_ m: Instruments, name: String, data: if_data) {
        let labels = ["interface": name]
        // Skip the many virtual interfaces (utun*, anpi*, ...) that never carry traffic.
        let hasTraffic = data.ifi_ibytes > 0 || data.ifi_obytes > 0
        let readings: [(String, Counter, UInt32)] = [
            ("rb", m.netRxBytes, data.ifi_ibytes), ("tb", m.netTxBytes, data.ifi_obytes),
            ("rp", m.netRxPackets, data.ifi_ipackets), ("tp", m.netTxPackets, data.ifi_opackets),
            ("re", m.netRxErrors, data.ifi_ierrors), ("te", m.netTxErrors, data.ifi_oerrors),
        ]
        for (kind, counter, value) in readings {
            let delta = netDeltas.delta("\(name)/\(kind)", Double(value))
            guard hasTraffic else { continue }
            counter.add(delta ?? 0, labels: labels)
        }
    }

    private func collectWiFi(_ m: Instruments) {
        guard let wifi = CWWiFiClient.shared().interface() else { return skip("wifi", "no Wi-Fi interface") }
        let ssid = wifi.ssid()
        let connected = ssid != nil || (wifi.powerOn() && wifi.rssiValue() != 0)
        m.wifiConnected.set(connected ? 1 : 0)
        m.wifiInfo.reset()
        guard connected, wifiFilter.enabled else { return }
        if let ssid {
            m.wifiInfo.set(1, labels: ["ssid": wifiFilter.label(ssid)])
        } else {
            skip("wifi ssid", "SSID hidden without Location permission; publishing connected only")
        }
    }

    // MARK: Battery, displays, bluetooth, audio

    private func collectBattery(_ m: Instruments) {
        guard let info = readBattery() else { return skip("battery", "no internal battery") }
        m.batteryPercent.set(info.percent)
        m.batteryCharging.set(info.charging ? 1 : 0)
        m.batteryOnAC.set(info.onAC ? 1 : 0)
        m.batteryTime.set(info.timeRemainingSeconds)
        if let cycles = info.cycleCount { m.batteryCycles.set(cycles) }
        if let health = info.healthRatio { m.batteryHealth.set(health) }
    }

    private func readBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery" else { continue }
            return parseBatteryInfo(power: description, smart: smartBatteryProperties())
        }
        return nil
    }

    private func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    // CoreGraphics rather than NSScreen: it is thread-safe, and collect() runs off the main thread.
    private func collectDisplays(_ m: Instruments) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            return skip("displays", "CGGetActiveDisplayList failed")
        }
        m.displays.set(Double(count))
        m.displayInfo.reset()
        for (index, id) in ids.prefix(Int(count)).enumerated() {
            let bounds = CGDisplayBounds(id)
            let pixelWidth = CGDisplayCopyDisplayMode(id)?.pixelWidth ?? Int(bounds.width)
            let scale = bounds.width > 0 ? Double(pixelWidth) / Double(bounds.width) : 1
            m.displayInfo.set(1, labels: ["display": String(index), "width": String(Int(bounds.width)),
                                          "height": String(Int(bounds.height)), "scale": Metrics.format(scale.rounded())])
        }
    }

    private func collectBluetooth(_ m: Instruments) {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        m.bluetooth.set(Double(paired.filter { $0.isConnected() }.count))
    }

    private func collectAudio(_ m: Instruments) {
        guard let volume = CoreAudioProbe.defaultOutputVolume() else { return skip("audio volume", "default output has no volume control") }
        m.audioVolume.set(Double(volume))
    }
}

// MARK: - Low-level readers

enum Sysctl {
    static func read<T>(_ name: String, into value: inout T) -> Bool {
        var size = MemoryLayout<T>.size
        return withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) == 0 }
    }
}

enum CoreAudioProbe {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let rc = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return rc == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func defaultOutputVolume() -> Float? {
        guard let device = defaultDevice(input: false) else { return nil }
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr { return volume }
        }
        return nil
    }

    /// nil when there is no default input device or the property is unreadable.
    static func isInputRunning() -> Bool? {
        guard let device = defaultDevice(input: true) else { return nil }
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }
}

// MARK: - Doctor

enum GroupADoctor {
    static func checks(config: Config) -> [DoctorCommand.Check] {
        let policy = (try? config.collector("system").filter("wifi", defaults: LabelPolicy(enabled: false))) ?? .disabled
        guard policy.enabled else { return [] }
        let visible = CWWiFiClient.shared().interface()?.ssid() != nil
        return [DoctorCommand.Check(name: "wifi ssid", ok: visible,
                                    detail: visible ? "SSID readable" : "SSID hidden: grant Location access to your terminal/Molly, or leave the wifi policy off")]
    }
}
