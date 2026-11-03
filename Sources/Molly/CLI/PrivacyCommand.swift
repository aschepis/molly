import Foundation

/// Prints what `/privacy` reports: every sensitive label dimension, its
/// policy, and how many values passed or were folded. Reads the running
/// daemon when there is one, otherwise builds the collectors to list policies.
enum PrivacyCommand {
    static func run(_ arguments: [String]) {
        let config: Config
        do {
            config = try Config.load()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
        let live = URL(string: "http://\(config.server.bind):\(config.server.port)/privacy")!
        let (status, data) = DoctorCommand.fetch(live, timeout: 2)
        let report: [String: Any]
        if status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            report = json
            print("source: running daemon at \(live.absoluteString)")
        } else {
            do {
                StateStore.persistenceEnabled = false
                let collectors = try CollectorRegistry.makeCollectors(config: config)
                report = PrivacyAudit.shared.report(
                    constLabels: config.constLabels,
                    collectorsOn: collectors.map { $0.name },
                    disabledByDefault: CollectorRegistry.disabledByDefault)
                print("source: config only (no daemon reachable, counts are zero)")
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
        }
        if arguments.contains("--json") {
            if let out = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: out, as: UTF8.self))
            }
            return
        }
        print(render(report))
    }

    static func render(_ report: [String: Any]) -> String {
        var lines: [String] = []
        if let labels = report["constLabels"] as? [String: String] {
            lines.append("labels on every series: " + labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        lines.append("")
        lines.append(pad("dimension", 26) + pad("policy", 30) + pad("passed", 8) + pad("other", 8) + pad("redacted", 10) + "hashed")
        for dim in (report["dimensions"] as? [[String: Any]]) ?? [] {
            let policy = dim["policy"] as? [String: Any] ?? [:]
            let counts = dim["counts"] as? [String: Any] ?? [:]
            let enabled = policy["enabled"] as? Bool ?? false
            var desc = enabled ? "on, \(policy["mode"] ?? "")" : "off"
            if enabled, let n = policy["patternCount"] as? Int, n > 0 { desc += ", \(n) patterns" }
            if enabled, policy["hash"] as? Bool == true { desc += ", hashed" }
            if enabled, let c = policy["maxCardinality"] as? Int, c > 0 { desc += ", max \(c)" }
            lines.append(pad(dim["dimension"] as? String ?? "", 26) + pad(desc, 30)
                         + pad("\(counts["passed"] ?? 0)", 8) + pad("\(counts["other"] ?? 0)", 8)
                         + pad("\(counts["redacted"] ?? 0)", 10) + "\(counts["hashed"] ?? 0)")
        }
        lines.append("")
        lines.append("opt-in collectors:")
        for c in (report["sensitiveCollectors"] as? [[String: Any]]) ?? [] {
            lines.append("  " + pad(c["collector"] as? String ?? "", 12) + ((c["enabled"] as? Bool ?? false) ? "on" : "off"))
        }
        return lines.joined(separator: "\n")
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
