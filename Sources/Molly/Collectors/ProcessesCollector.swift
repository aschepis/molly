import Darwin
import Foundation

// MARK: - Pure helpers (unit-tested)

struct ProcessSample: Equatable {
    let pid: Int32
    let name: String
    /// Cumulative user+system CPU seconds.
    let cpuSeconds: Double
    let residentBytes: Double
}

struct ProcessSummary: Equatable {
    var cpuRatio: Double = 0
    var residentBytes: Double = 0
    var count: Int = 0
}

enum ProcessMath {
    /// CPU ratio per pid over `wallSeconds` (1.0 = one full core). Pids with no
    /// earlier sample, or whose CPU time went backwards (pid reuse), get 0.
    static func cpuRatios(previous: [Int32: Double], current: [ProcessSample], wallSeconds: Double) -> [Int32: Double] {
        guard wallSeconds > 0 else { return [:] }
        var out: [Int32: Double] = [:]
        for sample in current {
            guard let before = previous[sample.pid], sample.cpuSeconds >= before else { out[sample.pid] = 0; continue }
            out[sample.pid] = (sample.cpuSeconds - before) / wallSeconds
        }
        return out
    }

    /// Sums samples that share a process name (Chrome has dozens of helpers).
    static func summarize(_ samples: [ProcessSample], ratios: [Int32: Double]) -> [String: ProcessSummary] {
        var out: [String: ProcessSummary] = [:]
        for s in samples {
            out[s.name, default: ProcessSummary()].cpuRatio += ratios[s.pid] ?? 0
            out[s.name, default: ProcessSummary()].residentBytes += s.residentBytes
            out[s.name, default: ProcessSummary()].count += 1
        }
        return out
    }

    /// The n names with the largest value, ties broken by name for stable output.
    static func top(_ summaries: [String: ProcessSummary], n: Int, by value: (ProcessSummary) -> Double) -> [String] {
        summaries.sorted { a, b in
            let (x, y) = (value(a.value), value(b.value))
            return x == y ? a.key < b.key : x > y
        }.prefix(n).map { $0.key }
    }
}

enum AgentMatcher {
    static let defaults: [String: [String]] = [
        "claude": ["claude"],
        "codex": ["codex"],
        "cursor": ["Cursor Helper", "cursor"],
        "aider": ["aider"],
        "copilot": ["copilot"],
        "gemini": ["gemini"],
        "ollama": ["ollama"],
    ]

    /// Config entries override the defaults per agent; an empty list turns an agent off.
    static func merged(config: [String: JSONValue]?) -> [String: [String]] {
        var agents = defaults
        for (agent, patterns) in config ?? [:] {
            agents[agent] = (patterns.arrayValue ?? []).compactMap { $0.stringValue }
        }
        return agents.filter { !$0.value.isEmpty }
    }

    /// Agents whose pattern is a case-insensitive substring of the process name.
    static func matches(name: String, agents: [String: [String]]) -> [String] {
        let lower = name.lowercased()
        return agents.filter { _, patterns in
            patterns.contains { lower.contains($0.lowercased()) }
        }.keys.sorted()
    }
}

// MARK: - Collector

