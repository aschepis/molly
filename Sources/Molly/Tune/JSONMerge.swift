import Foundation

/// Deep merge for config patches: objects merge key by key, every other
/// value (arrays included) is replaced by the patch.
enum JSONMerge {
    static func merge(_ base: JSONValue, _ patch: JSONValue) -> JSONValue {
        guard case .object(let b) = base, case .object(let p) = patch else { return patch }
        var out = b
        for (k, v) in p {
            out[k] = merge(b[k] ?? .object([:]), v)
        }
        return .object(out)
    }

    /// Dotted paths whose value differs between the two trees (added or changed).
    static func changedPaths(_ before: JSONValue, _ after: JSONValue, prefix: String = "") -> [String] {
        guard case .object(let a) = after else {
            return before == after ? [] : [prefix.isEmpty ? "(root)" : prefix]
        }
        let b = before.objectValue ?? [:]
        var paths: [String] = []
        for key in a.keys.sorted() {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            let old = b[key] ?? .null
            let new = a[key] ?? .null
            if case .object = new, case .object = old {
                paths += changedPaths(old, new, prefix: path)
            } else if old != new {
                paths.append(path)
            }
        }
        return paths
    }

    static func prettyData(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
