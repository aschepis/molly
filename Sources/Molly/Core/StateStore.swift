import Foundation

/// Small key/value persistence for collector cursors (last imported row,
/// last seen commit) so counters survive restarts without double counting.
/// One JSON file per collector under the state folder.
final class StateStore {
    /// `molly once` runs beside a daemon; it must read cursors but never
    /// advance them, or it would steal deltas the daemon should count.
    static var persistenceEnabled = true

    private let url: URL
    private var values: [String: JSONValue]
    private let lock = NSLock()

    init(collector: String, folder: URL = Paths.stateFolder) {
        url = folder.appendingPathComponent("\(collector).json")
        if let data = try? Data(contentsOf: url), let json = try? JSONValue.parse(data), let o = json.objectValue {
            values = o
        } else {
            values = [:]
        }
    }

    func string(_ key: String) -> String? { get(key)?.stringValue }
    func double(_ key: String) -> Double? { get(key)?.doubleValue }
    func int(_ key: String) -> Int? { get(key)?.intValue }

    func get(_ key: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: JSONValue) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    func set(_ key: String, _ value: String) { set(key, .string(value)) }
    func set(_ key: String, _ value: Double) { set(key, .number(value)) }
    func set(_ key: String, _ value: Int) { set(key, .number(Double(value))) }

    func save() throws {
        guard StateStore.persistenceEnabled else { return }
        lock.lock()
        let snapshot = values
        lock.unlock()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
