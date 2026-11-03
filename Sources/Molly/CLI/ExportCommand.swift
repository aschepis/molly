import Foundation

// `molly export` and `molly prune`: backup and retention for the local stack.
// The Prometheus admin API (snapshot, delete_series) is opt-in in Prometheus;
// the stack enables it with --web.enable-admin-api.

/// Pure helpers shared by export, prune, and their tests.
enum Backup {
    static let secretKeys: Set<String> = ["salt", "apiKey", "token"]
    static let adminFlagHint = "Prometheus admin API is disabled. Add `--web.enable-admin-api` to the prometheus "
        + "command in deploy/docker-compose.yml, then `make stack-down && make stack-up`."

    /// Replaces every non-empty secret value, at any depth, with "***".
    static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                if secretKeys.contains(k), case .string(let s) = v, !s.isEmpty {
                    out[k] = .string("***")
                } else {
                    out[k] = redact(v)
                }
            }
            return .object(out)
        case .array(let a):
            return .array(a.map(redact))
        default:
            return value
        }
    }

    static func folderName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "molly-backup-" + f.string(from: date)
    }

    static func defaultBackupsFolder() -> URL {
        Paths.dataFolder.appendingPathComponent("backups")
    }

    /// The Prometheus data folder: the config key wins, then a source
    /// checkout's deploy/data/prometheus, then the data folder next to Molly's own.
    static func prometheusDataDir(configured: String?, repoRoot: URL?) -> URL {
        if let configured, !configured.isEmpty {
            return URL(fileURLWithPath: Paths.expand(configured))
        }
        if let env = ProcessInfo.processInfo.environment["MOLLY_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: Paths.expand(env)).appendingPathComponent("prometheus")
        }
        if let repoRoot {
            return repoRoot.appendingPathComponent("deploy/data/prometheus")
        }
        return Paths.dataFolder.appendingPathComponent("prometheus")
    }

    /// Walks up from the working directory and the executable looking for the
    /// checkout that holds deploy/docker-compose.yml.
    static func findRepoRoot(starts: [String]? = nil) -> URL? {
        let candidates = starts ?? [
            FileManager.default.currentDirectoryPath,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path,
        ]
        for start in candidates {
            var dir = URL(fileURLWithPath: start)
            for _ in 0..<8 {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("deploy/docker-compose.yml").path) {
                    return dir
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        return nil
    }

    static func restoreInstructions(tarball: String, dataDir: URL) -> String {
        """
        Restore \(tarball) by hand (Molly never overwrites your history automatically):

          1. Stop the stack:            make stack-down
          2. Unpack the backup:         tar -xzf "\(tarball)" -C /tmp
          3. Replace the TSDB:          rm -rf "\(dataDir.path)"/* && cp -R /tmp/molly-backup-*/prometheus-snapshot/* "\(dataDir.path)/"
          4. Restore Molly's state:     cp -R /tmp/molly-backup-*/state "\(Paths.dataFolder.path)/"
             and config.json if needed (secrets were redacted unless --include-secrets was used)
          5. Start the stack:           make stack-up

        The snapshot is a complete Prometheus data directory; Grafana dashboards
        are provisioned from the repo and need no restore.
        """
    }

    static func humanSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Parses "30d", "12h", "2w", "90m" into seconds.
enum DurationParser {
    static func seconds(_ text: String) -> TimeInterval? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = t.last, let number = Double(t.dropLast()), number > 0 else { return nil }
        switch unit {
        case "m": return number * 60
        case "h": return number * 3600
        case "d": return number * 86400
        case "w": return number * 7 * 86400
        case "y": return number * 365 * 86400
        default: return nil
        }
    }
}

/// Builds the admin API requests `molly prune` sends.
struct PruneRequest {
    let base: URL
    let cutoff: Date
    let job: String

    var deleteSeriesURL: URL {
        var c = URLComponents(url: base.appendingPathComponent("api/v1/admin/tsdb/delete_series"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "match[]", value: "{job=\"\(job)\"}"),
            URLQueryItem(name: "end", value: String(Int(cutoff.timeIntervalSince1970))),
        ]
        return c.url!
    }

    var cleanTombstonesURL: URL {
        base.appendingPathComponent("api/v1/admin/tsdb/clean_tombstones")
    }
}

/// Tiny POST helper; the admin API only answers POST.
enum AdminHTTP {
    static func post(_ url: URL, timeout: TimeInterval = 60) -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var body = Data()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data ?? Data()
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return (status, body)
    }

    /// Prometheus answers "admin APIs disabled" when the flag is missing
    /// (HTTP 500 with a JSON error on v3, 403 on older releases).
    static func adminDisabled(status: Int, body: Data) -> Bool {
        status >= 400 && String(decoding: body, as: UTF8.self).lowercased().contains("admin apis disabled")
    }
}

