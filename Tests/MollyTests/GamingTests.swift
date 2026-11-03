import XCTest
@testable import Molly

private let manifestFixture = """
"AppState"
{
\t"appid"\t\t"1145360"
\t"Universe"\t\t"1"
\t"name"\t\t"Hades \\"Deluxe\\""
\t"StateFlags"\t\t"4"
\t"installdir"\t\t"Hades"
\t"LastUpdated"\t\t"1700000000"
\t"SizeOnDisk"\t\t"9000000000"
\t"LastPlayed"\t\t"1700001000"
\t// a comment
\t"UserConfig"
\t{
\t\t"language"\t\t"english"
\t}
}
"""

private let localConfigFixture = """
"UserLocalConfigStore"
{
\t"Software"
\t{
\t\t"Valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"apps"
\t\t\t\t{
\t\t\t\t\t"1145360"
\t\t\t\t\t{
\t\t\t\t\t\t"LastPlayed"\t\t"1700001000"
\t\t\t\t\t\t"Playtime"\t\t"615"
\t\t\t\t\t}
\t\t\t\t\t"220"
\t\t\t\t\t{
\t\t\t\t\t\t"Playtime"\t\t"0"
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t}
\t}
}
"""

final class VDFTests: XCTestCase {
    func testParsesNestedObjectsQuotedEscapesAndComments() {
        let tree = VDF.parse(manifestFixture)
        XCTAssertEqual(VDF.string(tree, ["AppState", "appid"]), "1145360")
        XCTAssertEqual(VDF.string(tree, ["AppState", "name"]), "Hades \"Deluxe\"")
        XCTAssertEqual(VDF.string(tree, ["AppState", "UserConfig", "language"]), "english")
        XCTAssertNil(VDF.lookup(tree, ["AppState", "comment"]))
    }

