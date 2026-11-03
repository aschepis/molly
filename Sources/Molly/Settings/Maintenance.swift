import Foundation

/// Housekeeping the Settings window exposes: forgetting collector cursors and
/// changing the stack's Prometheus retention. Neither touches Prometheus
/// history; `molly prune` does that.
enum Maintenance {
    static let envKey = "PROMETHEUS_RETENTION"

    /// Collector name to its cursor file, for every collector that has one.
    static func stateFiles(folder: URL = Paths.stateFolder) -> [String: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var files: [String: URL] = [:]
        for name in names where name.hasSuffix(".json") {
            files[String(name.dropLast(".json".count))] = folder.appendingPathComponent(name)
        }
        return files
    }

    /// Removes the collector's cursor file so its next run starts fresh.
    @discardableResult
    static func forget(collector: String, folder: URL = Paths.stateFolder) throws -> [URL] {
        guard let file = stateFiles(folder: folder)[collector] else { return [] }
        try FileManager.default.removeItem(at: file)
        return [file]
    }

    @discardableResult
    static func forgetAll(folder: URL = Paths.stateFolder) throws -> [URL] {
        var removed: [URL] = []
        for (_, file) in stateFiles(folder: folder).sorted(by: { $0.key < $1.key }) {
            try FileManager.default.removeItem(at: file)
            removed.append(file)
        }
        return removed
    }

    /// Replaces or appends the retention line, keeping every other line as is.
    static func rewriteEnv(_ contents: String, retention: String) -> String {
        let line = "\(envKey)=\(retention)"
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var replaced = false
        for (i, existing) in lines.enumerated() where existing.hasPrefix("\(envKey)=") {
            lines[i] = line
            replaced = true
        }
        if !replaced { lines.append(line) }
        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    static func writeRetention(_ retention: String, composeDir: URL) throws -> URL {
        guard PrometheusDuration.isValid(retention) else {
            throw ConfigError.invalid("retention must be a Prometheus duration like 90d or 2y")
        }
        let env = composeDir.appendingPathComponent(".env")
        let existing = (try? String(contentsOf: env, encoding: .utf8)) ?? ""
        try rewriteEnv(existing, retention: retention).write(to: env, atomically: true, encoding: .utf8)
        return env
    }

    typealias Runner = (_ command: String, _ arguments: [String], _ directory: String) throws -> String

    /// `docker compose` reads `.env` on every `up`, so recreating the service
    /// is what applies the new flag.
    static let composeRunner: Runner = { command, arguments, directory in
        let result = try Shell.run(command, arguments, timeout: 120, currentDirectory: directory)
        guard result.succeeded else {
            throw ConfigError.invalid("\(command) \(arguments.joined(separator: " ")) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout + result.stderr
    }

    static func applyRetention(_ retention: String, composeDir: URL, run: Runner = composeRunner) throws -> String {
        let compose = composeDir.appendingPathComponent("docker-compose.yml")
        guard FileManager.default.fileExists(atPath: compose.path) else {
            throw ConfigError.invalid("no docker-compose.yml in \(composeDir.path)")
        }
        let env = try writeRetention(retention, composeDir: composeDir)
        let output = try run("docker", ["compose", "up", "-d", "prometheus"], composeDir.path)
        return "wrote \(env.path)\n" + output
    }

    /// The deploy folder of a source checkout, found the same way `molly export`
    /// finds the Prometheus data dir.
    static func defaultComposeDir() -> URL? {
        Backup.findRepoRoot()?.appendingPathComponent("deploy")
    }
}
