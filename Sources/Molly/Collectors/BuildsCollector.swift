import Foundation

// MARK: - Pure logic (unit-tested)

enum BuildMatcher {
    static let defaults: [String: [String]] = [
        "swift": ["swift-frontend", "swift-build", "swiftc"],
        "clang": ["clang", "clang-*", "cc1"],
        "xcodebuild": ["xcodebuild"],
        "cargo": ["cargo", "rustc"],
        "go": ["go", "compile", "link"],
        "node": ["tsc", "esbuild", "webpack", "vite"],
        "gradle": ["gradle"],
        "make": ["make", "gmake", "ninja", "cmake"],
        "docker": ["docker-buildx", "buildkit"],
        "python": ["pytest"],
        "jest": ["jest"],
    ]

    /// Config entries override the defaults per tool; an empty list turns a tool off.
    static func merged(config: [String: JSONValue]?) -> [String: [String]] {
        var tools = defaults
        for (tool, patterns) in config ?? [:] {
            tools[tool] = (patterns.arrayValue ?? []).compactMap { $0.stringValue }
        }
        return tools.filter { !$0.value.isEmpty }
    }

    /// Case-insensitive exact name match. A trailing `*` makes a prefix match
    /// ("clang-*" finds clang-17 but not clangd). Substrings would match
    /// long-running helpers such as language servers and daemons.
    static func matches(name: String, patterns: [String]) -> Bool {
        let lower = name.lowercased()
        return patterns.contains { pattern in
            let p = pattern.lowercased()
            return p.hasSuffix("*") ? lower.hasPrefix(p.dropLast()) : lower == p
        }
    }

    static func tools(for name: String, config: [String: [String]]) -> [String] {
        config.filter { matches(name: name, patterns: $0.value) }.keys.sorted()
    }
}

/// Turns per-tick process counts into build seconds and build starts.
struct BuildTracker: Equatable {
    struct Update: Equatable {
        var seconds: [String: Double] = [:]
        var started: [String] = []
    }

    private(set) var active: Set<String> = []

    /// `elapsed` is the time since the previous observation, credited to every
    /// tool that has a process now. A tool seen for the first time starts a build.
    mutating func observe(counts: [String: Int], elapsed: Double) -> Update {
        let present = Set(counts.filter { $0.value > 0 }.keys)
        var update = Update()
        for tool in present {
            update.seconds[tool] = max(0, elapsed)
            if !active.contains(tool) { update.started.append(tool) }
        }
        update.started.sort()
        active = present
        return update
    }

    var anyActive: Bool { !active.isEmpty }
}

enum XcodeLogs {
    struct Entry: Equatable {
        let path: String
        let modified: Date
    }

    /// Build logs modified after `cursor` that were not counted already. A log
    /// that Xcode keeps rewriting while a build runs is counted once.
    static func newBuilds(entries: [Entry], cursor: Date, counted: Set<String>) -> (fresh: [Entry], cursor: Date) {
        let fresh = entries.filter { $0.path.hasSuffix(".xcactivitylog") && $0.modified > cursor && !counted.contains($0.path) }
        return (fresh, max(cursor, fresh.map(\.modified).max() ?? cursor))
    }

    /// `du -sk` prints "<kilobytes>\t<path>".
    static func bytes(duOutput: String) -> Double? {
        let first = duOutput.split(whereSeparator: { $0 == "\t" || $0 == " " }).first
        return first.flatMap { Double($0) }.map { $0 * 1024 }
    }
}

// MARK: - Collector

/// Counts running build tools by process name and accumulates build time.
/// Also watches Xcode's DerivedData for finished build logs and its size.
final class BuildsCollector: Collector {
    let name = "builds"
    let interval: TimeInterval

    private static let duTimeout: TimeInterval = 20
    private static let cursorKey = "xcodeCursor"
    /// A tick this far apart means the machine slept; do not credit the gap as build time.
    private static let maxCreditedIntervals = 2.0

    private let tools: [String: [String]]
    private let xcodeEnabled: Bool
    private let derivedData: URL
    private let derivedDataSeconds: TimeInterval
    private let store: StateStore
    private let startedAt: Date

    private var processes: Gauge?
    private var seconds: Counter?
    private var builds: Counter?
    private var active: Gauge?
    private var cpu: Gauge?
    private var xcodeBuilds: Counter?
    private var derivedDataBytes: Gauge?