    func testLookupIgnoresKeyCase() {
        let tree = VDF.parse(#""Root" { "Apps" { "1" { "Playtime" "5" } } }"#)
        XCTAssertEqual(VDF.string(tree, ["root", "apps", "1", "playtime"]), "5")
    }

    func testBareTokensAndTruncatedInputDoNotCrash() {
        XCTAssertEqual(VDF.string(VDF.parse("key value"), ["key"]), "value")
        XCTAssertEqual(VDF.string(VDF.parse(#""a" { "b" "c""#), ["a", "b"]), "c")
        XCTAssertTrue(VDF.parse("").isEmpty)
        XCTAssertTrue(VDF.parse("}}}").isEmpty)
    }

    func testBackslashesInWindowsPathsSurvive() {
        let tree = VDF.parse(#""path" "C:\\Games\\Steam""#)
        XCTAssertEqual(VDF.string(tree, ["path"]), "C:\\Games\\Steam")
    }
}

final class SteamFilesTests: XCTestCase {
    func testManifestExtraction() {
        let game = SteamFiles.manifest(manifestFixture)
        XCTAssertEqual(game, SteamGame(appId: "1145360", name: "Hades \"Deluxe\"", installDir: "Hades",
                                       installed: true, sizeBytes: 9_000_000_000))
    }

    func testManifestThatIsStillDownloadingIsNotInstalled() {
        let text = manifestFixture.replacingOccurrences(of: "\"StateFlags\"\t\t\"4\"", with: "\"StateFlags\"\t\t\"1026\"")
        XCTAssertEqual(SteamFiles.manifest(text)?.installed, false)
        XCTAssertNil(SteamFiles.manifest("\"Other\" { }"))
    }

    func testLocalConfigReadsOnlyPlaytimeAndLastPlayed() {
        let plays = SteamFiles.plays(localConfig: localConfigFixture)
        XCTAssertEqual(plays["1145360"], SteamPlay(lastPlayed: 1_700_001_000, playtimeMinutes: 615))
        XCTAssertNil(plays["220"], "an app with no playtime is not a play")
    }

    func testLibraryFolders() {
        let text = #""libraryfolders" { "0" { "path" "/Users/a/Steam" } "1" { "path" "/Volumes/Games/Steam" } }"#
        XCTAssertEqual(SteamFiles.libraryPaths(text), ["/Users/a/Steam", "/Volumes/Games/Steam"])
    }

    func testLaunchCursorOnlyCountsKnownGamesWithNewerLastPlayed() {
        let stored = ["1": SteamPlay(lastPlayed: 100, playtimeMinutes: 10), "2": SteamPlay(lastPlayed: 50, playtimeMinutes: 1)]
        let current = ["1": SteamPlay(lastPlayed: 200, playtimeMinutes: 20),
                       "2": SteamPlay(lastPlayed: 50, playtimeMinutes: 1),
                       "3": SteamPlay(lastPlayed: 300, playtimeMinutes: 5)]
        XCTAssertEqual(SteamFiles.launches(stored: stored, current: current), ["1"])
        XCTAssertEqual(SteamFiles.launches(stored: [:], current: current), [], "first run never backfills")
    }

    func testAppScannerRecognisesGamesCategoryAndExtraBundleIds() {
        let game: [String: Any] = ["LSApplicationCategoryType": "public.app-category.games", "CFBundleIdentifier": "a.b"]
        let tool: [String: Any] = ["LSApplicationCategoryType": "public.app-category.developer-tools", "CFBundleIdentifier": "c.d"]
        XCTAssertTrue(GameAppScanner.isGame(info: game, extraBundleIds: []))
        XCTAssertFalse(GameAppScanner.isGame(info: tool, extraBundleIds: []))
        XCTAssertTrue(GameAppScanner.isGame(info: tool, extraBundleIds: ["c.d"]))
    }
}

final class GameClassifierTests: XCTestCase {
    private let hades = SteamGame(appId: "1145360", name: "Hades", installDir: "Hades", installed: true, sizeBytes: 1)
    private var library: GameLibrary {
        GameLibrary(steam: [hades], plays: [:],
                    apps: [GameApp(path: "/Applications/Balatro.app", name: "Balatro", bundleId: "com.playstack.balatro"),
                           GameApp(path: "/Applications/Steam Link.app", name: "Steam Link", bundleId: "com.valvesoftware.SteamLink17")],
                    extraProcessNames: ["RetroArch"], hasCrossOver: true, hasSteam: true)
    }

    private func key(_ path: String, args: [String] = []) -> GameKey? {
        GameClassifier.classify(GameProcess(pid: 1, path: path, args: args), library: library)
    }

    func testSteamGameMapsInstallDirToManifestName() {
        let path = "/Users/a/Library/Application Support/Steam/steamapps/common/Hades/Hades.app/Contents/MacOS/Hades"
        XCTAssertEqual(key(path), GameKey(platform: .steam, name: "Hades"))
        let unknown = "/Users/a/Library/Application Support/Steam/steamapps/common/Other Game/run"
        XCTAssertEqual(key(unknown), GameKey(platform: .steam, name: "Other Game"))
    }

    func testSteamClientItselfIsNotAGame() {
        XCTAssertNil(key("/Users/a/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"))
    }

    func testCrossOverUsesExeNameOrSteamInstallDirFromArguments() {
        let wine = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine64-preloader"
        XCTAssertEqual(key(wine, args: [wine, "C:\\Program Files\\Cool Game\\CoolGame.exe"]),
                       GameKey(platform: .crossover, name: "CoolGame"))
        XCTAssertEqual(key(wine, args: [wine, "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Hades\\x64\\Hades.exe"]),
                       GameKey(platform: .crossover, name: "Hades"))
    }

    func testWineSupportProcessesAreNotGames() {
        let wine = "/Users/a/Library/Application Support/Whisky/Libraries/Wine/bin/wine64-preloader"
        XCTAssertNil(key(wine, args: [wine, "C:\\windows\\system32\\services.exe"]))
        XCTAssertNil(key(wine, args: [wine, "C:\\windows\\system32\\winedevice.exe"]))
        XCTAssertNil(key(wine, args: [wine]))
    }

    func testNativeRemoteAndExtraProcessNames() {
        XCTAssertEqual(key("/Applications/Balatro.app/Contents/MacOS/Balatro"), GameKey(platform: .native, name: "Balatro"))
        XCTAssertEqual(key("/Applications/Steam Link.app/Contents/MacOS/Steam Link"), GameKey(platform: .remote, name: "Steam Link"))
        XCTAssertEqual(key("/opt/retro/RetroArch"), GameKey(platform: .native, name: "RetroArch"))
        XCTAssertNil(key("/Applications/Safari.app/Contents/MacOS/Safari"))
    }

    func testRunningGroupsPidsAndMarksFrontmost() {
        let path = "/Users/a/Steam/steamapps/common/Hades/Hades"
        let processes = [GameProcess(pid: 10, path: path, args: []), GameProcess(pid: 11, path: path + "Helper", args: []),
                         GameProcess(pid: 20, path: "/Applications/Balatro.app/Contents/MacOS/Balatro", args: [])]
        let running = GameClassifier.running(processes: processes, library: library, frontmost: FrontmostApp(pid: 11, bundleId: nil))
        XCTAssertEqual(running.map { $0.key.name }, ["Balatro", "Hades"])
        XCTAssertEqual(running.first { $0.key.name == "Hades" }?.pids, [10, 11])
        XCTAssertEqual(running.map { $0.frontmost }, [false, true])
    }

    func testCrossOverHostAppCountsAsFrontmostForWineGames() {
        let wine = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine64-preloader"
        let process = GameProcess(pid: 5, path: wine, args: [wine, "C:\\g\\Game.exe"])
        let running = GameClassifier.running(processes: [process], library: library,
                                             frontmost: FrontmostApp(pid: 99, bundleId: "com.codeweavers.CrossOver"))
        XCTAssertEqual(running.first?.frontmost, true)
    }

    func testProcessArgumentParsing() {
        var data: [UInt8] = [3, 0, 0, 0]
        data += Array("/bin/wine64-preloader".utf8) + [0, 0, 0]
        data += Array("wine64-preloader".utf8) + [0] + Array("C:\\g\\Game.exe".utf8) + [0] + Array("-fullscreen".utf8) + [0]
        data += Array("HOME=/Users/a".utf8) + [0]
        XCTAssertEqual(GameProcessScanner.parseArguments(data), ["wine64-preloader", "C:\\g\\Game.exe", "-fullscreen"])
        XCTAssertEqual(GameProcessScanner.parseArguments([1, 0]), [])
    }

    func testGPUParsing() {
        let stats: [String: Any] = ["Device Utilization %": 45, "Renderer Utilization %": 30, "Tiler Utilization %": 250]
        XCTAssertEqual(GPUProbe.parse(stats), GPUUtilization(device: 0.45, renderer: 0.3, tiler: 1))
        XCTAssertNil(GPUProbe.parse(["Allocated PB Size": 1]))
    }
}

final class GamingSessionStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let hades = GameKey(platform: .steam, name: "Hades")
    private let balatro = GameKey(platform: .native, name: "Balatro")

    private func state() -> GamingSessionState { GamingSessionState(gpuThreshold: 0.3, maxGap: 180) }
    private func game(_ key: GameKey, front: Bool) -> [RunningGame] { [RunningGame(key: key, pids: [1], frontmost: front)] }
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testStartsOnFrontmostAndCreditsLaterIntervalsOnly() {
        var s = state()
        XCTAssertEqual(s.advance(to: at(0), running: [], gpuDevice: 0, controllers: 0), GamingDeltas())
        let start = s.advance(to: at(5), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        XCTAssertEqual(start.sessionStarted, .steam)
        XCTAssertTrue(start.seconds.isEmpty, "the starting sample is not credited")
        let next = s.advance(to: at(10), running: game(hades, front: true), gpuDevice: 0, controllers: 1)
        XCTAssertEqual(next.seconds, [hades: 5])
        XCTAssertEqual(next.controllerSeconds, 5)
        XCTAssertNil(next.sessionStarted)
        XCTAssertEqual(s.sessionSeconds(at: at(10)), 5)
    }

    func testGapShorterThanToleranceKeepsSessionWithoutCreditingTheGap() {
        var s = state()
        _ = s.advance(to: at(0), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        _ = s.advance(to: at(5), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        let away = s.advance(to: at(10), running: game(hades, front: false), gpuDevice: 0.05, controllers: 0)
        XCTAssertTrue(away.seconds.isEmpty)
        XCTAssertFalse(away.sessionEnded)
        XCTAssertTrue(s.active)
        let back = s.advance(to: at(100), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        XCTAssertNil(back.sessionStarted, "same session: no second start")
        XCTAssertFalse(back.sessionEnded)
    }

    func testSessionEndsAfterMaxGapAndRestartsAsANewSession() {
        var s = state()
        _ = s.advance(to: at(0), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        _ = s.advance(to: at(5), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        XCTAssertFalse(s.advance(to: at(100), running: game(hades, front: false), gpuDevice: 0, controllers: 0).sessionEnded)
        let ended = s.advance(to: at(200), running: game(hades, front: false), gpuDevice: 0, controllers: 0)
        XCTAssertTrue(ended.sessionEnded)
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.sessionSeconds(at: at(200)), 0)
        let again = s.advance(to: at(210), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        XCTAssertEqual(again.sessionStarted, .steam)
    }

    func testLongPauseBetweenSamplesEndsThenStartsAndCreditsNothing() {
        var s = state()
        _ = s.advance(to: at(0), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        _ = s.advance(to: at(5), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        let woke = s.advance(to: at(5 + 3600), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        XCTAssertTrue(woke.sessionEnded)
        XCTAssertEqual(woke.sessionStarted, .steam)
        XCTAssertTrue(woke.seconds.isEmpty)
    }

    func testBackgroundSteamGameNeedsTwoBusyGPUSamples() {
        var s = state()
        _ = s.advance(to: at(0), running: game(hades, front: false), gpuDevice: 0.9, controllers: 0)
        XCTAssertFalse(s.active)
        let second = s.advance(to: at(5), running: game(hades, front: false), gpuDevice: 0.9, controllers: 0)
        XCTAssertEqual(second.sessionStarted, .steam)
        var reset = state()
        _ = reset.advance(to: at(0), running: game(hades, front: false), gpuDevice: 0.9, controllers: 0)
        _ = reset.advance(to: at(5), running: game(hades, front: false), gpuDevice: 0.1, controllers: 0)
        _ = reset.advance(to: at(10), running: game(hades, front: false), gpuDevice: 0.9, controllers: 0)
        XCTAssertFalse(reset.active, "a quiet sample resets the streak")
    }

    func testNativeGamesIgnoreTheGPU() {
        var s = state()
        for i in 0..<4 { _ = s.advance(to: at(Double(i) * 5), running: game(balatro, front: false), gpuDevice: 0.99, controllers: 0) }
        XCTAssertFalse(s.active)
    }

    func testNoGameRunningNeverStartsASession() {
        var s = state()
        for i in 0..<4 { _ = s.advance(to: at(Double(i) * 5), running: [], gpuDevice: 0.99, controllers: 1) }
        XCTAssertFalse(s.active)
    }

    func testLaunchesAreProcessAppearancesAfterTheFirstSample() {
        var s = state()
        XCTAssertTrue(s.advance(to: at(0), running: game(hades, front: false), gpuDevice: 0, controllers: 0).launches.isEmpty)
        XCTAssertTrue(s.advance(to: at(5), running: [], gpuDevice: 0, controllers: 0).launches.isEmpty)
        XCTAssertEqual(s.advance(to: at(10), running: game(hades, front: false), gpuDevice: 0, controllers: 0).launches, [hades])
    }

    func testRestoreResumesOnlyWithinTheGap() {
        var fresh = state()
        fresh.restore(start: at(-600), platform: .steam, lastQualifying: at(-60), now: at(0))
        XCTAssertTrue(fresh.active)
        XCTAssertEqual(fresh.sessionSeconds(at: at(0)), 600)
        var stale = state()
        stale.restore(start: at(-600), platform: .steam, lastQualifying: at(-500), now: at(0))
        XCTAssertFalse(stale.active)
    }

    func testRestoredSessionDoesNotCountAsANewSession() {
        var s = state()
        s.restore(start: at(-600), platform: .steam, lastQualifying: at(-5), now: at(0))
        let d = s.advance(to: at(0), running: game(hades, front: true), gpuDevice: 0, controllers: 0)
        XCTAssertNil(d.sessionStarted)
    }
}

final class GamingCollectorTests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var processes: [GameProcess] = []
    private var front: FrontmostApp?
    private var controllers = ControllerCounts()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("gaming-\(UUID().uuidString)")
        let apps = folder.appendingPathComponent("Steam/steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try manifestFixture.write(to: apps.appendingPathComponent("appmanifest_1145360.acf"), atomically: true, encoding: .utf8)
        let config = folder.appendingPathComponent("Steam/userdata/12345/config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try localConfigFixture.write(to: config.appendingPathComponent("localconfig.vdf"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeCollector(policy: String = #"{"enabled": false}"#, extra: String = "") throws -> (GamingCollector, MetricsRegistry) {
        let json = #"{"collectors": {"gaming": {"steamPath": "\#(folder.path)/Steam", "games": \#(policy)\#(extra)}}}"#
        let settings = try Config.parse(Data(json.utf8)).collector("gaming")
        let sources = GamingSources(now: { self.clock }, processes: { self.processes }, frontmost: { self.front },
                                    gpu: { GPUUtilization(device: 0.1, renderer: 0.1, tiler: 0.1) },
                                    controllers: { self.controllers }, scanApps: { _ in [] })
        let collector = try GamingCollector(settings: settings, stateFolder: folder.appendingPathComponent("state"), sources: sources)
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        return (collector, registry)
    }

    private func playHades(_ collector: GamingCollector, ticks: Int) throws {
        processes = [GameProcess(pid: 7, path: "/x/steamapps/common/Hades/Hades", args: [])]
        front = FrontmostApp(pid: 7, bundleId: nil)
        for _ in 0..<ticks {
            try collector.collect()
            clock = clock.addingTimeInterval(5)
        }
    }

    func testPolicyOffPublishesAggregatesButNoGameLabels() throws {
        let (collector, registry) = try makeCollector()
        controllers = ControllerCounts(gamepad: 0, extended: 1)
        try playHades(collector, ticks: 4)
        let text = registry.render()
        XCTAssertFalse(text.contains("game=\""))
        XCTAssertFalse(text.contains("Hades"))
        XCTAssertFalse(text.contains("molly_gaming_playtime_minutes{"))
        XCTAssertEqual(registry.counter("molly_gaming_platform_seconds_total", help: "", labels: ["platform"]).value(labels: ["platform": "steam"]), 15)
        XCTAssertEqual(registry.counter("molly_gaming_sessions_total", help: "", labels: ["platform"]).value(labels: ["platform": "steam"]), 1)
        XCTAssertEqual(registry.counter("molly_gaming_controller_seconds_total", help: "").value(), 15)
        XCTAssertEqual(registry.gauge("molly_gaming_active", help: "", labels: ["platform"]).value(labels: ["platform": "steam"]), 1)
        XCTAssertEqual(registry.gauge("molly_gaming_installed_games", help: "", labels: ["platform"]).value(labels: ["platform": "steam"]), 1)
        XCTAssertEqual(registry.gauge("molly_gaming_controller_connected", help: "", labels: ["kind"]).value(labels: ["kind": "extended"]), 1)
    }

    func testPolicyOnAddsGameLabelsPlaytimeAndLastPlayed() throws {
        let (collector, registry) = try makeCollector(policy: #"{"enabled": true}"#)
        try playHades(collector, ticks: 3)
        let game = "Hades \"Deluxe\""
        XCTAssertEqual(registry.counter("molly_gaming_seconds_total", help: "", labels: ["platform", "game"])
            .value(labels: ["platform": "steam", "game": game.lowercased()]), 10)
        XCTAssertEqual(registry.gauge("molly_gaming_playtime_minutes", help: "", labels: ["game"]).value(labels: ["game": game.lowercased()]), 615)
        XCTAssertEqual(registry.gauge("molly_gaming_last_played_timestamp_seconds", help: "", labels: ["game"])
            .value(labels: ["game": game.lowercased()]), 1_700_001_000)
    }

    func testSessionGaugeIsZeroWhenIdle() throws {
        let (collector, registry) = try makeCollector()
        processes = []
        front = nil
        try collector.collect()
        XCTAssertEqual(registry.gauge("molly_gaming_session_seconds", help: "").value(), 0)
    }

    func testOpenSessionSurvivesARestart() throws {
        let (first, _) = try makeCollector()
        try playHades(first, ticks: 3)
        let (second, registry) = try makeCollector()
        try playHades(second, ticks: 1)
        XCTAssertEqual(registry.counter("molly_gaming_sessions_total", help: "", labels: ["platform"]).value(labels: ["platform": "steam"]), 0,
                       "a session resumed after a restart is not a new session")
        XCTAssertGreaterThan(registry.gauge("molly_gaming_session_seconds", help: "").value() ?? 0, 0)
    }

    func testNothingGamingRelatedThrowsUnavailable() throws {
        let settings = try Config.parse(Data(#"{"collectors": {"gaming": {"steamPath": "/nonexistent/steam"}}}"#.utf8)).collector("gaming")
        let sources = GamingSources(now: { self.clock }, processes: { [] }, frontmost: { nil }, gpu: { nil },
                                    controllers: { ControllerCounts() }, scanApps: { _ in [] })
        let collector = try GamingCollector(settings: settings, stateFolder: folder.appendingPathComponent("state"), sources: sources)
        try collector.start(registry: MetricsRegistry())
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let crossOverPresent = FileManager.default.fileExists(atPath: "/Applications/CrossOver.app")
            || FileManager.default.fileExists(atPath: home + "/Library/Application Support/CrossOver")
            || FileManager.default.fileExists(atPath: home + "/Library/Containers/com.isaacmarovitz.Whisky")
        try XCTSkipIf(crossOverPresent, "CrossOver or Whisky is installed on this machine")
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }

    func testLiveCollectPublishesFamilies() throws {
        let settings = try Config.parse(Data("{}".utf8)).collector("gaming")
        let collector = try GamingCollector(settings: settings, stateFolder: folder.appendingPathComponent("live-state"))
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        do {
            try collector.collect()
        } catch is CollectorUnavailable {
            throw XCTSkip("no Steam, CrossOver or game apps on this machine")
        }
        let names = Set(registry.familyNames)
        for family in ["molly_gaming_active", "molly_gaming_platform_seconds_total", "molly_gaming_session_seconds",
                       "molly_gaming_sessions_total", "molly_gaming_controller_connected", "molly_gaming_installed_games"] {
            XCTAssertTrue(names.contains(family), family)
        }
    }
}
