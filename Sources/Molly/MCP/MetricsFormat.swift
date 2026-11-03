import Foundation

/// Text renderings of query results and exposition text, kept small so an
/// LLM client can read them without a parser.
enum MetricsFormat {
    static let maxRows = 200

    static func vector(_ samples: [PrometheusClient.Sample]) -> String {
        guard !samples.isEmpty else { return "(empty result)" }
        var lines = samples.prefix(maxRows).map { "\(labelText($0.labels)) \(number($0.value))" }
        if samples.count > maxRows {
            lines.append("... \(samples.count - maxRows) more rows omitted (narrow the query)")
        }
        return lines.joined(separator: "\n")
    }

    static func matrix(_ series: [PrometheusClient.Series]) -> String {
        guard !series.isEmpty else { return "(empty result)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        var lines: [String] = []
        for s in series.prefix(maxRows) {
            let points = s.points.map { "\(formatter.string(from: $0.0))=\(number($0.1))" }
            lines.append("\(labelText(s.labels)) \(points.joined(separator: " "))")
        }
        if series.count > maxRows {
            lines.append("... \(series.count - maxRows) more series omitted (narrow the query)")
        }
        return lines.joined(separator: "\n")
    }

    /// `name{a="1",b="2"}`; user/host and the scrape labels are dropped
    /// because they are the same on every Molly series.
    static let hiddenLabels: Set<String> = ["__name__", "user", "host", "instance", "job"]

    static func labelText(_ labels: [String: String]) -> String {
        let name = labels["__name__"] ?? ""
        let pairs = labels.sorted { $0.key < $1.key }
            .filter { !hiddenLabels.contains($0.key) }
            .map { "\($0.key)=\"\($0.value)\"" }
        if pairs.isEmpty { return name.isEmpty ? "{}" : name }
        return name + "{" + pairs.joined(separator: ",") + "}"
    }

    static func number(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.4g", value)
    }

    struct Family: Equatable {
        let name: String
        let type: String
        let help: String
    }

    /// Reads `# HELP` and `# TYPE` lines from Prometheus text exposition.
    static func families(fromExposition text: String) -> [Family] {
        var helps: [String: String] = [:]
        var types: [String: String] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# HELP ") {
                let rest = line.dropFirst(7)
                let name: String
                if let space = rest.firstIndex(of: " ") {
                    name = String(rest[..<space])
                    helps[name] = String(rest[rest.index(after: space)...])
                } else {
                    name = String(rest)
                    helps[name] = ""
                }
                if !order.contains(name) { order.append(name) }
            } else if line.hasPrefix("# TYPE ") {
                let parts = line.dropFirst(7).split(separator: " ")
                if parts.count == 2 { types[String(parts[0])] = String(parts[1]) }
            }
        }
        return order.map { Family(name: $0, type: types[$0] ?? "untyped", help: helps[$0] ?? "") }
    }

    /// Reads metric rows (`| \`name\` | type | labels | unit | meaning |`) from docs/METRICS.md.
    static func families(fromCatalog markdown: String) -> [Family] {
        var out: [Family] = []
        for line in markdown.split(separator: "\n") where line.hasPrefix("| `molly") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 6 else { continue }
            let name = cells[1].replacingOccurrences(of: "`", with: "")
            out.append(Family(name: name, type: cells[2], help: cells[5]))
        }
        return out
    }

    static func familyTable(_ families: [Family]) -> String {
        guard !families.isEmpty else { return "(no metrics)" }
        return families.map { "\($0.name)  \($0.type)  \($0.help)" }.joined(separator: "\n")
    }
}
