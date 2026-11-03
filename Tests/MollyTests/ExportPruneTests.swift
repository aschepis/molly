import XCTest
@testable import Molly

final class ExportPruneTests: XCTestCase {
    func testRedactionReplacesSecretsAtAnyDepthAndKeepsEmptyOnes() throws {
        let json = try JSONValue.parse(Data(#"""
        {"events": {"token": "abc", "projects": {"salt": "", "hash": true}},
         "collectors": {"insights": {"apiKey": "sk-1"}, "browser": {"domains": {"salt": "pepper", "patterns": ["token"]}}},
         "list": [{"salt": "x"}]}
        """#.utf8))
        let redacted = Backup.redact(json)
        XCTAssertEqual(redacted["events"]?["token"], .string("***"))
        XCTAssertEqual(redacted["events"]?["projects"]?["salt"], .string(""))
        XCTAssertEqual(redacted["events"]?["projects"]?["hash"], .bool(true))
        XCTAssertEqual(redacted["collectors"]?["insights"]?["apiKey"], .string("***"))
        XCTAssertEqual(redacted["collectors"]?["browser"]?["domains"]?["salt"], .string("***"))
        XCTAssertEqual(redacted["collectors"]?["browser"]?["domains"]?["patterns"], .array([.string("token")]))
        XCTAssertEqual(redacted["list"]?.arrayValue?.first?["salt"], .string("***"))
    }

    func testFolderNameAndDataDirResolution() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(Backup.folderName(for: date).hasPrefix("molly-backup-2023"))
        XCTAssertEqual(Backup.prometheusDataDir(configured: "~/p", repoRoot: nil).path,
                       Paths.home.appendingPathComponent("p").path)
        let root = URL(fileURLWithPath: "/repo")
        if ProcessInfo.processInfo.environment["MOLLY_DATA_DIR"] == nil {
            XCTAssertEqual(Backup.prometheusDataDir(configured: nil, repoRoot: root).path, "/repo/deploy/data/prometheus")
            XCTAssertEqual(Backup.prometheusDataDir(configured: "", repoRoot: nil).path,
                           Paths.dataFolder.appendingPathComponent("prometheus").path)
        }
    }

    func testFindRepoRootWalksUp() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("molly-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let deep = tmp.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("deploy"), withIntermediateDirectories: true)
        try Data("name: molly\n".utf8).write(to: tmp.appendingPathComponent("deploy/docker-compose.yml"))
        XCTAssertEqual(Backup.findRepoRoot(starts: [deep.path])?.standardizedFileURL, tmp.standardizedFileURL)
        XCTAssertNil(Backup.findRepoRoot(starts: ["/var/empty"]))
    }

    func testExportLayoutWithoutStack() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("molly-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var config = Config()
        config.server.port = 1 // nothing listens: metrics.txt is skipped
        config.links.prometheus = "http://127.0.0.1:1"
        let tarball = try ExportCommand.export(config: config, into: tmp.appendingPathComponent("out"),
                                               includeSecrets: false, dataDir: tmp.appendingPathComponent("nodata"),
                                               now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(tarball.lastPathComponent.hasSuffix(".tar.gz"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tarball.path))
        let listing = try Shell.run("tar", ["-tzf", tarball.path])
        XCTAssertTrue(listing.stdout.contains("molly-backup-"), listing.stdout)
        XCTAssertFalse(listing.stdout.contains("prometheus-snapshot"))
        // The staging folder is removed after tarring.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("out").path)
        XCTAssertEqual(remaining, [tarball.lastPathComponent])
    }

    func testRestoreInstructionsNameTheTarballAndDataDir() {
        let text = Backup.restoreInstructions(tarball: "/x/b.tar.gz", dataDir: URL(fileURLWithPath: "/data/prom"))
        XCTAssertTrue(text.contains("make stack-down"))
        XCTAssertTrue(text.contains("/x/b.tar.gz"))
        XCTAssertTrue(text.contains("/data/prom"))
        XCTAssertTrue(text.contains("make stack-up"))
    }

    func testDurationParsing() {
        XCTAssertEqual(DurationParser.seconds("30d"), 30 * 86400)
        XCTAssertEqual(DurationParser.seconds("12h"), 12 * 3600)
        XCTAssertEqual(DurationParser.seconds("2w"), 14 * 86400)
        XCTAssertEqual(DurationParser.seconds(" 90m "), 5400)
        XCTAssertEqual(DurationParser.seconds("1y"), 365 * 86400)
        XCTAssertNil(DurationParser.seconds("30"))
        XCTAssertNil(DurationParser.seconds("0d"))
        XCTAssertNil(DurationParser.seconds("d"))
        XCTAssertNil(DurationParser.seconds("3x"))
    }

    func testPruneRequestURLs() {
        let r = PruneRequest(base: URL(string: "http://localhost:9090")!,
                             cutoff: Date(timeIntervalSince1970: 1_700_000_000), job: "molly")
        XCTAssertEqual(r.deleteSeriesURL.absoluteString,
                       "http://localhost:9090/api/v1/admin/tsdb/delete_series?match%5B%5D=%7Bjob%3D%22molly%22%7D&end=1700000000")
        XCTAssertEqual(r.cleanTombstonesURL.absoluteString, "http://localhost:9090/api/v1/admin/tsdb/clean_tombstones")
    }

    func testAdminDisabledDetection() {
        XCTAssertTrue(AdminHTTP.adminDisabled(status: 403, body: Data("Admin APIs disabled".utf8)))
        XCTAssertTrue(AdminHTTP.adminDisabled(status: 500, body: Data(#"{"status":"error","errorType":"unavailable","error":"admin APIs disabled"}"#.utf8)))
        XCTAssertFalse(AdminHTTP.adminDisabled(status: 403, body: Data("forbidden".utf8)))
        XCTAssertFalse(AdminHTTP.adminDisabled(status: 200, body: Data("admin APIs disabled".utf8)))
    }

    func testExportConfigKey() throws {
        let c = try Config.parse(Data(#"{"export": {"prometheusDataDir": "~/MollyData/prometheus"}}"#.utf8))
        XCTAssertEqual(c.export.prometheusDataDir, "~/MollyData/prometheus")
        XCTAssertNil(try Config.parse(Data("{}".utf8)).export.prometheusDataDir)
        XCTAssertThrowsError(try Config.parse(Data(#"{"export": {"prometheusDataDir": 3}}"#.utf8)))
    }
}
