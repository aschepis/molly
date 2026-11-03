import Foundation

// MARK: - Library (pure, unit-tested)

enum GamePlatform: String, CaseIterable {
    case steam, crossover, native, remote
}

struct GameKey: Hashable, Comparable {
    let platform: GamePlatform
    let name: String

    static func < (a: GameKey, b: GameKey) -> Bool {
        a.platform == b.platform ? a.name < b.name : a.platform.rawValue < b.platform.rawValue
    }
}

struct SteamGame: Equatable {
    let appId: String
    let name: String
    let installDir: String
    let installed: Bool
    let sizeBytes: Double
}

struct SteamPlay: Equatable {
    let lastPlayed: Double
    let playtimeMinutes: Double
}

struct GameApp: Equatable {
    let path: String
    let name: String
    let bundleId: String
}

/// Everything Molly knows about installed games, rebuilt every library interval.
struct GameLibrary: Equatable {
    var steam: [SteamGame] = []
    var plays: [String: SteamPlay] = [:]
    var apps: [GameApp] = []
    var extraProcessNames: Set<String> = []
    var hasCrossOver = false
    var hasSteam = false

    var isEmpty: Bool { !hasSteam && !hasCrossOver && apps.isEmpty && extraProcessNames.isEmpty }

    func steamGame(installDir: String) -> SteamGame? {
        steam.first { $0.installDir.caseInsensitiveCompare(installDir) == .orderedSame }
    }
}

enum SteamFiles {
    /// StateFlags bit 4 means fully installed.
    private static let installedFlag = 4

    static func manifest(_ text: String) -> SteamGame? {
        let tree = VDF.parse(text)
        guard let state = VDF.object(tree, ["AppState"]),
              let appId = VDF.string(state, ["appid"]),
              let name = VDF.string(state, ["name"]) else { return nil }
        let flags = Int(VDF.string(state, ["StateFlags"]) ?? "") ?? 0
        return SteamGame(appId: appId, name: name,
                         installDir: VDF.string(state, ["installdir"]) ?? name,
                         installed: flags & installedFlag != 0,
                         sizeBytes: Double(VDF.string(state, ["SizeOnDisk"]) ?? "") ?? 0)
    }

    /// Only LastPlayed and Playtime are read from localconfig; nothing else in that file is touched.
    static func plays(localConfig text: String) -> [String: SteamPlay] {
        let tree = VDF.parse(text)
        guard let apps = VDF.object(tree, ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps"]) else { return [:] }
        var out: [String: SteamPlay] = [:]
        for (appId, value) in apps {
            guard let app = value as? [String: Any] else { continue }
            let last = Double(VDF.string(app, ["LastPlayed"]) ?? "") ?? 0
            let minutes = Double(VDF.string(app, ["Playtime"]) ?? "") ?? 0
            if last > 0 || minutes > 0 { out[appId] = SteamPlay(lastPlayed: last, playtimeMinutes: minutes) }
        }
        return out
    }

    /// Extra library folders on other volumes, from steamapps/libraryfolders.vdf.
    static func libraryPaths(_ text: String) -> [String] {
        let tree = VDF.parse(text)
        guard let folders = VDF.object(tree, ["libraryfolders"]) else { return [] }
        return folders.values.compactMap { ($0 as? [String: Any]).flatMap { VDF.string($0, ["path"]) } }.sorted()
    }

    /// Launches that no process sighting accounted for: LastPlayed moved past the stored value.
    static func launches(stored: [String: SteamPlay], current: [String: SteamPlay]) -> [String] {
        current.compactMap { appId, play in
            guard let before = stored[appId], play.lastPlayed > before.lastPlayed else { return nil }
            return appId
        }.sorted()
    }
}

enum GameAppScanner {
    static let gamesCategory = "public.app-category.games"

    static func isGame(info: [String: Any], extraBundleIds: Set<String>) -> Bool {
        if info["LSApplicationCategoryType"] as? String == gamesCategory { return true }
        return (info["CFBundleIdentifier"] as? String).map(extraBundleIds.contains) ?? false
    }

