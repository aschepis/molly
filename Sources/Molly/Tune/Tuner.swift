import Foundation

/// Everything `molly tune` looks at, gathered by the command so the rules
/// themselves are pure and testable.
struct TuneInput {
    struct CollectorStatus {
        let name: String
        let interval: TimeInterval
        let runs: Int
        let errors: Int
        let lastError: String?
        let lastDuration: TimeInterval
        let unavailable: Bool
        let unavailableSince: Date?
    }

    /// Facts about the machine that rule 7 compares against the config.
    struct Environment {
        var codexSessionsExist = false
        var mailIndexExists = false
        var accessibilityTrusted = false
        var browsersRunning = false
    }

    struct PrivacyCount {
        let collector: String
        let policy: String
        let other: Int
        let redacted: Int
    }

    var families: [FamilyStats]
    var collectors: [CollectorStatus]
    var config: Config
    var scrapeDuration: Double?
    var scrapeSamples: Double?
    var privacy: [PrivacyCount] = []
    var environment = Environment()
    var now = Date()
}

struct Recommendation: Equatable {
    enum Severity: String { case info, warn }
    let severity: Severity
    let collector: String?
    let title: String
    let why: String
    /// Fragment to deep-merge into config.json, or nil when the fix is manual.
    let configPatch: JSONValue?
}

enum Tuner {
    static let seriesBudget = 5000
    static let scrapeBudgetSeconds = 2.0
    static let unavailableGrace: TimeInterval = 3600
    static let errorRateLimit = 0.2
    static let cardinalityLimit = 100

    /// Collectors that ship disabled; everything else defaults to enabled.
    static let disabledByDefault: Set<String> = ["mail", "input", "tabs"]

    /// Which policy key governs a label, for the collectors that have one.
    static let labelPolicies: [String: [String: String]] = [
        "browser": ["domain": "domains"],
        "focus": ["app": "apps", "bundle_id": "apps"],
        "processes": ["name": "names"],
        "docker": ["name": "containers", "image": "containers"],
        "knowledge": ["app": "apps"],
        "notes": ["folder": "folders"],
        "calendar": ["calendar": "calendars"],
        "git": ["repo": "repos", "branch": "branches"],
        "claude_code": ["project": "projects"],
        "projects": ["project": "projects"],
        "shell": ["command": "commands", "remote_host": "hosts"],
        "events": ["project": "projects"],
        "hardware": ["name": "devices"],
        "system": ["ssid": "wifi"],
    ]

    static let permissionShaped = try! NSRegularExpression(
        pattern: "full disk access|permission|not readable|accessibility|automation|location|does not exist|not found|unreadable",
        options: .caseInsensitive)

    static func recommend(input: TuneInput) -> [Recommendation] {
        var out: [Recommendation] = []
        out += unavailableCollectors(input)
        out += slowCollectors(input)
        out += failingCollectors(input)
        out += wideLabels(input)
        out += seriesBudget(input)
        out += slowScrape(input)
        out += enableableSources(input)
        out += hashingAvailable(input)
        out += tokenOnOpenBind(input)
        return out
    }

    // Rule 1
    static func unavailableCollectors(_ input: TuneInput) -> [Recommendation] {
        input.collectors.compactMap { c in
            guard c.unavailable, let since = c.unavailableSince,
                  input.now.timeIntervalSince(since) > unavailableGrace,
                  let error = c.lastError, isPermissionShaped(error) else { return nil }
            let hours = Int(input.now.timeIntervalSince(since) / 3600)
            return Recommendation(
                severity: .warn, collector: c.name,
                title: "\(c.name) has been unavailable for \(hours)h",
                why: "Last error: \(error). Grant the permission (see docs/GETTING-STARTED.md, permissions) or disable the collector so it stops retrying.",
                configPatch: patch(c.name, ["enabled": .bool(false)]))
        }
    }

    // Rule 2
    static func slowCollectors(_ input: TuneInput) -> [Recommendation] {
        input.collectors.compactMap { c in
            guard c.interval > 0, c.lastDuration > 0.5 * c.interval else { return nil }
            let suggested = max(Int(c.interval) + 1, Int((2 * c.lastDuration).rounded(.up)))
            return Recommendation(
                severity: .warn, collector: c.name,
                title: "\(c.name) takes \(fmt(c.lastDuration))s of its \(Int(c.interval))s interval",
                why: "A run that uses more than half the interval leaves no headroom. Raise interval to \(suggested)s.",
                configPatch: patch(c.name, ["interval": .number(Double(suggested))]))
        }
    }

    // Rule 3
    static func failingCollectors(_ input: TuneInput) -> [Recommendation] {
        input.collectors.compactMap { c in
            guard c.runs >= 5, !c.unavailable, Double(c.errors) / Double(c.runs) > errorRateLimit else { return nil }
            let pct = Int(100 * Double(c.errors) / Double(c.runs))
            return Recommendation(
                severity: .warn, collector: c.name,
                title: "\(c.name) fails \(pct)% of its runs",
                why: "\(c.errors) of \(c.runs) runs failed. Last error: \(c.lastError ?? "unknown").",
                configPatch: nil)
        }
    }

