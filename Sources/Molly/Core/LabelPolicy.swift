import Foundation

/// How one potentially sensitive label dimension (domains, app names, repo
/// names, ...) is handled. Every such dimension in Molly is governed by a
/// policy; the default for anything sensitive is `enabled: false`.
struct LabelPolicy: Equatable {
    enum Mode: String { case allowlist, denylist }

    static let other = "other"
    static let redacted = "redacted"

    var enabled: Bool
    var mode: Mode
    var patterns: [String]
    var hash: Bool
    var salt: String
    var maxCardinality: Int

    init(enabled: Bool = false, mode: Mode = .denylist, patterns: [String] = [],
         hash: Bool = false, salt: String = "", maxCardinality: Int = 0) {
        self.enabled = enabled
        self.mode = mode
        self.patterns = patterns
        self.hash = hash
        self.salt = salt
        self.maxCardinality = maxCardinality
    }

    /// Reads a policy object from config. Missing keys keep the defaults
    /// passed in, so a collector can ship "enabled by default" dimensions.
    static func from(_ json: JSONValue?, defaults: LabelPolicy = LabelPolicy()) throws -> LabelPolicy {
        guard let json else { return defaults }
        guard let object = json.objectValue else {
            throw ConfigError.invalid("label policy must be an object")
        }
        var policy = defaults
        if let v = object["enabled"] {
            guard let b = v.boolValue else { throw ConfigError.invalid("enabled must be a boolean") }
            policy.enabled = b
        }
        if let v = object["mode"] {
            guard let s = v.stringValue, let mode = Mode(rawValue: s) else {
                throw ConfigError.invalid("mode must be \"allowlist\" or \"denylist\"")
            }
            policy.mode = mode
        }
        if let v = object["patterns"] {
            guard let a = v.arrayValue else { throw ConfigError.invalid("patterns must be an array") }
            policy.patterns = try a.map {
                guard let s = $0.stringValue else { throw ConfigError.invalid("patterns must be strings") }
                return s
            }
        }
        if let v = object["hash"] {
            guard let b = v.boolValue else { throw ConfigError.invalid("hash must be a boolean") }
            policy.hash = b
        }
        if let v = object["salt"] {
            guard let s = v.stringValue else { throw ConfigError.invalid("salt must be a string") }
            policy.salt = s
        }
        if let v = object["maxCardinality"] {
            guard let n = v.intValue, n >= 0 else { throw ConfigError.invalid("maxCardinality must be >= 0") }
            policy.maxCardinality = n
        }
        return policy
    }

    func compile() throws -> LabelFilter { try LabelFilter(policy: self) }
}

/// A compiled LabelPolicy. Collectors call `label(_:)` for every raw value
/// before it becomes a Prometheus label.
final class LabelFilter {
    let policy: LabelPolicy
    /// Audit name ("<collector>.<key>"); nil for ad-hoc filters in tests.
    let dimension: String?
    private let matchers: [NSRegularExpression]

    /// A filter that exposes nothing.
    static let disabled = try! LabelFilter(policy: LabelPolicy(enabled: false))

    init(policy: LabelPolicy, dimension: String? = nil) throws {
        self.policy = policy
        self.dimension = dimension
        self.matchers = try policy.patterns.map(LabelFilter.compile)
    }

    var enabled: Bool { policy.enabled }
    var maxCardinality: Int { policy.maxCardinality }

    func matches(_ value: String) -> Bool {
        let v = normalize(value)
        let range = NSRange(v.startIndex..., in: v)
        return matchers.contains { $0.firstMatch(in: v, range: range) != nil }
    }

    /// Allowlist: non-matching values become "other". Denylist: matching values
    /// become "redacted". Values that pass are optionally replaced by a salted
    /// hash so dashboards can still distinguish them without naming them.
    func label(_ value: String) -> String {
        let (result, outcome) = decide(value)
        if let dimension { PrivacyAudit.shared.record(dimension: dimension, outcome: outcome) }
        return result
    }

    private func decide(_ value: String) -> (String, PrivacyAudit.Outcome) {
        guard enabled else { return (LabelPolicy.redacted, .redacted) }
        let v = normalize(value)
        if v.isEmpty { return (LabelPolicy.other, .other) }
        let matched = matches(v)
        switch policy.mode {
        case .allowlist where !matched: return (LabelPolicy.other, .other)
        case .denylist where matched: return (LabelPolicy.redacted, .redacted)
        default: break
        }
        return policy.hash ? (LabelFilter.hash(v, salt: policy.salt), .hashed) : (v, .passed)
    }

    /// Applies `label` to a map of counts, merging collisions and folding
    /// anything beyond `maxCardinality` into "other".
    func labels(_ counts: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (raw, n) in counts {
            out[label(raw), default: 0] += n
        }
        return LabelFilter.topN(out, maxCardinality)
    }

    /// Keeps the n largest entries and folds the rest into "other". n <= 0 keeps all.
    static func topN(_ counts: [String: Double], _ n: Int) -> [String: Double] {
        guard n > 0, counts.count > n else { return counts }
        let ranked = counts
            .filter { $0.key != LabelPolicy.other && $0.key != LabelPolicy.redacted }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var out: [String: Double] = [:]
        if let redacted = counts[LabelPolicy.redacted] { out[LabelPolicy.redacted] = redacted }
        var other = counts[LabelPolicy.other] ?? 0
        for (index, entry) in ranked.enumerated() {
            if index < n {
                out[entry.key] = entry.value
            } else {
                other += entry.value
            }
        }
        if other > 0 { out[LabelPolicy.other] = other }
        return out
    }

    static func hash(_ value: String, salt: String) -> String {
        "h_" + SHA256.hexPrefix(of: salt + value, bytes: 6)
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// "*" matches any run of characters. A pattern without a wildcard also
    /// matches as a dotted suffix, so "example.com" covers "www.example.com".
    private static func compile(_ pattern: String) throws -> NSRegularExpression {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty else { throw ConfigError.invalid("empty pattern in label policy") }
        var regex = "^"
        if !p.contains("*") { regex += "(.*\\.)?" }
        regex += p.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
        regex += "$"
        return try NSRegularExpression(pattern: regex, options: [])
    }
}
