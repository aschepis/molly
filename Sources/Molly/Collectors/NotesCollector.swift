import Foundation

/// Apple Notes activity from NoteStore.sqlite. Note titles and bodies are
/// never selected; folder names are read only to group counts and are
/// published only when the `folders` label policy is enabled.
enum NotesQueries {
    /// Notes have a title in ZTITLE1; folders use ZTITLE2. Notes in the
    /// "Recently Deleted" folder (ZFOLDERTYPE 1) and tombstones are excluded.
    private static let liveNotes = """
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
        WHERE n.ZTITLE1 IS NOT NULL AND COALESCE(n.ZMARKEDFORDELETION, 0) = 0 AND COALESCE(f.ZFOLDERTYPE, 0) != 1
        """

    static func noteCount(db: SQLiteDatabase) throws -> Int {
        Int(try db.scalar("SELECT count(*) \(liveNotes)").int ?? 0)
    }

    static func folderCount(db: SQLiteDatabase) throws -> Int {
        Int(try db.scalar("""
            SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT
            WHERE ZTITLE2 IS NOT NULL AND COALESCE(ZMARKEDFORDELETION, 0) = 0 AND COALESCE(ZFOLDERTYPE, 0) != 1
            """).int ?? 0)
    }

    /// Notes created in (after, upTo], dates in seconds since 2001.
    static func created(db: SQLiteDatabase, after: Double, upTo: Double) throws -> Int {
        Int(try db.scalar("SELECT count(*) \(liveNotes) AND n.ZCREATIONDATE1 > ? AND n.ZCREATIONDATE1 <= ?",
                          bindings: [.real(after), .real(upTo)]).int ?? 0)
    }

    static func modified(db: SQLiteDatabase, after: Double, upTo: Double) throws -> Int {
        Int(try db.scalar("SELECT count(*) \(liveNotes) AND n.ZMODIFICATIONDATE1 > ? AND n.ZMODIFICATIONDATE1 <= ?",
                          bindings: [.real(after), .real(upTo)]).int ?? 0)
    }

    static func modifiedByFolder(db: SQLiteDatabase, after: Double, upTo: Double) throws -> [String: Double] {
        let rows = try db.query("""
            SELECT f.ZTITLE2 AS folder, count(*) AS n \(liveNotes)
            AND n.ZMODIFICATIONDATE1 > ? AND n.ZMODIFICATIONDATE1 <= ? GROUP BY f.ZTITLE2
            """, bindings: [.real(after), .real(upTo)])
        var counts: [String: Double] = [:]
        for row in rows {
            counts[row["folder"].string ?? "", default: 0] += Double(row["n"].int ?? 0)
        }
        return counts
    }
}

final class NotesCollector: Collector {
    static let foldersDefaults = LabelPolicy(enabled: false, mode: .denylist, maxCardinality: 50)
    static let defaultPath = "~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    static let cursorKey = "cursor.seconds"

    let name = "notes"
    let interval: TimeInterval

    private let path: String
    private let folderFilter: LabelFilter
    private let store: StateStore
    private let startedAt: Date
    private let now: () -> Date
    private let calendar: Calendar

    private var count: Gauge?
    private var folders: Gauge?
    private var createdTotal: Counter?
    private var modifiedTotal: Counter?
    private var createdToday: Gauge?
    private var modifiedToday: Gauge?
    private var folderModifiedTotal: Counter?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) throws {
        interval = settings.interval(default: 120)
        path = Paths.expand(settings.string("path", default: NotesCollector.defaultPath))
        folderFilter = try settings.filter("folders", defaults: NotesCollector.foldersDefaults)
        store = StateStore(collector: "notes", folder: stateFolder)
        self.now = now
        self.calendar = calendar
        startedAt = now()
    }

    func start(registry: MetricsRegistry) throws {
        count = registry.gauge("molly_notes_count", help: "Notes that are not deleted.")
        folders = registry.gauge("molly_notes_folders", help: "Note folders, excluding Recently Deleted.")
        createdTotal = registry.counter("molly_notes_created_total", help: "Notes created since Molly started watching.")
        modifiedTotal = registry.counter("molly_notes_modified_total", help: "Notes created or edited since Molly started watching.")
        createdToday = registry.gauge("molly_notes_created_today", help: "Notes created since local midnight.")
        modifiedToday = registry.gauge("molly_notes_modified_today", help: "Notes created or edited since local midnight.")
        folderModifiedTotal = registry.counter("molly_notes_folder_modified_total", help: "Notes created or edited per folder (needs the folders label policy enabled).", labels: ["folder"])
    }

    func collect() throws {
        let db = try SQLiteSnapshot.open(path: path)
        let current = now()
        let nowSeconds = CocoaTime.cocoaSeconds(current)
        let dayStart = CocoaTime.cocoaSeconds(calendar.startOfDay(for: current))

        count?.set(try NotesQueries.noteCount(db: db))
        folders?.set(try NotesQueries.folderCount(db: db))
        createdToday?.set(try NotesQueries.created(db: db, after: dayStart, upTo: nowSeconds))
        modifiedToday?.set(try NotesQueries.modified(db: db, after: dayStart, upTo: nowSeconds))

        let cursor = store.double(NotesCollector.cursorKey) ?? CocoaTime.cocoaSeconds(startedAt)
        createdTotal?.add(Double(try NotesQueries.created(db: db, after: cursor, upTo: nowSeconds)))
        modifiedTotal?.add(Double(try NotesQueries.modified(db: db, after: cursor, upTo: nowSeconds)))
        if folderFilter.enabled {
            let byFolder = folderFilter.labels(try NotesQueries.modifiedByFolder(db: db, after: cursor, upTo: nowSeconds))
            for (folder, n) in byFolder { folderModifiedTotal?.add(n, labels: ["folder": folder]) }
        }
        store.set(NotesCollector.cursorKey, max(cursor, nowSeconds))
        try store.save()
    }
}