    // Rule 4
    static func wideLabels(_ input: TuneInput) -> [Recommendation] {
        var out: [Recommendation] = []
        let known = input.collectors.map { $0.name }
        for family in input.families {
            guard let collector = collectorName(for: family.name, known: known) else { continue }
            for (label, distinct) in family.labelCardinality.sorted(by: { $0.key < $1.key }) {
                guard let policy = labelPolicies[collector]?[label] else { continue }
                let current = (try? input.config.collector(collector).policy(policy))?.maxCardinality ?? 0
                let overBudget = distinct > cardinalityLimit || (current > 0 && distinct > 2 * current)
                guard overBudget else { continue }
                let target = current > 0 ? max(10, current / 2) : 50
                out.append(Recommendation(
                    severity: .warn, collector: collector,
                    title: "\(family.name) has \(distinct) distinct \(label) values",
                    why: "Policy \(collector).\(policy) allows \(current == 0 ? "unlimited" : String(current)) values per run. Lower maxCardinality to \(target) or add denylist patterns for the noisiest values.",
                    configPatch: patch(collector, [policy: .object(["maxCardinality": .number(Double(target))])])))
            }
        }
        return dedupe(out)
    }

    // Rule 5
    static func seriesBudget(_ input: TuneInput) -> [Recommendation] {
        let total = input.families.reduce(0) { $0 + $1.series }
        let samples = Int(input.scrapeSamples ?? 0)
        guard total > seriesBudget || samples > seriesBudget else { return [] }
        let top = input.families.sorted { $0.series > $1.series }.prefix(3)
        let known = input.collectors.map { $0.name }
        var merged: JSONValue = .object([:])
        var disabled: [String] = []
        for family in top {
            guard let collector = collectorName(for: family.name, known: known),
                  let label = family.labelCardinality.max(by: { $0.value < $1.value })?.key,
                  let policy = labelPolicies[collector]?[label],
                  let fragment = patch(collector, [policy: .object(["enabled": .bool(false)])]) else { continue }
            merged = JSONMerge.merge(merged, fragment)
            disabled.append("\(collector).\(policy)")
        }
        let names = top.map { "\($0.name) (\($0.series))" }.joined(separator: ", ")
        return [Recommendation(
            severity: .warn, collector: nil,
            title: "Registry holds \(max(total, samples)) series, over the \(seriesBudget) budget",
            why: "Largest families: \(names). Disabling their label policies (\(disabled.isEmpty ? "none mappable" : disabled.joined(separator: ", "))) keeps the aggregate metrics and drops the per-value series.",
            configPatch: disabled.isEmpty ? nil : merged)]
    }

    // Rule 6
    static func slowScrape(_ input: TuneInput) -> [Recommendation] {
        guard let duration = input.scrapeDuration, duration > scrapeBudgetSeconds else { return [] }
        let slowest = input.collectors.filter { $0.interval > 0 }.sorted { $0.lastDuration > $1.lastDuration }.prefix(3)
        var merged: JSONValue = .object([:])
        for c in slowest {
            if let fragment = patch(c.name, ["interval": .number((c.interval * 2).rounded())]) {
                merged = JSONMerge.merge(merged, fragment)
            }
        }
        let names = slowest.map { "\($0.name) (\(fmt($0.lastDuration))s)" }.joined(separator: ", ")
        return [Recommendation(
            severity: .warn, collector: nil,
            title: "Prometheus scrapes take \(fmt(duration))s",
            why: "Rendering /metrics should take milliseconds; slow collectors holding locks are the usual cause. Slowest: \(names). Doubling their intervals is a safe first step.",
            configPatch: slowest.isEmpty ? nil : merged)]
    }

    // Rule 7
    static func enableableSources(_ input: TuneInput) -> [Recommendation] {
        let candidates: [(collector: String, present: Bool, source: String)] = [
            ("codex", input.environment.codexSessionsExist, "~/.codex/sessions exists"),
            ("mail", input.environment.mailIndexExists, "Apple Mail's Envelope Index exists"),
            ("input", input.environment.accessibilityTrusted, "this process is trusted for Accessibility"),
            ("tabs", input.environment.browsersRunning, "a scriptable browser is running"),
        ]
        return candidates.compactMap { c in
            guard c.present else { return nil }
            let enabled = input.config.collector(c.collector).enabled(default: !disabledByDefault.contains(c.collector))
            guard !enabled else { return nil }
            return Recommendation(
                severity: .info, collector: c.collector,
                title: "\(c.collector) could be enabled",
                why: "\(c.source) but the collector is disabled. Enable it if you want that data; the tuning rules never do this for you.",
                configPatch: nil)
        }
    }