enum ExportCommand {
    static func run(_ arguments: [String]) {
        var out: URL?
        var includeSecrets = false
        var restore: String?
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--out":
                if let path = iterator.next() { out = URL(fileURLWithPath: Paths.expand(path)) }
            case "--include-secrets": includeSecrets = true
            case "--restore":
                restore = iterator.next()
            default:
                FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8))
                exit(2)
            }
        }
        let config = (try? Config.load()) ?? Config()
        let dataDir = Backup.prometheusDataDir(configured: config.export.prometheusDataDir, repoRoot: Backup.findRepoRoot())
        if let restore {
            print(Backup.restoreInstructions(tarball: restore, dataDir: dataDir))
            return
        }
        do {
            let tarball = try export(config: config, into: out ?? Backup.defaultBackupsFolder(),
                                     includeSecrets: includeSecrets, dataDir: dataDir)
            let size = (try? FileManager.default.attributesOfItem(atPath: tarball.path)[.size] as? Int64) ?? 0
            print("backup: \(tarball.path) (\(Backup.humanSize(size)))")
            print("restore with: molly export --restore \"\(tarball.path)\"")
        } catch {
            FileHandle.standardError.write(Data("export failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Builds the backup folder, tars it, removes the folder, returns the tarball.
    static func export(config: Config, into parent: URL, includeSecrets: Bool, dataDir: URL,
                       now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let folder = parent.appendingPathComponent(Backup.folderName(for: now))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // 1. config.json, redacted unless asked otherwise.
        if let data = try? Data(contentsOf: Paths.configFile) {
            let json = try JSONValue.parse(data)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let outJSON = includeSecrets ? json : Backup.redact(json)
            try encoder.encode(outJSON).write(to: folder.appendingPathComponent("config.json"))
            print("config:   \(includeSecrets ? "copied" : "copied with secrets redacted")")
        } else {
            print("config:   none (defaults in use)")
        }

        // 2. state and insights folders.
        for name in ["state", "insights"] {
            let source = Paths.dataFolder.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: folder.appendingPathComponent(name))
                print("\(name.padding(toLength: 9, withPad: " ", startingAt: 0)) copied")
            } else {
                print("\(name.padding(toLength: 9, withPad: " ", startingAt: 0)) none")
            }
        }

        // 3. current /metrics text when the daemon answers.
        let probeHost = config.server.bind == "0.0.0.0" ? "127.0.0.1" : config.server.bind
        if let url = URL(string: "http://\(probeHost):\(config.server.port)/metrics") {
            let (status, body) = DoctorCommand.fetch(url, timeout: 3)
            if status == 200 {
                try body.write(to: folder.appendingPathComponent("metrics.txt"))
                print("metrics:  snapshot of \(body.count) bytes")
            } else {
                print("metrics:  daemon not answering, skipped")
            }
        }

        // 4. Prometheus TSDB snapshot through the admin API.
        snapshot(prometheusURL: config.links.prometheus, dataDir: dataDir, into: folder)

        // 5. Tar it up.
        let tarball = parent.appendingPathComponent(folder.lastPathComponent + ".tar.gz")
        let result = try Shell.run("tar", ["-czf", tarball.path, "-C", parent.path, folder.lastPathComponent], timeout: 600)
        guard result.succeeded else {
            throw ShellError.launchFailed("tar", result.stderr)
        }
        try fm.removeItem(at: folder)
        return tarball
    }

    private static func snapshot(prometheusURL: String, dataDir: URL, into folder: URL) {
        guard let url = URL(string: prometheusURL + "/api/v1/admin/tsdb/snapshot") else {
            print("tsdb:     bad prometheus url \(prometheusURL)")
            return
        }
        let (status, body) = AdminHTTP.post(url, timeout: 300)
        if AdminHTTP.adminDisabled(status: status, body: body) {
            print("tsdb:     skipped. \(Backup.adminFlagHint)")
            return
        }
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let name = data["name"] as? String else {
            print("tsdb:     snapshot request failed (HTTP \(status)); is Prometheus running at \(prometheusURL)?")
            return
        }
        let source = dataDir.appendingPathComponent("snapshots").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else {
            print("tsdb:     Prometheus wrote snapshot \(name) but \(source.path) is not visible here; set export.prometheusDataDir")
            return
        }
        do {
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("prometheus-snapshot"))
            try FileManager.default.removeItem(at: source)
            print("tsdb:     snapshot \(name) copied")
        } catch {
            print("tsdb:     copy failed: \(error.localizedDescription)")
        }
    }
}

enum PruneCommand {
    static func run(_ arguments: [String]) {
        var olderThan: String?
        var dryRun = false
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--older-than": olderThan = iterator.next()
            case "--dry-run": dryRun = true
            default:
                FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8))
                exit(2)
            }
        }
        guard let olderThan, let seconds = DurationParser.seconds(olderThan) else {
            FileHandle.standardError.write(Data("usage: molly prune --older-than <30d|12h|2w> [--dry-run]\n".utf8))
            exit(2)
        }
        let config = (try? Config.load()) ?? Config()
        guard let base = URL(string: config.links.prometheus) else {
            FileHandle.standardError.write(Data("bad prometheus url \(config.links.prometheus)\n".utf8))
            exit(1)
        }
        let request = PruneRequest(base: base, cutoff: Date().addingTimeInterval(-seconds), job: "molly")
        let f = ISO8601DateFormatter()
        print("prune: delete job=\"molly\" samples older than \(f.string(from: request.cutoff)) (\(olderThan))")
        print("  POST \(request.deleteSeriesURL.absoluteString)")
        print("  POST \(request.cleanTombstonesURL.absoluteString)")
        if dryRun {
            print("dry run: nothing sent")
            return
        }
        let (status, body) = AdminHTTP.post(request.deleteSeriesURL, timeout: 300)
        if AdminHTTP.adminDisabled(status: status, body: body) {
            FileHandle.standardError.write(Data((Backup.adminFlagHint + "\n").utf8))
            exit(1)
        }
        guard status == 204 || status == 200 else {
            FileHandle.standardError.write(Data("delete_series failed: HTTP \(status) \(String(decoding: body.prefix(200), as: UTF8.self))\n".utf8))
            exit(1)
        }
        let (cleanStatus, _) = AdminHTTP.post(request.cleanTombstonesURL, timeout: 600)
        print(cleanStatus == 204 || cleanStatus == 200 ? "pruned and compacted" : "pruned; clean_tombstones returned HTTP \(cleanStatus)")
    }
}
