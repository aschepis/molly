import Foundation

/// Records, per sensitive label dimension, how many raw values passed, were
/// folded to "other", were redacted, or were hashed. Only counts are kept;
/// a raw value never enters this type. `/privacy` and `molly privacy` read it.
final class PrivacyAudit {
    static let shared = PrivacyAudit()

    enum Outcome: String, CaseIterable {
        case passed, other, redacted, hashed
    }

    struct Dimension {
        let name: String
        let collector: String
        let key: String
        var policy: LabelPolicy
        var counts: [Outcome: Int]
    }

    private var dimensions: [String: Dimension] = [:]
    private var counter: Counter?
    private let lock = NSLock()

    /// Registers (or re-registers after a config reload) a dimension. Counts
    /// survive re-registration so a reload does not hide earlier decisions.
    func register(dimension name: String, collector: String, key: String, policy: LabelPolicy) {
        lock.lock()
        defer { lock.unlock() }
        if var existing = dimensions[name] {
            existing.policy = policy
            dimensions[name] = existing
        } else {
            dimensions[name] = Dimension(name: name, collector: collector, key: key, policy: policy, counts: [:])
        }
    }

    func record(dimension name: String, outcome: Outcome) {
        lock.lock()
        if var d = dimensions[name] {
            d.counts[outcome, default: 0] += 1
            dimensions[name] = d
        } else {
            dimensions[name] = Dimension(name: name, collector: name, key: "", policy: LabelPolicy(), counts: [outcome: 1])
        }
        let counter = self.counter
        lock.unlock()
        counter?.inc(labels: ["dimension": name, "outcome": outcome.rawValue])
    }

    /// Publishes decisions as `molly_privacy_label_decisions_total`.
    func attach(registry: MetricsRegistry) {
        let c = registry.counter("molly_privacy_label_decisions_total",
                                 help: "Label values that passed, were folded to other, redacted, or hashed, per dimension.",
                                 labels: ["dimension", "outcome"])
        lock.lock()
        counter = c
        let known = Array(dimensions.keys)
        lock.unlock()
        for name in known {
            for outcome in Outcome.allCases { c.touch(labels: ["dimension": name, "outcome": outcome.rawValue]) }
        }
    }

    func snapshot() -> [Dimension] {
        lock.lock()
        defer { lock.unlock() }
        return dimensions.values.sorted { $0.name < $1.name }
    }

    /// Tests only.
    func reset() {
        lock.lock()
        dimensions.removeAll()
        counter = nil
        lock.unlock()
    }

    /// JSON-ready description with policy details but never the patterns
    /// themselves (those are in `/config`) and never raw values.
    func report(constLabels: [String: String], collectorsOn: [String], disabledByDefault: Set<String>) -> [String: Any] {
        let dims = snapshot().map { d -> [String: Any] in
            [
                "dimension": d.name,
                "collector": d.collector,
                "key": d.key,
                "enabled": d.policy.enabled,
                "policy": [
                    "enabled": d.policy.enabled,
                    "mode": d.policy.mode.rawValue,
                    "patternCount": d.policy.patterns.count,
                    "hash": d.policy.hash,
                    "maxCardinality": d.policy.maxCardinality,
                ],
                "counts": Dictionary(uniqueKeysWithValues: Outcome.allCases.map { ($0.rawValue, d.counts[$0] ?? 0) }),
            ]
        }
        let sensitive = disabledByDefault.sorted().map { name -> [String: Any] in
            ["collector": name, "defaultEnabled": false, "enabled": collectorsOn.contains(name)]
        }
        return [
            "constLabels": constLabels,
            "dimensions": dims,
            "sensitiveCollectors": sensitive,
        ]
    }
}
