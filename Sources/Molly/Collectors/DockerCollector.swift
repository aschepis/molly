import Foundation

// MARK: - Pure parsers (unit-tested)

struct DockerContainer: Equatable {
    let name: String
    let image: String
    let state: String
}

struct DockerStat: Equatable {
    let name: String
    let cpuRatio: Double
    let memoryBytes: Double
}

enum DockerParse {
    /// `docker ... --format '{{json .}}'` prints one JSON object per line.
    static func jsonLines(_ text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object
        }
    }

    static func containers(_ text: String) -> [DockerContainer] {
        jsonLines(text).compactMap { row in
            guard let name = row["Names"] as? String else { return nil }
            let status = (row["Status"] as? String) ?? ""
            return DockerContainer(name: name, image: (row["Image"] as? String) ?? "",
                                   state: normalizedState(row["State"] as? String, status: status))
        }
    }

    /// Older engines omit State; "Up ... (Paused)" and "Exited (0) ..." are the fallbacks.
    static func normalizedState(_ state: String?, status: String) -> String {
        if let state, !state.isEmpty { return state.lowercased() }
        let s = status.lowercased()
        if s.contains("paused") { return "paused" }
        if s.hasPrefix("up") { return "running" }
        if s.hasPrefix("exited") { return "exited" }
        if s.hasPrefix("created") { return "created" }
        return "unknown"
    }

    static func countByState(_ containers: [DockerContainer]) -> [String: Int] {
        var counts = ["running": 0, "exited": 0, "paused": 0, "created": 0]
        for c in containers { counts[c.state, default: 0] += 1 }
        return counts
    }

    /// Distinct non-empty lines, so an image with several tags counts once.
    static func distinctLineCount(_ text: String) -> Int {
        Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).count
    }

    /// "12.34%" -> 0.1234. Nil for "--" and other non-numbers.
    static func percentRatio(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("%"), let v = Double(trimmed.dropLast()) else { return nil }
        return v / 100
    }

    private static let units: [String: Double] = [
        "b": 1,
        "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
        "kib": 1024, "mib": 1024 * 1024, "gib": 1024 * 1024 * 1024, "tib": 1024 * 1024 * 1024 * 1024,
    ]

    /// "1.2GiB" -> bytes.
    static func byteCount(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let split = t.firstIndex(where: { !($0.isNumber || $0 == ".") }),
              let value = Double(t[..<split]),
              let factor = units[t[split...].trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
        return value * factor
    }

    /// "1.2GiB / 16GiB" -> bytes in use (the left half).
    static func memoryUsage(_ text: String) -> Double? {
        guard let used = text.split(separator: "/").first else { return nil }
        return byteCount(String(used))
    }

    static func stats(_ text: String) -> [DockerStat] {
        jsonLines(text).compactMap { row in
            guard let name = row["Name"] as? String,
                  let cpu = (row["CPUPerc"] as? String).flatMap(percentRatio),
                  let mem = (row["MemUsage"] as? String).flatMap(memoryUsage) else { return nil }
            return DockerStat(name: name, cpuRatio: cpu, memoryBytes: mem)
        }
    }
}

// MARK: - Collector

/// Container, image and volume counts from the docker CLI. Reports
/// `molly_docker_available 0` and becomes unavailable when there is no CLI or
/// the daemon is not running (Docker Desktop quit).
final class DockerCollector: Collector {
    static let containersDefaults = LabelPolicy(enabled: true, mode: .denylist)
    let name = "docker"
    let interval: TimeInterval

    private static let commandTimeout: TimeInterval = 15
    private static let statsTimeout: TimeInterval = 30

    private let containerFilter: LabelFilter
    private let statsEnabled: Bool
    private let pathOverride: String

    private var available: Gauge?
    private var containers: Gauge?
    private var info: Gauge?
    private var images: Gauge?
    private var volumes: Gauge?
    private var cpu: Gauge?
    private var memory: Gauge?

    init(settings: CollectorSettings) throws {
        interval = settings.interval(default: 60)
        containerFilter = try settings.filter("containers", defaults: DockerCollector.containersDefaults)
        statsEnabled = settings.bool("stats", default: false)
        pathOverride = settings.string("path", default: "")
    }

    func start(registry r: MetricsRegistry) throws {
        available = r.gauge("molly_docker_available", help: "1 when the docker CLI and daemon respond.")
        containers = r.gauge("molly_docker_containers", help: "Containers by state.", labels: ["state"])
        info = r.gauge("molly_docker_container_info", help: "One series per container.", labels: ["name", "image"])
        images = r.gauge("molly_docker_images", help: "Distinct local images.")
        volumes = r.gauge("molly_docker_volumes", help: "Local volumes.")
        cpu = r.gauge("molly_docker_container_cpu_ratio", help: "Container CPU use; 1.0 is one full core. Needs stats: true.", labels: ["name"])
        memory = r.gauge("molly_docker_container_memory_bytes", help: "Container memory in use. Needs stats: true.", labels: ["name"])
        available?.set(0)
    }

    func collect() throws {
        guard let docker = dockerPath() else {
            markUnavailable()
            throw CollectorUnavailable(reason: "docker CLI not found")
        }
        let ps: ShellResult
        do {
            ps = try Shell.run(docker, ["ps", "-a", "--format", "{{json .}}"], timeout: Self.commandTimeout)
        } catch {
            markUnavailable()
            throw CollectorUnavailable(reason: "docker not responding: \(error)")
        }
        guard ps.succeeded else {
            markUnavailable()
            throw CollectorUnavailable(reason: "docker daemon not running")
        }
        available?.set(1)

        let all = DockerParse.containers(ps.stdout)
        for (state, n) in DockerParse.countByState(all) { containers?.set(Double(n), labels: ["state": state]) }
        publishInfo(all)
        try publishCounts(docker)
        if statsEnabled { try publishStats(docker) }
    }

    private func dockerPath() -> String? {
        if !pathOverride.isEmpty { return Paths.expand(pathOverride) }
        return Shell.which("docker")
    }

    private func markUnavailable() {
        available?.set(0)
        for gauge in [containers, info, cpu, memory] { gauge?.reset() }
    }

    private func publishInfo(_ all: [DockerContainer]) {
        info?.reset()
        guard containerFilter.enabled else { return }
        for c in all {
            info?.set(1, labels: ["name": containerFilter.label(c.name), "image": containerFilter.label(c.image)])
        }
    }

    private func publishCounts(_ docker: String) throws {
        let imageList = try Shell.run(docker, ["images", "-q", "--no-trunc"], timeout: Self.commandTimeout)
        if imageList.succeeded { images?.set(Double(DockerParse.distinctLineCount(imageList.stdout))) }
        let volumeList = try Shell.run(docker, ["volume", "ls", "-q"], timeout: Self.commandTimeout)
        if volumeList.succeeded { volumes?.set(Double(DockerParse.distinctLineCount(volumeList.stdout))) }
    }

    private func publishStats(_ docker: String) throws {
        let result = try Shell.run(docker, ["stats", "--no-stream", "--format", "{{json .}}"], timeout: Self.statsTimeout)
        guard result.succeeded else { return }
        cpu?.reset()
        memory?.reset()
        guard containerFilter.enabled else { return }
        for stat in DockerParse.stats(result.stdout) {
            let labels = ["name": containerFilter.label(stat.name)]
            cpu?.set(stat.cpuRatio, labels: labels)
            memory?.set(stat.memoryBytes, labels: labels)
        }
    }
}
