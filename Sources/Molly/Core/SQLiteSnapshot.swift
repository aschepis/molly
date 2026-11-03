import Foundation
import SQLite3

enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)

    var description: String {
        switch self {
        case .open(let m): return "sqlite open: \(m)"
        case .prepare(let m): return "sqlite prepare: \(m)"
        case .step(let m): return "sqlite step: \(m)"
        }
    }
}

enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var int: Int64? {
        switch self {
        case .integer(let i): return i
        case .real(let d): return Int64(d)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .real(let d): return d
        case .text(let s): return Double(s)
        default: return nil
        }
    }
    var string: String? {
        switch self {
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .real(let d): return String(d)
        default: return nil
        }
    }
}

struct SQLiteRow {
    let columns: [String: SQLiteValue]
    subscript(name: String) -> SQLiteValue { columns[name] ?? .null }
}

/// A read-only SQLite handle. Use `SQLiteSnapshot.open` for files owned by
/// other apps: it copies the database (and its -wal/-shm) first, because the
/// owner may hold an exclusive lock and we must never write to their file.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let cleanup: (() -> Void)?

    fileprivate init(path: String, cleanup: (() -> Void)?) throws {
        self.cleanup = cleanup
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let db { sqlite3_close(db) }
            cleanup?()
            throw SQLiteError.open("\(path): \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }

    /// Opens an SQLite file in place, read-only. For Molly's own files.
    static func open(path: String) throws -> SQLiteDatabase {
        try SQLiteDatabase(path: path, cleanup: nil)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
        cleanup?()
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        guard let handle else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, i)
            case .integer(let n): sqlite3_bind_int64(statement, i, n)
            case .real(let d): sqlite3_bind_double(statement, i, d)
            case .text(let s): sqlite3_bind_text(statement, i, s, -1, transient)
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32(data.count), transient) }
            }
        }
        let columnCount = Int(sqlite3_column_count(statement))
        let names = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var rows: [SQLiteRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError.step(String(cString: sqlite3_errmsg(handle))) }
            var columns: [String: SQLiteValue] = [:]
            for c in 0..<columnCount {
                let col = Int32(c)
                switch sqlite3_column_type(statement, col) {
                case SQLITE_INTEGER: columns[names[c]] = .integer(sqlite3_column_int64(statement, col))
                case SQLITE_FLOAT: columns[names[c]] = .real(sqlite3_column_double(statement, col))
                case SQLITE_TEXT: columns[names[c]] = .text(String(cString: sqlite3_column_text(statement, col)))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(statement, col)
                    if let base = sqlite3_column_blob(statement, col), bytes > 0 {
                        columns[names[c]] = .blob(Data(bytes: base, count: Int(bytes)))
                    } else {
                        columns[names[c]] = .blob(Data())
                    }
                default: columns[names[c]] = .null
                }
            }
            rows.append(SQLiteRow(columns: columns))
        }
        return rows
    }

    /// Convenience for single-value queries like SELECT count(*).
    func scalar(_ sql: String, bindings: [SQLiteValue] = []) throws -> SQLiteValue {
        guard let row = try query(sql, bindings: bindings).first, let first = row.columns.values.first else {
            return .null
        }
        return first
    }
}

enum SQLiteSnapshot {
    /// Copies `path` (plus -wal and -shm if present) into a private temp folder
    /// and opens the copy read-only. The temp folder is removed on close.
    static func open(path: String) throws -> SQLiteDatabase {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: path) else {
            throw CollectorUnavailable(reason: "\(path) is not readable (missing file or Full Disk Access)")
        }
        let folder = fm.temporaryDirectory.appendingPathComponent("molly-snap-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("db.sqlite")
        do {
            try fm.copyItem(atPath: path, toPath: destination.path)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
                try fm.copyItem(atPath: path + suffix, toPath: destination.path + suffix)
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw CollectorUnavailable(reason: "cannot copy \(path): \(error.localizedDescription)")
        }
        return try SQLiteDatabase(path: destination.path, cleanup: { try? fm.removeItem(at: folder) })
    }
}
