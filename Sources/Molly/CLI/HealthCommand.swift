import Foundation

/// `molly health import`: turns an Apple Health export into an OpenMetrics
/// file that `promtool` can load as historical blocks. Never starts the app.
enum HealthCommand {
    static let defaultOutput = "molly-health.om"
    static let exportEntryName = "export.xml"
    static let promtoolImage = "prom/prometheus:v3.7.3"

    static let usage = "usage: molly health import <export.zip or export.xml> [--out file.om] | molly health status"
    static let statusTimeout: TimeInterval = 3

    static func run(_ arguments: [String]) {
        if arguments.first == "status" { runStatus() }
        guard arguments.first == "import" else { fail(usage) }
        var input: String?
        var output = defaultOutput
        var iterator = arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            if arg == "--out" {
                guard let path = iterator.next() else { fail("--out needs a file name") }
                output = path
            } else if arg.hasPrefix("-") {
                fail("unknown argument \(arg)")
            } else {
                input = arg
            }
        }
        guard let input else { fail(usage) }

        let config = (try? Config.load()) ?? Config()
        let source = URL(fileURLWithPath: Paths.expand(input))
        let destination = URL(fileURLWithPath: Paths.expand(output))
        do {
            let (parser, text) = try importExport(at: source, user: config.constLabels["user"] ?? Config.defaultUser,
                                                  host: config.constLabels["host"] ?? Config.defaultHost)
            try Data(text.utf8).write(to: destination, options: .atomic)
            let dayCount = parser.days.days.count
            print("read \(parser.recordCount) records, used \(parser.usedRecordCount), \(dayCount) days")
            print("wrote \(destination.path)")
            let dataDir = Backup.prometheusDataDir(configured: config.export.prometheusDataDir, repoRoot: Backup.findRepoRoot())
            print(instructions(file: destination, dataDir: dataDir))
        } catch {
            FileHandle.standardError.write(Data("import failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Asks the running daemon, using the token from the local config.
    private static func runStatus() -> Never {
        let config = (try? Config.load()) ?? Config()
        let token = config.collector("health").string("token", default: "")
        guard !token.isEmpty else { fail("collectors.health.token is not set in \(Paths.configFile.path)") }
        guard let url = URL(string: "http://\(config.server.bind):\(config.server.port)/health/status") else {
            fail("cannot build the status URL from server.bind")
        }
        let (code, data) = fetchStatus(url, token: token)
        switch code {
        case 200:
            guard let tree = (try? JSONValue.parse(data))?.objectValue else { fail("unexpected reply from the daemon") }
            print(statusTable(tree, now: Date()))
            exit(0)
        case 0: fail("molly is not running at \(url.host ?? ""):\(config.server.port) (start it with: molly run)", code: 1)
        case 401: fail("the daemon rejected the token: it differs from collectors.health.token in the config", code: 1)
        case 403: fail("the daemon refuses health data on this bind: see docs/HEALTH.md (allowRemoteBind)", code: 1)
        case 503: fail("the health collector is disabled: set collectors.health.enabled to true", code: 1)
        default: fail("daemon answered HTTP \(code)", code: 1)
        }
    }

    private static func fetchStatus(_ url: URL, token: String) -> (Int, Data) {
        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var body = Data()
        var request = URLRequest(url: url)
        request.timeoutInterval = statusTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data ?? Data()
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return (status, body)
    }

    static func statusTable(_ tree: [String: JSONValue], now: Date) -> String {
        var lines: [String] = []
        if let posted = tree["last_post"]?.doubleValue {
            let age = Int(now.timeIntervalSince1970 - posted)
            lines.append("last post   \(age)s ago")
        } else {
            lines.append("last post   never")
        }
        let devices = (tree["devices"]?.arrayValue ?? []).compactMap { $0.stringValue }
        lines.append("devices     \(devices.isEmpty ? "none" : devices.joined(separator: ", "))")
        let today = tree["today"]?.objectValue ?? [:]
        let yesterday = tree["yesterday"]?.objectValue ?? [:]
        let names = Set(today.keys).union(yesterday.keys).sorted()
        lines.append("")
        lines.append("type".padding(toLength: statusColumnWidth, withPad: " ", startingAt: 0) + "today".padding(toLength: 14, withPad: " ", startingAt: 0) + "yesterday")
        for name in names {
            lines.append(name.padding(toLength: statusColumnWidth, withPad: " ", startingAt: 0)
                + cell(today[name]).padding(toLength: 14, withPad: " ", startingAt: 0) + cell(yesterday[name]))
        }
        if names.isEmpty { lines.append("(no values stored for today or yesterday)") }
        return lines.joined(separator: "\n")
    }

    private static let statusColumnWidth = 28

    private static func cell(_ value: JSONValue?) -> String {
        guard let number = value?.doubleValue else { return "-" }
        return number == number.rounded() ? String(Int(number)) : String(format: "%.2f", number)
    }

    static func importExport(at source: URL, user: String, host: String) throws -> (HealthExportParser, String) {
        var xml = source
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        if source.pathExtension.lowercased() == "zip" {
            temporary = try extractExport(from: source)
            xml = temporary ?? source
        }
        guard let stream = InputStream(url: xml) else { throw CocoaError(.fileReadNoSuchFile) }
        let parser = HealthExportParser()
        try parser.parse(XMLParser(stream: stream))
        return (parser, HealthOpenMetrics.render(parser.days, user: user, host: host))
    }

    /// Streams the XML out of the zip into a temp file; the parser then reads
    /// it from disk, so memory use does not depend on the export's size.
    private static func extractExport(from zip: URL) throws -> URL {
        let listing = try Shell.run("/usr/bin/unzip", ["-Z1", zip.path], timeout: 60)
        let entries = listing.stdout.split(separator: "\n").map(String.init)
        guard let entry = entries.first(where: { $0 == exportEntryName || $0.hasSuffix("/" + exportEntryName) }) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "no \(exportEntryName) inside \(zip.lastPathComponent)"])
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("molly-health-\(UUID().uuidString).xml")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zip.path, entry]
        process.standardOutput = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: target)
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "unzip failed for \(zip.lastPathComponent)"])
        }
        return target
    }

    static func instructions(file: URL, dataDir: URL) -> String {
        """

        Load it into Prometheus. promtool writes blocks straight into the data
        directory, so Prometheus must be stopped (or the blocks moved in while
        it is down):

          make stack-down
          promtool tsdb create-blocks-from openmetrics "\(file.path)" "\(dataDir.path)"
          make stack-up

        Without promtool installed, use the image the stack runs:

          docker run --rm -v "\(file.deletingLastPathComponent().path):/in" -v "\(dataDir.path):/data" \\
            --entrypoint promtool \(promtoolImage) tsdb create-blocks-from openmetrics /in/\(file.lastPathComponent) /data

        The Body dashboard reads the result as molly_health_day{type}.
        """
    }

    private static func fail(_ message: String, code: Int32 = 2) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