    // Rule 8
    static func hashingAvailable(_ input: TuneInput) -> [Recommendation] {
        let sensitive: [(String, String)] = [("browser", "domains"), ("shell", "hosts"), ("shell", "commands")]
        return sensitive.compactMap { collector, key in
            guard let policy = try? input.config.collector(collector).policy(key), policy.enabled, !policy.hash else { return nil }
            return Recommendation(
                severity: .info, collector: collector,
                title: "\(collector).\(key) exports raw values",
                why: "The policy is enabled without hashing. Setting hash: true (with a salt) keeps the series distinguishable on dashboards without naming the values.",
                configPatch: nil)
        }
    }

    // Rule 9
    static func tokenOnOpenBind(_ input: TuneInput) -> [Recommendation] {
        let bind = input.config.server.bind
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(bind)
        let token = input.config.collector("events").string("token", default: "")
        guard !loopback, token.isEmpty else { return [] }
        return [Recommendation(
            severity: .warn, collector: "events",
            title: "POST /event is open on \(bind) without a token",
            why: "Anything on the network can inflate your event counters. Set events.token and pass it to molly hook, or bind to 127.0.0.1.",
            configPatch: nil)]
    }

    // MARK: helpers

    static func isPermissionShaped(_ error: String) -> Bool {
        permissionShaped.firstMatch(in: error, range: NSRange(error.startIndex..., in: error)) != nil
    }

    /// Families whose name prefix is not the collector name.
    static let familyPrefixes: [String: String] = [
        "molly_claude_hook": "events", "molly_events": "events", "molly_claude": "claude_code",
        "molly_process_": "processes", "molly_agent_process": "processes",
        "molly_cpu": "system", "molly_memory": "system", "molly_swap": "system", "molly_disk": "system",
        "molly_network": "network", "molly_network_wifi": "system", "molly_battery": "system", "molly_display": "system", "molly_load": "system",
        "molly_idle": "focus", "molly_user_active": "focus", "molly_screen": "focus", "molly_running_app": "focus",
        "molly_windows": "focus", "molly_app_": "focus", "molly_active_seconds": "focus", "molly_system_asleep": "focus",
        "molly_microphone": "meeting", "molly_camera": "meeting", "molly_meeting": "meeting",
        "molly_message": "messages", "molly_xcode": "builds", "molly_build": "builds",
        "molly_usb": "hardware", "molly_audio": "hardware", "molly_external_displays": "hardware",
        "molly_docked": "hardware", "molly_lid": "hardware", "molly_power_adapter": "hardware",
        "molly_project": "projects", "molly_self": "process", "molly_collector": "process",
    ]

    /// Maps a metric family to its collector by the longest matching prefix.
    static func collectorName(for family: String, known: [String]) -> String? {
        var best: (collector: String, length: Int)?
        for (prefix, collector) in familyPrefixes where family.hasPrefix(prefix) {
            if best == nil || prefix.count > best!.length { best = (collector, prefix.count) }
        }
        for collector in known where family.hasPrefix("molly_\(collector)_") {
            let length = collector.count + 7
            if best == nil || length > best!.length { best = (collector, length) }
        }
        return best?.collector
    }

    static func patch(_ collector: String, _ section: [String: JSONValue]) -> JSONValue? {
        .object(["collectors": .object([collector: .object(section)])])
    }

    private static func dedupe(_ recs: [Recommendation]) -> [Recommendation] {
        var seen: Set<String> = []
        return recs.filter { seen.insert($0.title).inserted }
    }

    static func fmt(_ seconds: Double) -> String {
        seconds >= 10 ? String(Int(seconds.rounded())) : String(format: "%.1f", seconds)
    }
}

/// Human and JSON renderings of a recommendation list.
enum TuneReport {
    static func text(_ recs: [Recommendation]) -> String {
        guard !recs.isEmpty else { return "No recommendations. Molly looks healthy.\n" }
        var out = ""
        for (i, r) in recs.enumerated() {
            out += "\(i + 1). [\(r.severity.rawValue)] \(r.title)\n"
            out += "   \(r.why)\n"
            if let p = r.configPatch, let data = try? JSONMerge.prettyData(p) {
                let body = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n").map { "   " + $0 }.joined(separator: "\n")
                out += "   patch:\n\(body)\n"
            }
            out += "\n"
        }
        return out
    }

    static func json(_ recs: [Recommendation]) -> JSONValue {
        .array(recs.map { r in
            var o: [String: JSONValue] = [
                "severity": .string(r.severity.rawValue),
                "title": .string(r.title),
                "why": .string(r.why),
            ]
            if let c = r.collector { o["collector"] = .string(c) }
            if let p = r.configPatch { o["configPatch"] = p }
            return .object(o)
        })
    }

    static func combinedPatch(_ recs: [Recommendation]) -> JSONValue {
        recs.compactMap { $0.configPatch }.reduce(.object([:]), JSONMerge.merge)
    }
}
