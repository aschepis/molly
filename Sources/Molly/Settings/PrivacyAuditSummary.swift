import Foundation

/// The per-dimension counts from the daemon's `/privacy` report, in a shape
/// the Privacy tab can show next to each policy.
enum PrivacyAuditSummary {
    struct Counts: Equatable {
        var passed = 0
        var other = 0
        var redacted = 0
        var hashed = 0

        var total: Int { passed + other + redacted + hashed }

        /// One line such as "12 passed · 3 other", omitting zero outcomes.
        var summary: String {
            let parts = [(passed, "passed"), (other, "other"), (redacted, "redacted"), (hashed, "hashed")]
                .filter { $0.0 > 0 }
                .map { "\($0.0) \($0.1)" }
            return parts.isEmpty ? "nothing recorded yet" : parts.joined(separator: " · ")
        }
    }

    /// Keyed by dimension id ("browser.domains"). Entries with malformed
    /// counts are skipped rather than failing the whole report.
    static func parse(_ data: Data) throws -> [String: Counts] {
        let root = try JSONValue.parse(data)
        var result: [String: Counts] = [:]
        for entry in root.objectValue?["dimensions"]?.arrayValue ?? [] {
            guard let object = entry.objectValue,
                  let id = object["dimension"]?.stringValue,
                  let counts = object["counts"]?.objectValue else { continue }
            result[id] = Counts(
                passed: counts["passed"]?.intValue ?? 0,
                other: counts["other"]?.intValue ?? 0,
                redacted: counts["redacted"]?.intValue ?? 0,
                hashed: counts["hashed"]?.intValue ?? 0)
        }
        return result
    }
}

/// The short status shown beside each collector in the Collectors tab.
enum CollectorStatusText {
    enum Kind { case off, waiting, ok, errors, unavailable }

    struct Pill: Equatable {
        let text: String
        let kind: Kind
    }

    /// `enabled` is the pending config value; `status` comes from the running
    /// daemon, so the two disagree until Apply.
    static func pill(enabled: Bool, status: CollectorManager.Status?, now: Date = Date()) -> Pill {
        guard enabled else { return Pill(text: "off", kind: .off) }
        guard let status else { return Pill(text: "starts on Apply", kind: .waiting) }
        if status.unavailable { return Pill(text: "unavailable", kind: .unavailable) }
        if let success = status.lastSuccess {
            let age = max(0, Int(now.timeIntervalSince(success)))
            let errors = status.errors > 0 ? ", \(status.errors) errors" : ""
            return Pill(text: "ok \(age)s ago\(errors)", kind: status.errors > 0 ? .errors : .ok)
        }
        if status.errors > 0 { return Pill(text: "\(status.errors) errors", kind: .errors) }
        return Pill(text: "waiting", kind: .waiting)
    }
}

/// Pattern text as edited in a text box, one pattern per line.
enum PatternText {
    static func join(_ patterns: [String]) -> String { patterns.joined(separator: "\n") }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
