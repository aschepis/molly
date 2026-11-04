import Foundation

enum InsightsFormat: CaseIterable {
    // Declaration order is the tie-break order for equal Accept q-values.
    case html, markdown, json, yaml

    var fileExtension: String {
        switch self {
        case .html: return "html"
        case .markdown: return "md"
        case .json: return "json"
        case .yaml: return "yaml"
        }
    }

    var contentType: String {
        switch self {
        case .html: return "text/html; charset=utf-8"
        case .markdown: return "text/markdown; charset=utf-8"
        case .json: return "application/json"
        case .yaml: return "application/yaml"
        }
    }

    var label: String {
        switch self {
        case .html: return "HTML"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .yaml: return "YAML"
        }
    }

    static func fromSuffix(_ ext: String) -> InsightsFormat? {
        switch ext.lowercased() {
        case "html": return .html
        case "md": return .markdown
        case "json": return .json
        case "yaml", "yml": return .yaml
        default: return nil
        }
    }

    private static let mediaTypes: [String: InsightsFormat] = [
        "text/html": .html, "text/markdown": .markdown, "text/x-markdown": .markdown,
        "application/json": .json,
        "application/yaml": .yaml, "text/yaml": .yaml, "application/x-yaml": .yaml, "text/x-yaml": .yaml,
    ]
    private static let wildcards: [String: InsightsFormat] = ["*/*": .html, "text/*": .html, "application/*": .json]

    enum Choice: Equatable {
        case format(InsightsFormat)
        case notAcceptable
    }

    /// Highest q wins; ties go to the declaration order above. Wildcards count
    /// as their most natural format. Missing or unparseable headers mean HTML;
    /// 406 only when concrete media types are listed and none is ours.
    static func choose(accept: String?) -> Choice {
        guard let accept, !accept.trimmingCharacters(in: .whitespaces).isEmpty else { return .format(.html) }
        var best: [InsightsFormat: Double] = [:]
        var sawConcreteType = false
        for item in accept.split(separator: ",") {
            let parts = item.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard let type = parts.first, type.contains("/") else { continue }
            sawConcreteType = true
            let q = parts.dropFirst().compactMap { $0.hasPrefix("q=") ? Double($0.dropFirst(2)) : nil }.first ?? 1
            guard q > 0, let format = mediaTypes[type] ?? wildcards[type] else { continue }
            best[format] = max(best[format] ?? 0, q)
        }
        guard let top = best.values.max() else { return sawConcreteType ? .notAcceptable : .format(.html) }
        return .format(allCases.first { best[$0] == top } ?? .html)
    }
}

/// `/insights/<name>[.ext]` where name is `latest`, `<date>` or `<date>-week`.
struct InsightsPath: Equatable {
    let name: String
    let suffix: InsightsFormat?

    init?(path: String) {
        let prefix = "/insights/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        var name = String(path.dropFirst(prefix.count))
        var suffix: InsightsFormat?
        if let dot = name.lastIndex(of: "."), let format = InsightsFormat.fromSuffix(String(name[name.index(after: dot)...])) {
            suffix = format
            name = String(name[..<dot])
        }
        self.name = name
        self.suffix = suffix
    }
}

enum InsightsRoute {
    static func handle(_ request: HTTPRequest, store: InsightsStore) -> HTTPResponse {
        guard let target = InsightsPath(path: request.path) else { return .notFound() }
        var kind = InsightsDigest.Kind.day
        var date = target.name
        var markdown: String?
        if target.name == "latest" {
            guard let latest = store.latest() else {
                return .text("no insights yet: run `molly insights` or enable the insights collector\n", status: 404)
            }
            date = latest.date
            markdown = latest.text
        } else {
            if date.hasSuffix("-week") {
                kind = .week
                date = String(date.dropLast("-week".count))
            }
            guard DigestBuilder.parseDate(date) != nil, let text = store.read(kind: kind, date: date) else { return .notFound() }
            markdown = text
        }
        guard let markdown else { return .notFound() }

        let format: InsightsFormat
        if let suffix = target.suffix {
            format = suffix
        } else {
            switch InsightsFormat.choose(accept: request.headers["accept"]) {
            case .format(let chosen): format = chosen
            case .notAcceptable:
                return response(.text("not acceptable: serving text/html, text/markdown, application/json, application/yaml\n",
                                      status: 406))
            }
        }
        let report = Report(kind: kind, date: date, markdown: markdown,
                            digest: store.readDigest(kind: kind, date: date),
                            fileTime: store.modified(kind: kind, date: date))
        let body: String
        switch format {
        case .html: body = page(report, store: store)
        case .markdown: body = markdown
        case .json: body = jsonText(report.tree)
        case .yaml: body = YAML.emit(report.tree)
        }
        return response(.text(body, contentType: format.contentType))
    }

