import XCTest
import SQLite3
@testable import Molly

final class StorageTests: XCTestCase {
    private func makeTempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("molly-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeDatabase(at path: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, score REAL, data BLOB);
        INSERT INTO t(name, score, data) VALUES ('a', 1.5, x'0102'), ('b', 2, NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
    }

    func testSnapshotCopiesWalAndReadsTypedValues() throws {
        let folder = makeTempFolder()
        let path = folder.appendingPathComponent("src.db").path
        makeDatabase(at: path)
        let db = try SQLiteSnapshot.open(path: path)
        let rows = try db.query("SELECT id, name, score, data FROM t WHERE score >= ? ORDER BY id", bindings: [.real(1)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["name"].string, "a")
        XCTAssertEqual(rows[0]["score"].double, 1.5)
        XCTAssertEqual(rows[0]["data"], .blob(Data([1, 2])))
        XCTAssertEqual(rows[1]["id"].int, 2)
        XCTAssertEqual(rows[1]["data"], .null)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM t").int, 2)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM t WHERE name = ?", bindings: [.text("a")]).int, 1)
    }

    func testSnapshotOfMissingFileIsUnavailable() {
        XCTAssertThrowsError(try SQLiteSnapshot.open(path: "/nonexistent/x.db")) { error in
            XCTAssertTrue(error is CollectorUnavailable)
        }
    }

    func testBadSQLThrows() throws {
        let folder = makeTempFolder()
        let path = folder.appendingPathComponent("src.db").path
        makeDatabase(at: path)
        let db = try SQLiteSnapshot.open(path: path)
        XCTAssertThrowsError(try db.query("SELECT nope FROM t"))
    }

    func testStateStoreRoundTrips() throws {
        let folder = makeTempFolder()
        let store = StateStore(collector: "browser", folder: folder)
        XCTAssertNil(store.string("cursor"))
        store.set("cursor", "abc")
        store.set("count", 3)
        store.set("when", 1.5)
        try store.save()
        let reloaded = StateStore(collector: "browser", folder: folder)
        XCTAssertEqual(reloaded.string("cursor"), "abc")
        XCTAssertEqual(reloaded.int("count"), 3)
        XCTAssertEqual(reloaded.double("when"), 1.5)
    }

    func testEpochConversions() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(CocoaTime.date(cocoaSeconds: CocoaTime.cocoaSeconds(date)), date)
        XCTAssertEqual(CocoaTime.date(cocoaNanoseconds: CocoaTime.cocoaNanoseconds(date)).timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(CocoaTime.date(webKitMicroseconds: CocoaTime.webKitMicroseconds(date)).timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(CocoaTime.date(cocoaSeconds: 0).timeIntervalSince1970, 978_307_200)
    }

    func testShellRunsAndTimesOut() throws {
        let result = try Shell.run("echo", ["hi"])
        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertTrue(result.succeeded)
        XCTAssertThrowsError(try Shell.run("sleep", ["5"], timeout: 0.2))
        XCTAssertNotNil(Shell.which("ls"))
    }
}
