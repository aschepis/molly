import Foundation

/// Reads only the bytes appended to a growing text file since `offset`.
/// A trailing line without a newline is left for the next run.
struct TailChunk: Equatable {
    var lines: [String]
    var offset: Int
}

enum FileTail {
    /// Upper bound per run so one huge backlog cannot stall a collector.
    static let maxChunkBytes = 16 * 1024 * 1024

    static func read(path: String, from offset: Int) throws -> TailChunk {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        // A shrunken file was rewritten (history compaction); do not replay it.
        guard size > offset else { return TailChunk(lines: [], offset: min(offset, size)) }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(size - offset, maxChunkBytes)) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return TailChunk(lines: [], offset: offset) }
        let complete = data[data.startIndex...lastNewline]
        let lines = String(decoding: complete, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return TailChunk(lines: lines, offset: offset + complete.count)
    }

    /// New files that appear after Molly started are read from the top; files
    /// that already existed are skipped to their end so history is never
    /// backfilled into a counter. Birth time is used rather than mtime because
    /// a long-running session file is modified after start but holds old data.
    static func isNewFile(created: Date?, modified: Date?, startedAt: Date) -> Bool {
        (created ?? modified ?? .distantPast) >= startedAt
    }

    static func initialOffset(size: Int, created: Date?, modified: Date?, startedAt: Date) -> Int {
        isNewFile(created: created, modified: modified, startedAt: startedAt) ? 0 : size
    }
}

/// Per-file byte offsets persisted in a collector's StateStore.
final class OffsetTable {
    private let store: StateStore
    private let key: String
    private var offsets: [String: Int] = [:]

    init(store: StateStore, key: String = "offsets") {
        self.store = store
        self.key = key
        for (path, value) in store.get(key)?.objectValue ?? [:] {
            if let n = value.intValue { offsets[path] = n }
        }
    }

    func offset(for path: String) -> Int? { offsets[path] }
    func set(_ offset: Int, for path: String) { offsets[path] = offset }

    func prune(keeping live: Set<String>) {
        offsets = offsets.filter { live.contains($0.key) }
    }

    func save() {
        store.set(key, .object(offsets.mapValues { .number(Double($0)) }))
        do {
            try store.save()
        } catch {
            Log.warn("cannot save state for \(key): \(error)")
        }
    }
}

/// Applies a LabelFilter and keeps the number of distinct label values a
/// counter has ever used under `maxCardinality`, folding latecomers into "other".
final class LabelLimiter {
    let filter: LabelFilter
    private var known = Set<String>()

    init(filter: LabelFilter) { self.filter = filter }

    var enabled: Bool { filter.enabled }

    func label(_ raw: String) -> String {
        let value = filter.label(raw)
        if value == LabelPolicy.other || value == LabelPolicy.redacted || known.contains(value) { return value }
        if filter.maxCardinality > 0, known.count >= filter.maxCardinality { return LabelPolicy.other }
        known.insert(value)
        return value
    }
}

enum Clock {
    static func startOfToday(now: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: now)
    }
}

/// Environment for read-only git calls: never take index.lock or refresh the index.
enum GitEnvironment {
    static var readOnly: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }
}
