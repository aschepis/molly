import Foundation

/// Renders the small Markdown subset insights reports use. It escapes every
/// piece of text, so a report can never inject markup into the page.
enum MarkdownHTML {
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func render(_ markdown: String) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        var html: [String] = []
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.removeFirst()
            } else if trimmed.hasPrefix("```") {
                html.append(fencedCode(&lines))
            } else if let heading = heading(trimmed) {
                html.append(heading)
                lines.removeFirst()
            } else if isRule(trimmed) {
                html.append("<hr>")
                lines.removeFirst()
            } else if let wrapper = detailsWrapper(trimmed) {
                html.append(wrapper)
                lines.removeFirst()
            } else if lines.count > 1, isTableRow(trimmed), isTableSeparator(lines[lines.startIndex + 1]) {
                html.append(table(&lines))
            } else if listMarker(trimmed) != nil {
                html.append(list(&lines))
            } else {
                html.append(paragraph(&lines))
            }
        }
        return html.joined(separator: "\n") + "\n"
    }

    // MARK: Blocks

    private static func fencedCode(_ lines: inout ArraySlice<String>) -> String {
        lines.removeFirst()
        var body: [String] = []
        while let line = lines.first {
            lines.removeFirst()
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
            body.append(line)
        }
        return "<pre><code>\(escape(body.joined(separator: "\n")))</code></pre>"
    }

    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return "<h\(hashes)>\(inline(text))</h\(hashes)>"
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// Reports wrap the digest in <details>; only these exact tags pass through.
    private static func detailsWrapper(_ line: String) -> String? {
        if line == "<details>" || line == "</details>" { return line }
        guard line.hasPrefix("<summary>"), line.hasSuffix("</summary>") else { return nil }
        let text = line.dropFirst("<summary>".count).dropLast("</summary>".count)
        return "<summary>\(inline(String(text)))</summary>"
    }

    private static func isTableRow(_ line: String) -> Bool { line.contains("|") }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) } && cell.contains("-")
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func table(_ lines: inout ArraySlice<String>) -> String {
        let header = tableCells(lines.removeFirst())
        lines.removeFirst()
        var out = "<table>\n<thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
        while let line = lines.first, !line.trimmingCharacters(in: .whitespaces).isEmpty, isTableRow(line) {
            lines.removeFirst()
            out += "<tr>" + tableCells(line).map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
        }
        return out + "</tbody>\n</table>"
    }

    /// Returns (ordered, text after the marker) for a list item line.
    private static func listMarker(_ line: String) -> (ordered: Bool, text: String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (true, String(line.dropFirst(digits.count + 2)))
    }

    private static func list(_ lines: inout ArraySlice<String>) -> String {
        let ordered = listMarker(lines[lines.startIndex].trimmingCharacters(in: .whitespaces))?.ordered ?? false
        var items: [String] = []
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = listMarker(trimmed), marker.ordered == ordered {
                items.append(marker.text)
            } else if !trimmed.isEmpty, line.hasPrefix(" "), !items.isEmpty {
                items[items.count - 1] += " " + trimmed
            } else {
                break
            }
            lines.removeFirst()
        }
        let tag = ordered ? "ol" : "ul"
        return "<\(tag)>\n" + items.map { "<li>\(inline($0))</li>\n" }.joined() + "</\(tag)>"
    }

    private static func paragraph(_ lines: inout ArraySlice<String>) -> String {
        var parts: [String] = []
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let startsBlock = trimmed.hasPrefix("```") || heading(trimmed) != nil || isRule(trimmed)
                || listMarker(trimmed) != nil || detailsWrapper(trimmed) != nil
            if trimmed.isEmpty || (startsBlock && !parts.isEmpty) { break }
            parts.append(trimmed)
            lines.removeFirst()
        }
        return "<p>\(inline(parts.joined(separator: "\n")))</p>"
    }

    // MARK: Inline

    /// Code spans are split out first so their contents are never styled.
    /// A backtick with no partner is literal text.
    static func inline(_ text: String) -> String {
        let pieces = text.components(separatedBy: "`")
        var out = ""
        for (index, piece) in pieces.enumerated() {
            let isOdd = index % 2 == 1
            if isOdd, index < pieces.count - 1 {
                out += "<code>\(escape(piece))</code>"
            } else {
                out += (isOdd ? "`" : "") + styledText(escape(piece))
            }
        }
        return out
    }

    private static func styledText(_ escaped: String) -> String {
        var out = escaped
        out = replace(out, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { groups in
            isSafeLink(groups[2]) ? "<a href=\"\(groups[2])\">\(groups[1])</a>" : groups[0]
        }
        out = replace(out, #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        out = replace(out, #"(?<![\*\w])\*(?!\s)([^*]+?)\*(?!\*)"#) { "<em>\($0[1])</em>" }
        return out
    }

    private static func isSafeLink(_ href: String) -> Bool {
        let lower = href.lowercased()
        return ["http://", "https://", "mailto:", "/", "#"].contains { lower.hasPrefix($0) } || !lower.contains(":")
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }
        return out + ns.substring(from: cursor)
    }
}
