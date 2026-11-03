import XCTest
@testable import Molly

final class NotesCollectorTests: GroupBTestCase {
    private func cocoa(_ date: Date) -> Double { CocoaTime.cocoaSeconds(date) }

    /// Folders 1 (Work) and 2 (Recently Deleted, type 1); three live notes, one trashed, one tombstoned.
    private func fixture() -> String {
        makeDatabase("""
            CREATE TABLE ZICCLOUDSYNCINGOBJECT(Z_PK INTEGER PRIMARY KEY, ZTITLE1 TEXT, ZTITLE2 TEXT, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER,
                ZCREATIONDATE1 REAL, ZMODIFICATIONDATE1 REAL, ZMARKEDFORDELETION INTEGER);
            INSERT INTO ZICCLOUDSYNCINGOBJECT(Z_PK, ZTITLE2, ZFOLDERTYPE) VALUES (1, 'Work', 0), (2, 'Recently Deleted', 1);
            INSERT INTO ZICCLOUDSYNCINGOBJECT(ZTITLE1, ZFOLDER, ZCREATIONDATE1, ZMODIFICATIONDATE1, ZMARKEDFORDELETION) VALUES
              ('old note', 1, \(cocoa(noon) - 86400 * 30), \(cocoa(noon) - 86400 * 2), 0),
              ('new today', 1, \(cocoa(noon) - 600), \(cocoa(noon) - 600), 0),
              ('edited today', 1, \(cocoa(noon) - 86400 * 9), \(cocoa(noon) - 300), 0),
              ('trashed', 2, \(cocoa(noon) - 100), \(cocoa(noon) - 100), 0),
              ('tombstone', 1, \(cocoa(noon) - 100), \(cocoa(noon) - 100), 1);
            """)
    }

    func testQueries() throws {
        let db = try open(fixture())
        let dayStart = cocoa(midnight)
        let now = cocoa(noon)
        XCTAssertEqual(try NotesQueries.noteCount(db: db), 3)
        XCTAssertEqual(try NotesQueries.folderCount(db: db), 1)
        XCTAssertEqual(try NotesQueries.created(db: db, after: dayStart, upTo: now), 1)
        XCTAssertEqual(try NotesQueries.modified(db: db, after: dayStart, upTo: now), 2)
        XCTAssertEqual(try NotesQueries.modified(db: db, after: now - 400, upTo: now), 1, "cursor excludes older edits")
        XCTAssertEqual(try NotesQueries.modifiedByFolder(db: db, after: dayStart, upTo: now), ["Work": 2])
    }

    func testCollectorPublishesGaugesAndGatesFolders() throws {
        let path = fixture()
        let collector = try NotesCollector(settings: settings("notes", ["path": .string(path)]), stateFolder: makeFolder(), now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        try collector.collect()
        XCTAssertEqual(sample(registry, "molly_notes_count "), 3)
        XCTAssertEqual(sample(registry, "molly_notes_folders "), 1)
        XCTAssertEqual(sample(registry, "molly_notes_created_today "), 1)
        XCTAssertEqual(sample(registry, "molly_notes_modified_today "), 2)
        XCTAssertEqual(sample(registry, "molly_notes_modified_total "), 0, "no backfill on first run")
        XCTAssertFalse(registry.render().contains("Work"))
        XCTAssertFalse(registry.render().contains("work"))
    }

    func testCursorCountsLaterEditsOnce() throws {
        let path = fixture()
        let state = makeFolder()
        let config: [String: JSONValue] = ["path": .string(path), "folders": .object(["enabled": .bool(true)])]
        let first = try NotesCollector(settings: settings("notes", config), stateFolder: state, now: { self.noon }, calendar: utc)
        let registry = MetricsRegistry()
        try first.start(registry: registry)
        try first.collect()

        execute("UPDATE ZICCLOUDSYNCINGOBJECT SET ZMODIFICATIONDATE1 = \(cocoa(noon) + 30) WHERE ZTITLE1 = 'old note'", at: path)
        let second = try NotesCollector(settings: settings("notes", config), stateFolder: state, now: { self.noon.addingTimeInterval(60) }, calendar: utc)
        let registry2 = MetricsRegistry()
        try second.start(registry: registry2)
        try second.collect()
        try second.collect()
        XCTAssertEqual(sample(registry2, "molly_notes_modified_total "), 1)
        XCTAssertEqual(sample(registry2, "molly_notes_folder_modified_total{folder=\"work\"}"), 1)
    }
}