/// Top-N processes by CPU and memory, plus per-AI-agent process counts.
final class ProcessesCollector: Collector {
    static let namesDefaults = LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 25)
    let name = "processes"
    let interval: TimeInterval

    private let nameFilter: LabelFilter
    private let topN: Int
    private let agents: [String: [String]]

    private var cpuRatio: Gauge?
    private var residentBytes: Gauge?
    private var countByName: Gauge?
    private var agentProcesses: Gauge?
    private var agentCPU: Gauge?

    private var previousCPU: [Int32: Double] = [:]
    private var previousTime: Date?

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }()
    private static let nanosPerSecond = 1e9
    private static let truncatedNameLength: Int32 = 31

    init(settings: CollectorSettings) throws {
        interval = settings.interval(default: 30)
        nameFilter = try settings.filter("names", defaults: ProcessesCollector.namesDefaults)
        topN = max(1, settings.int("topN", default: 25))
        agents = AgentMatcher.merged(config: settings.raw["agents"]?.objectValue)
    }

    func start(registry: MetricsRegistry) throws {
        cpuRatio = registry.gauge("molly_process_cpu_ratio", help: "CPU use of top processes by name; 1.0 is one full core.", labels: ["name"])
        residentBytes = registry.gauge("molly_process_resident_memory_bytes", help: "Resident memory of top processes by name.", labels: ["name"])
        countByName = registry.gauge("molly_process_count_by_name", help: "Process instances for the top names.", labels: ["name"])
        agentProcesses = registry.gauge("molly_agent_processes", help: "Running processes matching an AI agent.", labels: ["agent"])
        agentCPU = registry.gauge("molly_agent_process_cpu_ratio", help: "CPU use of an AI agent's processes; 1.0 is one full core.", labels: ["agent"])
    }

    func collect() throws {
        let now = Date()
        let samples = Self.sampleAll()
        guard !samples.isEmpty else { throw CollectorUnavailable(reason: "libproc returned no processes") }

        let wall = previousTime.map { now.timeIntervalSince($0) } ?? 0
        let haveBaseline = !previousCPU.isEmpty && wall > 0
        let ratios = haveBaseline ? ProcessMath.cpuRatios(previous: previousCPU, current: samples, wallSeconds: wall) : [:]
        previousCPU = Dictionary(samples.map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: { _, last in last })
        previousTime = now

        publishAgents(samples, ratios: ratios, haveBaseline: haveBaseline)
        guard nameFilter.enabled else { return }
        publishTop(ProcessMath.summarize(samples, ratios: ratios), haveBaseline: haveBaseline)
    }

    private func publishTop(_ summaries: [String: ProcessSummary], haveBaseline: Bool) {
        let byCPU = haveBaseline ? ProcessMath.top(summaries, n: topN) { $0.cpuRatio } : []
        let byMemory = ProcessMath.top(summaries, n: topN) { $0.residentBytes }
        let shown = Set(byCPU + byMemory)

        cpuRatio?.reset()
        residentBytes?.reset()
        countByName?.reset()
        let cpu = nameFilter.labels(Dictionary(uniqueKeysWithValues: byCPU.compactMap { n in summaries[n].map { (n, $0.cpuRatio) } }))
        let memory = nameFilter.labels(Dictionary(uniqueKeysWithValues: byMemory.compactMap { n in summaries[n].map { (n, $0.residentBytes) } }))
        let counts = nameFilter.labels(Dictionary(uniqueKeysWithValues: shown.compactMap { n in summaries[n].map { (n, Double($0.count)) } }))
        for (label, value) in cpu { cpuRatio?.set(value, labels: ["name": label]) }
        for (label, value) in memory { residentBytes?.set(value, labels: ["name": label]) }
        for (label, value) in counts { countByName?.set(value, labels: ["name": label]) }
    }

    private func publishAgents(_ samples: [ProcessSample], ratios: [Int32: Double], haveBaseline: Bool) {
        var counts: [String: Double] = [:]
        var cpu: [String: Double] = [:]
        for agent in agents.keys { counts[agent] = 0; cpu[agent] = 0 }
        for sample in samples {
            for agent in AgentMatcher.matches(name: sample.name, agents: agents) {
                counts[agent, default: 0] += 1
                cpu[agent, default: 0] += ratios[sample.pid] ?? 0
            }
        }
        for (agent, n) in counts {
            agentProcesses?.set(n, labels: ["agent": agent])
            if haveBaseline { agentCPU?.set(cpu[agent] ?? 0, labels: ["agent": agent]) }
        }
    }

    // MARK: libproc

    static func sampleAll() -> [ProcessSample] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).compactMap { pid in
            pid > 0 ? sample(pid: pid) : nil
        }
    }

    /// Nil for processes we may not inspect (other users' and system daemons).
    private static func sample(pid: pid_t) -> ProcessSample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        guard let processName = displayName(pid: pid) else { return nil }
        let machTime = Double(info.pti_total_user) + Double(info.pti_total_system)
        return ProcessSample(pid: pid, name: processName,
                             cpuSeconds: machTime * timebase / nanosPerSecond,
                             residentBytes: Double(info.pti_resident_size))
    }

    private static func displayName(pid: pid_t) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        // proc_name truncates at 31 bytes; the executable path has the full name.
        if nameLength > 0, nameLength < truncatedNameLength {
            return String(cString: nameBuffer)
        }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            return nameLength > 0 ? String(cString: nameBuffer) : nil
        }
        let last = (String(cString: pathBuffer) as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }
}
