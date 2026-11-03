import Foundation

/// Cursor's local AI-attribution database. Only row counts and timestamps are
/// read; file names, prompts, summaries and commit messages are never selected.
final class CursorCollector: Collector {
    let name = "cursor"
    let interval: TimeInterval

    /// Timestamps in this database are milliseconds since the Unix epoch.
    private struct Source {
        let table: String
        let column: String
        let metric: String
        let help: String
    }

    private static let sources = [
        Source(table: "ai_code_hashes", column: "createdAt",
               metric: "molly_cursor_ai_code_events_total", help: "AI-generated code hashes recorded by Cursor."),
        Source(table: "scored_commits", column: "scoredAt",
               metric: "molly_cursor_scored_commits_total", help: "Commits scored by Cursor's attribution."),
        Source(table: "conversation_summaries", column: "updatedAt",
               metric: "molly_cursor_conversations_total", help: "Conversation summaries written or updated."),
    ]

    private let databasePath: String
    private let store: StateStore
    private let startedAt: Date
    private var available: Gauge?
    private var counters: [String: Counter] = [:]

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, startedAt: Date = Date()) {
        interval = settings.interval(default: 120)
        databasePath = Paths.expand(settings.string("databasePath", default: "~/.cursor/ai-tracking/ai-code-tracking.db"))
        store = StateStore(collector: "cursor", folder: stateFolder)
        self.startedAt = startedAt
    }

    func start(registry: MetricsRegistry) throws {
        available = registry.gauge("molly_cursor_available", help: "1 when Cursor's tracking database is readable.")
        for source in CursorCollector.sources {
            counters[source.metric] = registry.counter(source.metric, help: source.help)
        }
    }

    func collect() throws {
        let database: SQLiteDatabase
        do {
            database = try SQLiteSnapshot.open(path: databasePath)
        } catch {
            available?.set(0)
            throw error
        }
        available?.set(1)
        for source in CursorCollector.sources {
            do {
                try ingest(source, from: database)
            } catch {
                Log.debug("cursor: \(source.table): \(error)")
            }
        }
        do { try store.save() } catch { Log.warn("cursor: cannot save state: \(error)") }
    }

    private func ingest(_ source: Source, from database: SQLiteDatabase) throws {
        let cursor = store.double(source.table) ?? (startedAt.timeIntervalSince1970 * 1000).rounded(.down)
        let row = try database.query(
            "SELECT count(*) AS n, max(\(source.column)) AS newest FROM \(source.table) WHERE \(source.column) > ?",
            bindings: [.real(cursor)]).first
        let count = row?["n"].int ?? 0
        counters[source.metric]?.add(Double(count))
        store.set(source.table, count > 0 ? (row?["newest"].double ?? cursor) : cursor)
    }
}
