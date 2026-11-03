import Foundation

/// Molly's own footprint, so a dashboard can prove the observer is cheap.
final class ProcessSelfCollector: Collector {
    let name = "process"
    let interval: TimeInterval
    private var residentBytes: Gauge?
    private var cpuSeconds: Counter?
    private var lastCPUSeconds: Double = 0
    private var threads: Gauge?

    init(settings: CollectorSettings) {
        interval = settings.interval(default: 30)
    }

    func start(registry: MetricsRegistry) throws {
        residentBytes = registry.gauge("molly_self_resident_memory_bytes", help: "Resident memory of the Molly process.")
        cpuSeconds = registry.counter("molly_self_cpu_seconds_total", help: "CPU time consumed by the Molly process.")
        threads = registry.gauge("molly_self_threads", help: "Threads in the Molly process.")
    }

    func collect() throws {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if rc == KERN_SUCCESS {
            residentBytes?.set(Double(info.resident_size))
        }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            let total = user + system
            cpuSeconds?.add(max(0, total - lastCPUSeconds))
            lastCPUSeconds = total
        }
        threads?.set(threadCount())
    }

    private func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.size))
        return Int(count)
    }
}