    private static func response(_ response: HTTPResponse) -> HTTPResponse {
        var response = response
        response.headers["Vary"] = "Accept"
        return response
    }

    struct Report {
        let kind: InsightsDigest.Kind
        let date: String
        let markdown: String
        let digest: JSONValue?
        let fileTime: Date?

        /// Reports from before digests were saved fall back to the file time.
        var generated: String? {
            if let stamp = digest?["generated_at"]?.stringValue { return stamp }
            return fileTime.map { ISO8601DateFormatter().string(from: $0) }
        }

        var slug: String { kind == .day ? date : "\(date)-week" }

        var tree: JSONValue {
            .object([
                "kind": .string(kind.rawValue),
                "date": .string(date),
                "generated": generated.map(JSONValue.string) ?? .null,
                "markdown": .string(markdown),
                "digest": digest ?? .null,
            ])
        }
    }

    static func jsonText(_ tree: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(tree) else { return "{}" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: HTML page

    static func page(_ report: Report, store: InsightsStore) -> String {
        let title = report.kind == .day ? "Molly insights \(report.date)" : "Molly insights, week of \(report.date)"
        var meta = [report.kind == .day ? "Daily report" : "Weekly report", MarkdownHTML.escape(report.date)]
        if let generated = report.generated { meta.append("generated \(MarkdownHTML.escape(generated))") }
        let formats = InsightsFormat.allCases
            .map { "<a href=\"/insights/\(report.slug).\($0.fileExtension)\">\($0.label)</a>" }.joined(separator: " · ")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(MarkdownHTML.escape(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <header class="meta">\(meta.joined(separator: " · "))<br>\(formats)\(neighbours(report, store: store))</header>
        <main>
        \(MarkdownHTML.render(report.markdown))</main>
        </body>
        </html>

        """
    }

    private static func neighbours(_ report: Report, store: InsightsStore) -> String {
        let dates = store.dates(kind: report.kind)
        guard let index = dates.firstIndex(of: report.date) else { return "" }
        func link(_ date: String, _ text: String) -> String {
            "<a href=\"/insights/\(report.kind == .day ? date : "\(date)-week")\">\(text)</a>"
        }
        var parts: [String] = []
        if index > dates.startIndex { parts.append(link(dates[index - 1], "&larr; \(dates[index - 1])")) }
        if index < dates.endIndex - 1 { parts.append(link(dates[index + 1], "\(dates[index + 1]) &rarr;")) }
        return parts.isEmpty ? "" : "<br>" + parts.joined(separator: " · ")
    }

    private static let css = """
    :root { color-scheme: light dark; --bg: #fff; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --code: #f5f5f7; --link: #0a60d0; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #1c1c1e; --fg: #f2f2f7; --muted: #98989f; --line: #3a3a3c; --code: #2c2c2e; --link: #6cb2ff; }
    }
    body { background: var(--bg); color: var(--fg); font: 16px/1.6 -apple-system, system-ui, sans-serif; margin: 0; padding: 24px 16px; }
    header.meta, main { max-width: 720px; margin: 0 auto; }
    header.meta { color: var(--muted); font-size: 14px; margin-bottom: 16px; }
    a { color: var(--link); }
    table { border-collapse: collapse; margin: 1em 0; }
    th, td { border: 1px solid var(--line); padding: 4px 10px; text-align: left; }
    code, pre { background: var(--code); border-radius: 4px; font-family: ui-monospace, Menlo, monospace; font-size: 14px; }
    code { padding: 1px 4px; }
    pre { overflow-x: auto; padding: 10px 12px; }
    pre code { padding: 0; }
    hr { border: 0; border-top: 1px solid var(--line); }
    """
}