    private var tracker = BuildTracker()
    private var previousCPU: [Int32: Double] = [:]
    private var previousTime: Date?
    private var xcodeCursor: Date
    private var countedLogs = Set<String>()
    private var lastDerivedDataScan: Date = .distantPast
    private let duLock = NSLock()
    private var duRunning = false

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, startedAt: Date = Date()) {
        interval = settings.interval(default: 15)
        tools = BuildMatcher.merged(config: settings.raw["tools"]?.objectValue)
        xcodeEnabled = settings.bool("xcode", default: true)
        derivedData = URL(fileURLWithPath: Paths.expand(settings.string("derivedDataPath", default: "~/Library/Developer/Xcode/DerivedData")))
        derivedDataSeconds = max(60, settings.double("derivedDataSeconds", default: 1800))
        store = StateStore(collector: "builds", folder: stateFolder)
        self.startedAt = startedAt
        xcodeCursor = Date(timeIntervalSince1970: store.double(Self.cursorKey) ?? startedAt.timeIntervalSince1970)
    }

    func start(registry: MetricsRegistry) throws {
        processes = registry.gauge("molly_build_processes", help: "Running build or compile processes by tool.", labels: ["tool"])
        seconds = registry.counter("molly_build_seconds_total", help: "Seconds with at least one process of the tool running.", labels: ["tool"])
        builds = registry.counter("molly_builds_total", help: "Times a tool went from no processes to at least one.", labels: ["tool"])
        active = registry.gauge("molly_build_active", help: "1 when any build tool is running.")
        cpu = registry.gauge("molly_build_cpu_ratio", help: "CPU use of a tool's processes; 1.0 is one full core.", labels: ["tool"])
        xcodeBuilds = registry.counter("molly_xcode_builds_total", help: "Xcode build logs written since Molly started.")
        derivedDataBytes = registry.gauge("molly_xcode_derived_data_bytes", help: "Size of the Xcode DerivedData folder, refreshed every derivedDataSeconds.")
        for tool in tools.keys {
            seconds?.touch(labels: ["tool": tool])
            builds?.touch(labels: ["tool": tool])
        }
        xcodeBuilds?.touch()
    }

    func collect() throws {
        let now = Date()
        let samples = ProcessesCollector.sampleAll()
        guard !samples.isEmpty else { throw CollectorUnavailable(reason: "libproc returned no processes") }

        let elapsed = previousTime.map { min(now.timeIntervalSince($0), interval * Self.maxCreditedIntervals) } ?? 0
        let wall = previousTime.map { now.timeIntervalSince($0) } ?? 0
        let ratios = wall > 0 && !previousCPU.isEmpty
            ? ProcessMath.cpuRatios(previous: previousCPU, current: samples, wallSeconds: wall) : [:]
        previousCPU = Dictionary(samples.map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: { _, last in last })
        previousTime = now

        publishProcesses(samples, ratios: ratios, elapsed: elapsed)
        if xcodeEnabled { collectXcode(now: now) }
    }

    private func publishProcesses(_ samples: [ProcessSample], ratios: [Int32: Double], elapsed: Double) {
        var counts = Dictionary(uniqueKeysWithValues: tools.keys.map { ($0, 0) })
        var cpuByTool = Dictionary(uniqueKeysWithValues: tools.keys.map { ($0, 0.0) })
        for sample in samples {
            for tool in BuildMatcher.tools(for: sample.name, config: tools) {
                counts[tool, default: 0] += 1
                cpuByTool[tool, default: 0] += ratios[sample.pid] ?? 0
            }
        }
        let update = tracker.observe(counts: counts, elapsed: elapsed)
        for (tool, count) in counts {
            let label = ["tool": tool]
            processes?.set(count, labels: label)
            cpu?.set(cpuByTool[tool] ?? 0, labels: label)
            if let credited = update.seconds[tool] { seconds?.add(credited, labels: label) }
        }
        for tool in update.started { builds?.inc(labels: ["tool": tool]) }
        active?.set(tracker.anyActive ? 1 : 0)
    }

    // MARK: Xcode

    private func collectXcode(now: Date) {
        guard FileManager.default.fileExists(atPath: derivedData.path) else { return }
        countNewLogs()
        if now.timeIntervalSince(lastDerivedDataScan) >= derivedDataSeconds {
            lastDerivedDataScan = now
            measureDerivedData()
        }
    }

    private func countNewLogs() {
        let result = XcodeLogs.newBuilds(entries: buildLogs(), cursor: xcodeCursor, counted: countedLogs)
        guard !result.fresh.isEmpty else { return }
        xcodeBuilds?.add(Double(result.fresh.count))
        countedLogs.formUnion(result.fresh.map(\.path))
        xcodeCursor = result.cursor
        store.set(Self.cursorKey, xcodeCursor.timeIntervalSince1970)
        do { try store.save() } catch { Log.warn("builds: cannot save state: \(error)") }
    }

    private func buildLogs() -> [XcodeLogs.Entry] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil)) ?? []
        var entries: [XcodeLogs.Entry] = []
        for project in projects {
            let logs = project.appendingPathComponent("Logs/Build")
            let files = (try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "xcactivitylog" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                entries.append(XcodeLogs.Entry(path: file.path, modified: modified))
            }
        }
        return entries
    }

    /// `du` on a large DerivedData can take many seconds, so it runs off the collector queue.
    private func measureDerivedData() {
        duLock.lock()
        let alreadyRunning = duRunning
        duRunning = true
        duLock.unlock()
        guard !alreadyRunning else { return }
        let path = derivedData.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                self?.duLock.lock()
                self?.duRunning = false
                self?.duLock.unlock()
            }
            do {
                let result = try Shell.run("/usr/bin/du", ["-sk", path], timeout: Self.duTimeout)
                if let bytes = XcodeLogs.bytes(duOutput: result.stdout) { self?.derivedDataBytes?.set(bytes) }
            } catch {
                Log.warn("builds: du failed: \(error)")
            }
        }
    }
}
