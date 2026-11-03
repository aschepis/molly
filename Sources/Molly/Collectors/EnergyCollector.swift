import AppKit
import Foundation

// MARK: - Pure helpers (unit-tested)

struct EnergyRow: Equatable {
    let pid: Int32
    /// top truncates this to 16 characters; it is only a fallback name.
    let command: String
    let impact: Double
}

enum EnergyParse {
    private static let headerPrefix = "PID"

    /// Rows of the second sample in `top -l 2 -stats pid,command,power`. The first
    /// sample has no interval to measure over and reads zero, so it is skipped.
    static func rows(_ text: String) -> [EnergyRow] {
        var headers = 0
        var out: [EnergyRow] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(headerPrefix) { headers += 1; continue }
            guard headers >= 2, let row = row(String(line)) else { continue }
            out.append(row)
        }
        return out
    }

    /// The command may contain spaces, so only the first and last fields are fixed.
    static func row(_ line: String) -> EnergyRow? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3, let pid = Int32(fields[0]),
              let impact = Double(fields[fields.count - 1]), impact >= 0 else { return nil }
        return EnergyRow(pid: pid, command: fields[1..<(fields.count - 1)].joined(separator: " "), impact: impact)
    }
}

enum EnergyMath {
    /// Sums rows that share a name; Chrome and Electron apps run dozens of helpers.
    static func byName(_ rows: [EnergyRow], name: (EnergyRow) -> String) -> [String: Double] {
        var out: [String: Double] = [:]
        for row in rows { out[name(row), default: 0] += row.impact }
        return out
    }

    static func top(_ values: [String: Double], n: Int) -> [String: Double] {
        let ranked = values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return Dictionary(uniqueKeysWithValues: ranked.prefix(n).map { ($0.key, $0.value) })
    }
}

// MARK: - Collector

/// Energy impact per process from `top`, which reports it without root.
final class EnergyCollector: Collector {
    static let processesDefaults = LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 25)
    let name = "energy"
    let interval: TimeInterval

    private let filter: LabelFilter
    private let topN: Int

    private var impact: Gauge?
    private var impactByApp: Gauge?
    private var total: Gauge?

    private static let topPath = "/usr/bin/top"
    private static let timeout: TimeInterval = 15
    private static let sampleDelaySeconds = "1"

    init(settings: CollectorSettings) throws {
        interval = settings.interval(default: 30)
        filter = try settings.filter("processes", defaults: EnergyCollector.processesDefaults)
        topN = max(1, settings.int("topN", default: 15))
    }

    func start(registry: MetricsRegistry) throws {
        impact = registry.gauge("molly_energy_impact", help: "Energy impact of the top processes by name, as top reports it.", labels: ["process"])
        impactByApp = registry.gauge("molly_energy_impact_by_app", help: "Energy impact of the top applications; helpers without an app count under their process name.", labels: ["app"])
        total = registry.gauge("molly_energy_impact_total", help: "Energy impact summed over every process, not only the top N.")
    }

    func collect() throws {
        let result = try Shell.run(Self.topPath, ["-l", "2", "-s", Self.sampleDelaySeconds, "-stats", "pid,command,power", "-o", "power"],
                                   timeout: Self.timeout)
        guard result.succeeded else {
            throw NSError(domain: "molly.energy", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "top exited \(result.status): \(result.stderr.prefix(200))"])
        }
        let rows = EnergyParse.rows(result.stdout)
        guard !rows.isEmpty else {
            throw NSError(domain: "molly.energy", code: 0, userInfo: [NSLocalizedDescriptionKey: "no process rows in top output"])
        }

        total?.set(rows.reduce(0) { $0 + $1.impact })
        guard filter.enabled else { return }

        let names = Dictionary(rows.map { ($0.pid, Self.fullName($0)) }, uniquingKeysWith: { first, _ in first })
        let byProcess = EnergyMath.byName(rows) { names[$0.pid] ?? $0.command }
        let byApp = EnergyMath.byName(rows) { Self.appName(pid: $0.pid) ?? names[$0.pid] ?? $0.command }
        publish(impact, EnergyMath.top(byProcess, n: topN), label: "process")
        publish(impactByApp, EnergyMath.top(byApp, n: topN), label: "app")
    }

    private func publish(_ gauge: Gauge?, _ values: [String: Double], label: String) {
        gauge?.reset()
        for (name, value) in filter.labels(values) { gauge?.set(value, labels: [label: name]) }
    }

    private static func fullName(_ row: EnergyRow) -> String {
        ProcessesCollector.displayName(pid: row.pid) ?? row.command
    }

    /// Only regular (Dock) apps; helpers and agents keep their process name.
    private static func appName(pid: Int32) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
        return app.localizedName
    }
}
