import Foundation

/// `molly health import`: turns an Apple Health export into an OpenMetrics
/// file that `promtool` can load as historical blocks. Never starts the app.
enum HealthCommand {
    static let defaultOutput = "molly-health.om"
    static let exportEntryName = "export.xml"
    static let promtoolImage = "prom/prometheus:v3.7.3"

    static func run(_ arguments: [String]) {
        guard arguments.first == "import" else { fail("usage: molly health import <export.zip or export.xml> [--out file.om]") }
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
        guard let input else { fail("usage: molly health import <export.zip or export.xml> [--out file.om]") }

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

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}