    /// Looks one folder level deep so /Applications/Games/Foo.app is found without a full walk.
    static func scan(folders: [String], extraBundleIds: Set<String>) -> [GameApp] {
        var found: [GameApp] = []
        for folder in folders {
            for entry in children(of: folder) {
                if entry.hasSuffix(".app") {
                    if let app = app(at: entry, extraBundleIds: extraBundleIds) { found.append(app) }
                } else {
                    for inner in children(of: entry) where inner.hasSuffix(".app") {
                        if let app = app(at: inner, extraBundleIds: extraBundleIds) { found.append(app) }
                    }
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func children(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().map { folder + "/" + $0 }
    }

    private static func app(at path: String, extraBundleIds: Set<String>) -> GameApp? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
              isGame(info: info, extraBundleIds: extraBundleIds) else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return GameApp(path: path, name: name, bundleId: info["CFBundleIdentifier"] as? String ?? "")
    }
}

// MARK: - Process classification (pure, unit-tested)

struct GameProcess: Equatable {
    let pid: Int32
    let path: String
    let args: [String]
}

struct FrontmostApp: Equatable {
    let pid: Int32
    let bundleId: String?
}

struct RunningGame: Equatable {
    let key: GameKey
    var pids: Set<Int32>
    var frontmost: Bool
}

enum GameClassifier {
    static let remoteBundlePrefixes = ["com.valvesoftware.steamlink", "com.moonlight-stream"]
    static let wineHostBundlePrefixes = ["com.codeweavers.crossover", "com.isaacmarovitz.whisky"]
    static let winePreloaderPrefixes = ["wine64-preloader", "wine-preloader"]
    /// Windows plumbing that wine starts beside every game.
    static let windowsSupportExecutables: Set<String> = [
        "services.exe", "explorer.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
        "wineboot.exe", "conhost.exe", "cmd.exe", "start.exe", "winedbg.exe", "steamwebhelper.exe",
        "steam.exe", "crashhandler.exe", "unitycrashhandler64.exe",
    ]

    static func classify(_ process: GameProcess, library: GameLibrary) -> GameKey? {
        let executable = lastComponent(process.path).lowercased()
        if winePreloaderPrefixes.contains(where: executable.hasPrefix) {
            return windowsGame(args: process.args, library: library)
        }
        if let installDir = steamInstallDir(in: process.path) {
            let name = library.steamGame(installDir: installDir)?.name ?? installDir
            return GameKey(platform: .steam, name: name)
        }
        if let app = library.apps.first(where: { process.path.hasPrefix($0.path + "/") }) {
            let remote = remoteBundlePrefixes.contains { app.bundleId.lowercased().hasPrefix($0) }
            return GameKey(platform: remote ? .remote : .native, name: app.name)
        }
        let extra = library.extraProcessNames.first { $0.caseInsensitiveCompare(lastComponent(process.path)) == .orderedSame }
        return extra.map { GameKey(platform: .native, name: $0) }
    }

    /// Groups processes by game and marks the game that owns the frontmost window.
    static func running(processes: [GameProcess], library: GameLibrary, frontmost: FrontmostApp?) -> [RunningGame] {
        var byKey: [GameKey: Set<Int32>] = [:]
        for process in processes {
            guard let key = classify(process, library: library) else { continue }
            byKey[key, default: []].insert(process.pid)
        }
        return byKey.map { key, pids in
            RunningGame(key: key, pids: pids, frontmost: isFrontmost(key, pids: pids, frontmost: frontmost))
        }.sorted { $0.key < $1.key }
    }

    private static func isFrontmost(_ key: GameKey, pids: Set<Int32>, frontmost: FrontmostApp?) -> Bool {
        guard let frontmost else { return false }
        if pids.contains(frontmost.pid) { return true }
        guard key.platform == .crossover, let bundleId = frontmost.bundleId?.lowercased() else { return false }
        return wineHostBundlePrefixes.contains { bundleId.hasPrefix($0) }
    }

    private static func windowsGame(args: [String], library: GameLibrary) -> GameKey? {
        for arg in args {
            let file = lastComponent(arg)
            guard file.lowercased().hasSuffix(".exe"), !windowsSupportExecutables.contains(file.lowercased()) else { continue }
            if let installDir = steamInstallDir(in: arg) {
                return GameKey(platform: .crossover, name: library.steamGame(installDir: installDir)?.name ?? installDir)
            }
            return GameKey(platform: .crossover, name: String(file.dropLast(".exe".count)))
        }
        return nil
    }

    /// The folder after steamapps/common/, for unix and Windows style paths.
    static func steamInstallDir(in path: String) -> String? {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        let marker = parts.indices.first { index in
            index + 2 < parts.count && parts[index].lowercased() == "steamapps" && parts[index + 1].lowercased() == "common"
        }
        return marker.map { parts[$0 + 2] }
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }
}

// MARK: - Session state machine (pure, unit-tested)

struct GamingDeltas: Equatable {
    var seconds: [GameKey: Double] = [:]
    var controllerSeconds: Double = 0
    var launches: [GameKey] = []
    var sessionStarted: GamePlatform?
    var sessionEnded = false
}

/// A session starts when a game process is running and it is frontmost (or, for
/// Steam and CrossOver, the GPU has been busy for two samples), and ends when that
/// has not held for `maxGap`. Time is credited only while a session was already
/// open and the game still qualifies, so nothing is counted twice and a gap
/// inside a session is never credited.
struct GamingSessionState {
    static let gpuBusySamples = 2

    let gpuThreshold: Double
    let maxGap: Double
    /// Intervals longer than this (sleep, suspended process) are not credited.
    let maxCredit: Double

    private(set) var sessionStart: Date?
    private(set) var platform: GamePlatform?
    private(set) var primary: GameKey?
    private(set) var lastQualifying: Date?
    private var lastTick: Date?
    private var previousRunning: Set<GameKey>?
    private var gpuStreak = 0

    var active: Bool { sessionStart != nil }

    init(gpuThreshold: Double, maxGap: Double, maxCredit: Double = 60) {
        self.gpuThreshold = gpuThreshold
        self.maxGap = maxGap
        self.maxCredit = maxCredit
    }

    func sessionSeconds(at now: Date) -> Double {
        sessionStart.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    /// Resumes a session saved before a restart, if it was still within the gap tolerance.
    mutating func restore(start: Date, platform: GamePlatform, lastQualifying: Date, now: Date) {
        guard !active, now.timeIntervalSince(lastQualifying) <= maxGap else { return }
        sessionStart = start
        self.platform = platform
        self.lastQualifying = lastQualifying
    }

    mutating func advance(to now: Date, running: [RunningGame], gpuDevice: Double?, controllers: Int) -> GamingDeltas {
        var deltas = GamingDeltas()
        let elapsed = lastTick.map { now.timeIntervalSince($0) }
        lastTick = now

        gpuStreak = (gpuDevice ?? 0) > gpuThreshold ? gpuStreak + 1 : 0
        let keys = Set(running.map { $0.key })
        if let previousRunning { deltas.launches = keys.subtracting(previousRunning).sorted() }
        previousRunning = keys

        if active, let lastQualifying, now.timeIntervalSince(lastQualifying) > maxGap { endSession(&deltas) }

        guard let game = leadingGame(running.filter(qualifies)) else { return deltas }
        let wasActive = active
        lastQualifying = now
        primary = game.key
        if !wasActive {
            sessionStart = now
            platform = game.key.platform
            deltas.sessionStarted = game.key.platform
        } else if let elapsed, elapsed > 0, elapsed <= maxCredit {
            deltas.seconds[game.key] = elapsed
            if controllers > 0 { deltas.controllerSeconds = elapsed }
        }
        return deltas
    }

    private func qualifies(_ game: RunningGame) -> Bool {
        if game.frontmost { return true }
        let canRunUnfocused = game.key.platform == .steam || game.key.platform == .crossover
        return canRunUnfocused && gpuStreak >= Self.gpuBusySamples
    }

    private func leadingGame(_ candidates: [RunningGame]) -> RunningGame? {
        candidates.first { $0.frontmost } ?? candidates.first { $0.key == primary } ?? candidates.first
    }

    private mutating func endSession(_ deltas: inout GamingDeltas) {
        sessionStart = nil
        platform = nil
        primary = nil
        lastQualifying = nil
        deltas.sessionEnded = true
    }
}

// MARK: - Probe values

struct GPUUtilization: Equatable {
    var device: Double
    var renderer: Double
    var tiler: Double
}

struct ControllerCounts: Equatable {
    var gamepad = 0
    var extended = 0
}
