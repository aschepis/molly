import Foundation

/// A tiny Prometheus client: gauges and counters with labels, rendered in the
/// text exposition format. Thread-safe; collectors update from any queue.
enum Metrics {
    static let namePattern = try! NSRegularExpression(pattern: "^[a-zA-Z_:][a-zA-Z0-9_:]*$")
    static let labelPattern = try! NSRegularExpression(pattern: "^[a-zA-Z_][a-zA-Z0-9_]*$")

    static func isValidMetricName(_ name: String) -> Bool {
        namePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func isValidLabelName(_ name: String) -> Bool {
        !name.hasPrefix("__")
            && labelPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func escapeLabelValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func escapeHelp(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func format(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == .infinity { return "+Inf" }
        if value == -.infinity { return "-Inf" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}

enum MetricType: String {
    case gauge, counter
}

struct LabelValues: Hashable {
    let values: [String]
}

/// One named metric with all its labeled children.
final class MetricFamily {
    let name: String
    let help: String
    let type: MetricType
    let labelNames: [String]
    private(set) var children: [LabelValues: Double] = [:]
    private let lock = NSLock()

    init(name: String, help: String, type: MetricType, labelNames: [String]) {
        self.name = name
        self.help = help
        self.type = type
        self.labelNames = labelNames
    }

    fileprivate func values(for labels: [String: String]) -> LabelValues {
        precondition(labels.count == labelNames.count,
                     "\(name): expected labels \(labelNames), got \(Array(labels.keys))")
        return LabelValues(values: labelNames.map { name in
            guard let v = labels[name] else {
                preconditionFailure("\(self.name): missing label \(name)")
            }
            return v
        })
    }

    fileprivate func set(_ value: Double, labels: [String: String]) {
        let key = values(for: labels)
        lock.lock()
        children[key] = value
        lock.unlock()
    }

    fileprivate func add(_ delta: Double, labels: [String: String]) {
        let key = values(for: labels)
        lock.lock()
        children[key, default: 0] += delta
        lock.unlock()
    }

    fileprivate func remove(labels: [String: String]) {
        let key = values(for: labels)
        lock.lock()
        children.removeValue(forKey: key)
        lock.unlock()
    }

    fileprivate func reset() {
        lock.lock()
        children.removeAll()
        lock.unlock()
    }

    fileprivate func get(labels: [String: String]) -> Double? {
        let key = values(for: labels)
        lock.lock()
        defer { lock.unlock() }
        return children[key]
    }

    fileprivate func snapshot() -> [(LabelValues, Double)] {
        lock.lock()
        defer { lock.unlock() }
        return children.sorted { $0.key.values.lexicographicallyPrecedes($1.key.values) }
    }

    fileprivate func stats() -> FamilyStats {
        lock.lock()
        defer { lock.unlock() }
        var distinct: [String: Set<String>] = [:]
        for key in children.keys {
            for (i, label) in labelNames.enumerated() {
                distinct[label, default: []].insert(key.values[i])
            }
        }
        return FamilyStats(name: name, type: type, series: children.count,
                           labelCardinality: distinct.mapValues { $0.count })
    }
}

/// Size of one metric family: how many series it holds and how many distinct
/// values each label has. Used by `/stats` and `molly tune`.
struct FamilyStats: Equatable {
    let name: String
    let type: MetricType
    let series: Int
    let labelCardinality: [String: Int]
}

/// A gauge can go up and down. `reset()` drops every child so a collector that
/// publishes "current state" (which app is focused) does not leave stale series.
final class Gauge {
    fileprivate let family: MetricFamily
    fileprivate init(family: MetricFamily) { self.family = family }

    func set(_ value: Double, labels: [String: String] = [:]) { family.set(value, labels: labels) }
    func set(_ value: Int, labels: [String: String] = [:]) { family.set(Double(value), labels: labels) }
    func add(_ delta: Double, labels: [String: String] = [:]) { family.add(delta, labels: labels) }
    func remove(labels: [String: String] = [:]) { family.remove(labels: labels) }
    func reset() { family.reset() }
    func value(labels: [String: String] = [:]) -> Double? { family.get(labels: labels) }

    /// Replaces all children with the given map (one label dimension).
    func replaceAll(_ values: [String: Double], label: String) {
        reset()
        for (k, v) in values { set(v, labels: [label: k]) }
    }
}

/// A counter only goes up. Collectors that re-derive totals from an external
/// source (a history database) should keep a cursor and call `add` with deltas.
final class Counter {
    fileprivate let family: MetricFamily
    fileprivate init(family: MetricFamily) { self.family = family }

    func inc(labels: [String: String] = [:]) { add(1, labels: labels) }
    func add(_ delta: Double, labels: [String: String] = [:]) {
        precondition(delta >= 0, "\(family.name): counters cannot decrease")
        family.add(delta, labels: labels)
    }
    func value(labels: [String: String] = [:]) -> Double? { family.get(labels: labels) }
    /// Ensures a zero sample exists so rate() has a baseline.
    func touch(labels: [String: String] = [:]) { family.add(0, labels: labels) }
}

final class MetricsRegistry {
    private var families: [String: MetricFamily] = [:]
    private let lock = NSLock()
    let constLabels: [String: String]

    init(constLabels: [String: String] = [:]) {
        for name in constLabels.keys {
            precondition(Metrics.isValidLabelName(name), "bad const label name \(name)")
        }
        self.constLabels = constLabels
    }

    func gauge(_ name: String, help: String, labels: [String] = []) -> Gauge {
        Gauge(family: family(name, help: help, type: .gauge, labelNames: labels))
    }

    func counter(_ name: String, help: String, labels: [String] = []) -> Counter {
        Counter(family: family(name, help: help, type: .counter, labelNames: labels))
    }

    /// Registering the same name twice returns the existing family; it must
    /// have the same type and label names, anything else is a programming error.
    private func family(_ name: String, help: String, type: MetricType, labelNames: [String]) -> MetricFamily {
        precondition(Metrics.isValidMetricName(name), "bad metric name \(name)")
        for label in labelNames {
            precondition(Metrics.isValidLabelName(label), "\(name): bad label name \(label)")
            precondition(constLabels[label] == nil, "\(name): label \(label) collides with a const label")
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = families[name] {
            precondition(existing.type == type && existing.labelNames == labelNames,
                         "\(name) re-registered with different type or labels")
            return existing
        }
        let f = MetricFamily(name: name, help: help, type: type, labelNames: labelNames)
        families[name] = f
        return f
    }

    var familyNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return families.keys.sorted()
    }

    /// Per-family sizes, sorted by name. Families with no series are included
    /// with zero so a dashboard can tell "registered" from "populated".
    func stats() -> [FamilyStats] {
        lock.lock()
        let all = families.values.sorted { $0.name < $1.name }
        lock.unlock()
        return all.map { $0.stats() }
    }

    /// Prometheus text exposition format, version 0.0.4.
    func render() -> String {
        lock.lock()
        let all = families.values.sorted { $0.name < $1.name }
        lock.unlock()

        let constPairs = constLabels.sorted { $0.key < $1.key }
            .map { "\($0.key)=\"\(Metrics.escapeLabelValue($0.value))\"" }
        var out = ""
        for family in all {
            let samples = family.snapshot()
            guard !samples.isEmpty else { continue }
            out += "# HELP \(family.name) \(Metrics.escapeHelp(family.help))\n"
            out += "# TYPE \(family.name) \(family.type.rawValue)\n"
            for (labels, value) in samples {
                var pairs = constPairs
                for (i, labelName) in family.labelNames.enumerated() {
                    pairs.append("\(labelName)=\"\(Metrics.escapeLabelValue(labels.values[i]))\"")
                }
                let labelText = pairs.isEmpty ? "" : "{" + pairs.joined(separator: ",") + "}"
                out += "\(family.name)\(labelText) \(Metrics.format(value))\n"
            }
        }
        return out
    }
}
