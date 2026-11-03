import Foundation

/// The config file as an editable JSON tree. Every edit from the Settings
/// window goes through here so keys Molly does not understand survive a save.
struct ConfigDocument: Equatable {
    static let maxBackups = 10
    static let backupPrefix = "config.json.bak-"

    let url: URL
    var root: JSONValue

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            root = .object([:])
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable("\(url.path): \(error.localizedDescription)")
        }
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(data)
        } catch {
            throw ConfigError.invalid("not valid JSON: \(error.localizedDescription)")
        }
        guard parsed.objectValue != nil else { throw ConfigError.invalid("top level must be an object") }
        root = parsed
    }

    init(url: URL, root: JSONValue) {
        self.url = url
        self.root = root
    }

    func get(path: [String]) -> JSONValue? {
        var node = root
        for key in path {
            guard let object = node.objectValue, let next = object[key] else { return nil }
            node = next
        }
        return node
    }

    /// `nil` removes the key. Intermediate objects are created on the way down;
    /// a non-object in the way is replaced, since the path says it must be one.
    mutating func set(path: [String], _ value: JSONValue?) {
        guard !path.isEmpty else { return }
        root = ConfigDocument.replacing(root, path[...], with: value)
    }

    private static func replacing(_ node: JSONValue, _ path: ArraySlice<String>, with value: JSONValue?) -> JSONValue {
        guard let key = path.first else { return value ?? .null }
        var object = node.objectValue ?? [:]
        if path.count == 1 {
            if let value {
                object[key] = value
            } else {
                object.removeValue(forKey: key)
            }
        } else {
            object[key] = replacing(object[key] ?? .object([:]), path.dropFirst(), with: value)
        }
        return .object(object)
    }

    /// Sorted keys because `JSONValue.object` is an unordered dictionary;
    /// a stable order keeps diffs between backups readable.
    func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(root)
        data.append(0x0A)
        return data
    }

    /// The parsed form of the current tree, or the reason it would be rejected.
    func validate() throws -> Config {
        try Config.parse(serialized())
    }

    /// Validates first so a bad edit never reaches disk, then backs up the
    /// previous file and writes atomically.
    func save(now: Date = Date()) throws {
        let data = try serialized()
        _ = try Config.parse(data)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent(ConfigDocument.backupName(for: now))
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.copyItem(at: url, to: backup)
            try ConfigDocument.pruneBackups(of: url)
        }
        try data.write(to: url, options: .atomic)
    }

    static func backupName(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return backupPrefix + f.string(from: date)
    }

    /// Oldest first; the timestamp suffix sorts lexically.
    static func backups(of url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(backupPrefix) }.sorted().map { folder.appendingPathComponent($0) }
    }

    private static func pruneBackups(of url: URL) throws {
        let all = backups(of: url)
        guard all.count > maxBackups else { return }
        for old in all.prefix(all.count - maxBackups) {
            try FileManager.default.removeItem(at: old)
        }
    }
}
