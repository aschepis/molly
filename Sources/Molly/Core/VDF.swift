import Foundation

/// Valve KeyValues text, as used by Steam's appmanifest and localconfig files.
/// A tree is `[String: Any]` whose values are either `String` or a nested tree.
/// Malformed input yields whatever parsed cleanly so far; it never throws.
enum VDF {
    static func parse(_ text: String) -> [String: Any] {
        var parser = Parser(Array(text.unicodeScalars))
        return parser.parseObject(topLevel: true)
    }

    /// Case-insensitive descent: Steam writes "apps" in one file and "Apps" in another.
    static func lookup(_ tree: [String: Any], _ path: [String]) -> Any? {
        var current: Any = tree
        for key in path {
            guard let object = current as? [String: Any],
                  let match = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { return nil }
            current = match.value
        }
        return current
    }

    static func string(_ tree: [String: Any], _ path: [String]) -> String? {
        lookup(tree, path) as? String
    }

    static func object(_ tree: [String: Any], _ path: [String]) -> [String: Any]? {
        lookup(tree, path) as? [String: Any]
    }

    private enum Token: Equatable {
        case text(String)
        case open
        case close
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func parseObject(topLevel: Bool) -> [String: Any] {
            var out: [String: Any] = [:]
            while let token = next() {
                switch token {
                case .close:
                    if !topLevel { return out }
                case .open:
                    continue
                case .text(let key):
                    guard let value = next() else { return out }
                    switch value {
                    case .text(let s): out[key] = s
                    case .open: out[key] = parseObject(topLevel: false)
                    case .close: if !topLevel { return out }
                    }
                }
            }
            return out
        }

        private mutating func next() -> Token? {
            skipBlanksAndComments()
            guard index < scalars.count else { return nil }
            let c = scalars[index]
            if c == "{" { index += 1; return .open }
            if c == "}" { index += 1; return .close }
            if c == "\"" { return .text(quoted()) }
            return .text(bare())
        }

        private mutating func skipBlanksAndComments() {
            while index < scalars.count {
                let c = scalars[index]
                if c.properties.isWhitespace {
                    index += 1
                } else if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else {
                    return
                }
            }
        }

        private mutating func quoted() -> String {
            index += 1
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                index += 1
                if c == "\"" { break }
                guard c == "\\", index < scalars.count else { out.append(c); continue }
                let escaped = scalars[index]
                index += 1
                switch escaped {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(escaped)
                }
            }
            return String(out)
        }

        private mutating func bare() -> String {
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                if c.properties.isWhitespace || c == "{" || c == "}" || c == "\"" { break }
                out.append(c)
                index += 1
            }
            return String(out)
        }
    }
}
