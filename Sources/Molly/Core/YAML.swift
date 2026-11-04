import Foundation

/// Emits a JSON-compatible value tree as block-style YAML. Output only: Molly
/// never reads YAML, so there is no parser.
enum YAML {
    static func emit(_ value: JSONValue) -> String {
        let out: [String]
        switch value {
        case .object(let o) where !o.isEmpty: out = lines(for: value, indent: 0)
        case .array(let a) where !a.isEmpty: out = lines(for: value, indent: 0)
        default: out = entry(prefix: "", value: value, indent: -2).map { String($0.dropFirst()) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Lines for a non-empty object or array whose lines start at `indent`.
    private static func lines(for value: JSONValue, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .object(let object):
            return object.keys.sorted().flatMap { key in
                entry(prefix: "\(pad)\(scalar(key)):", value: object[key] ?? .null, indent: indent)
            }
        case .array(let array):
            return array.flatMap { item in
                isContainer(item) ? dashed(item, indent: indent) : entry(prefix: "\(pad)-", value: item, indent: indent)
            }
        default:
            return []
        }
    }

    private static func isContainer(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let o): return !o.isEmpty
        case .array(let a): return !a.isEmpty
        default: return false
        }
    }

    /// A container inside an array shares the dash's line with its first line.
    private static func dashed(_ item: JSONValue, indent: Int) -> [String] {
        var inner = lines(for: item, indent: indent + 2)
        inner[0] = String(repeating: " ", count: indent) + "- " + inner[0].dropFirst(indent + 2)
        return inner
    }

    private static func entry(prefix: String, value: JSONValue, indent: Int) -> [String] {
        switch value {
        case .object, .array:
            return isContainer(value) ? [prefix] + lines(for: value, indent: indent + 2) : ["\(prefix) \(value.isObject ? "{}" : "[]")"]
        case .string(let s) where isBlockScalar(s):
            return ["\(prefix) \(blockHeader(s))"] + blockBody(s, indent: indent + 2)
        case .string(let s):
            return ["\(prefix) \(scalar(s))"]
        case .null: return ["\(prefix) null"]
        case .bool(let b): return ["\(prefix) \(b)"]
        case .number(let n):
            return ["\(prefix) \(n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n))"]
        }
    }

    static func scalar(_ s: String) -> String {
        needsQuotes(s) ? quoted(s) : s
    }

    private static let reserved: Set<String> = ["", "~", "null", "true", "false", "yes", "no", "on", "off", "y", "n", ".inf", "-.inf", ".nan"]
    private static let specialLeading = Set("-?:,[]{}#&*!|>'\"%@`")

    private static func needsQuotes(_ s: String) -> Bool {
        guard let first = s.first, let last = s.last else { return true }
        return reserved.contains(s.lowercased()) || Double(s) != nil || s.lowercased().hasPrefix("0x")
            || specialLeading.contains(first) || first == " " || last == " " || last == ":"
            || s.contains(": ") || s.contains("#") || s.contains("\"") || s.contains("'")
            || s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                out += scalar.value < 0x20 || scalar.value == 0x7F
                    ? String(format: "\\u%04X", scalar.value) : String(scalar)
            }
        }
        return out + "\""
    }

    /// Multi-line text with a leading space or control characters would need
    /// an indentation indicator, so those fall back to a quoted string.
    private static func isBlockScalar(_ s: String) -> Bool {
        let body = s.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        guard body.contains("\n"), !body.hasPrefix(" ") else { return false }
        return !s.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\n") || $0.value == 0x7F }
    }

    private static func blockHeader(_ s: String) -> String {
        if !s.hasSuffix("\n") { return "|-" }
        return s.hasSuffix("\n\n") ? "|+" : "|"
    }

    private static func blockBody(_ s: String, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var parts = s.components(separatedBy: "\n")
        if s.hasSuffix("\n") { parts.removeLast() }
        return parts.map { $0.isEmpty ? "" : pad + $0 }
    }
}

private extension JSONValue {
    var isObject: Bool { objectValue != nil }
}
