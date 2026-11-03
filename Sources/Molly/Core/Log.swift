import Foundation

/// Process-wide logger: stderr plus an append-only file under the data folder.
/// Collectors log and degrade; they never crash the app.
enum Log {
    enum Level: String { case debug, info, warn, error }

    static var minimumLevel: Level = .info
    static var fileURL: URL? = Paths.logFile
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }
    static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    static func warn(_ message: @autoclosure () -> String) { write(.warn, message()) }
    static func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    private static let order: [Level: Int] = [.debug: 0, .info: 1, .warn: 2, .error: 3]

    private static func write(_ level: Level, _ message: String) {
        guard order[level, default: 0] >= order[minimumLevel, default: 0] else { return }
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
        guard let url = fileURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// Well-known file locations. Everything Molly owns lives under one folder so
/// it is easy to back up or delete.
enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var dataFolder: URL {
        if let override = ProcessInfo.processInfo.environment["MOLLY_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Library/Application Support/Molly")
    }

    static var configFile: URL {
        if let override = ProcessInfo.processInfo.environment["MOLLY_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return dataFolder.appendingPathComponent("config.json")
    }

    static var stateFolder: URL { dataFolder.appendingPathComponent("state") }
    static var logFile: URL { dataFolder.appendingPathComponent("molly.log") }

    /// Expands "~" and environment-style "$HOME" in user-supplied paths.
    static func expand(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        if p.hasPrefix("$HOME") {
            p = home.path + p.dropFirst("$HOME".count)
        }
        return p
    }
}
