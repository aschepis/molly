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
    case gauge, counter, histogram
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

/// Fixed-bucket histogram. Buckets are chosen up front so series stay mergeable
/// across restarts and hosts; `le` is added after the registry's const labels.
final class Histogram {
    let name: String
    let help: String
    let labelNames: [String]
    let buckets: [Double]
    private struct Series {
        var bucketCounts: [Double]
        var sum = 0.0
        var count = 0.0
    }
    private var children: [LabelValues: Series] = [:]
    private let lock = NSLock()

    fileprivate init(name: String, help: String, labelNames: [String], buckets: [Double]) {
        precondition(!buckets.isEmpty && buckets == buckets.sorted() && Set(buckets).count == buckets.count,
                     "\(name): buckets must be ascending and unique")
        precondition(!labelNames.contains("le"), "\(name): le is reserved for histogram buckets")
        self.name = name
        self.help = help
        self.labelNames = labelNames
        self.buckets = buckets
    }

    func observe(_ value: Double, labels: [String: String] = [:]) {
        precondition(labels.count == labelNames.count, "\(name): expected labels \(labelNames), got \(Array(labels.keys))")
        let key = LabelValues(values: labelNames.map { labels[$0] ?? "" })
        // The last slot is the +Inf bucket, so a value above every bound still counts.
        let slot = buckets.firstIndex { value <= $0 } ?? buckets.count
        lock.lock()
        defer { lock.unlock() }
        var series = children[key] ?? Series(bucketCounts: Array(repeating: 0, count: buckets.count + 1))
        series.bucketCounts[slot] += 1
        series.sum += value
        series.count += 1
        children[key] = series
    }

    func count(labels: [String: String] = [:]) -> Double? {
        let key = LabelValues(values: labelNames.map { labels[$0] ?? "" })
        lock.lock()
        defer { lock.unlock() }
        return children[key]?.count
    }

    fileprivate func render(constPairs: [String]) -> String {
        lock.lock()
        let all = children.sorted { $0.key.values.lexicographicallyPrecedes($1.key.values) }
        lock.unlock()
        guard !all.isEmpty else { return "" }
        var out = "# HELP \(name) \(Metrics.escapeHelp(help))\n# TYPE \(name) histogram\n"
        for (labels, series) in all {
            var pairs = constPairs
            for (i, labelName) in labelNames.enumerated() {
                pairs.append("\(labelName)=\"\(Metrics.escapeLabelValue(labels.values[i]))\"")
            }
            var cumulative = 0.0
            for (i, bound) in (buckets + [.infinity]).enumerated() {
                cumulative += series.bucketCounts[i]
                let bucketLabels = (pairs + ["le=\"\(Metrics.format(bound))\""]).joined(separator: ",")
                out += "\(name)_bucket{\(bucketLabels)} \(Metrics.format(cumulative))\n"
            }
            let labelText = pairs.isEmpty ? "" : "{" + pairs.joined(separator: ",") + "}"
            out += "\(name)_sum\(labelText) \(Metrics.format(series.sum))\n"
            out += "\(name)_count\(labelText) \(Metrics.format(series.count))\n"
        }
        return out
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
        // Each child exposes one series per bucket plus _sum and _count.
        return FamilyStats(name: name, type: .histogram, series: children.count * (buckets.count + 3),
                           labelCardinality: distinct.mapValues { $0.count })
    }
}

final class MetricsRegistry {
    private var families: [String: MetricFamily] = [:]
    private var histograms: [String: Histogram] = [:]
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

    func histogram(_ name: String, help: String, labels: [String] = [], buckets: [Double]) -> Histogram {
        precondition(Metrics.isValidMetricName(name), "bad metric name \(name)")
        for label in labels {
            precondition(Metrics.isValidLabelName(label), "\(name): bad label name \(label)")
            precondition(constLabels[label] == nil, "\(name): label \(label) collides with a const label")
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = histograms[name] {
            precondition(existing.labelNames == labels && existing.buckets == buckets,
                         "\(name) re-registered with different labels or buckets")
            return existing
        }
        let h = Histogram(name: name, help: help, labelNames: labels, buckets: buckets)
        histograms[name] = h
        return h
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
        return (Array(families.keys) + Array(histograms.keys)).sorted()
    }

    /// Per-family sizes, sorted by name. Families with no series are included
    /// with zero so a dashboard can tell "registered" from "populated".
    func stats() -> [FamilyStats] {
        lock.lock()
        let all = families.values.sorted { $0.name < $1.name }
        let hists = histograms.values
        lock.unlock()
        return (all.map { $0.stats() } + hists.map { $0.stats() }).sorted { $0.name < $1.name }
    }

    /// Prometheus text exposition format, version 0.0.4.
    func render() -> String {
        lock.lock()
        let all = families.values.sorted { $0.name < $1.name }
        let hists = histograms.values.sorted { $0.name < $1.name }
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
        for histogram in hists { out += histogram.render(constPairs: constPairs) }
        return out
    }
}
