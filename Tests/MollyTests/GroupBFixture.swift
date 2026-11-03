import XCTest
import SQLite3
@testable import Molly

/// Temp SQLite files shaped like other apps' databases, for Group B collector tests.
class GroupBTestCase: XCTestCase {
    func makeFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("molly-groupb-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func makeDatabase(_ sql: String) -> String {
        let path = makeFolder().appendingPathComponent("fixture.db").path
        execute(sql, at: path)
        return path
    }

    func execute(_ sql: String, at path: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        sqlite3_close(db)
    }

    func open(_ path: String) throws -> SQLiteDatabase { try SQLiteDatabase.open(path: path) }

    func settings(_ name: String, _ raw: [String: JSONValue]) -> CollectorSettings {
        CollectorSettings(name: name, raw: raw)
    }

    /// Renders the registry and returns the value of the sample whose line starts with `prefix`.
    func sample(_ registry: MetricsRegistry, _ prefix: String) -> Double? {
        for line in registry.render().split(separator: "\n") where line.hasPrefix(prefix) {
            return line.split(separator: " ").last.flatMap { Double($0) }
        }
        return nil
    }

    /// A UTC calendar and a fixed "now" at 2023-11-14 12:00:00 UTC keep day boundaries deterministic.
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    let noon = Date(timeIntervalSince1970: 1_699_963_200)
    var midnight: Date { Date(timeIntervalSince1970: 1_699_920_000) }
}
