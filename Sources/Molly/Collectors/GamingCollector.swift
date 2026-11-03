import AppKit
import Darwin
import Foundation
import GameController
import IOKit

// MARK: - Live sources

/// Everything the collector reads from the machine, injectable so tests can drive it.
struct GamingSources {
    var now: () -> Date = Date.init
    var processes: () -> [GameProcess] = GameProcessScanner.all
    var frontmost: () -> FrontmostApp? = GameProbes.frontmost
    var gpu: () -> GPUUtilization? = GPUProbe.read
    var controllers: () -> ControllerCounts = GameProbes.controllers
    var scanApps: (Set<String>) -> [GameApp] = { GameAppScanner.scan(folders: GamingCollector.appFolders, extraBundleIds: $0) }

    static let live = GamingSources()
}

enum GameProbes {
    static func frontmost() -> FrontmostApp? {
        let app = Thread.isMainThread ? NSWorkspace.shared.frontmostApplication
            : DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
        return app.map { FrontmostApp(pid: $0.processIdentifier, bundleId: $0.bundleIdentifier) }
    }

    static func controllers() -> ControllerCounts {
        var counts = ControllerCounts()
        for controller in GCController.controllers() {
            if controller.extendedGamepad != nil { counts.extended += 1 } else { counts.gamepad += 1 }
        }
        return counts
    }
}

enum GPUProbe {
    private static let percentScale = 100.0

    static func read() -> GPUUtilization? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var busiest: GPUUtilization?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let raw = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
            guard let stats = raw?.takeRetainedValue() as? [String: Any], let value = parse(stats) else { continue }
            if value.device >= busiest?.device ?? -1 { busiest = value }
        }
        return busiest
    }

    /// nil when the dictionary has no device utilisation (an accelerator that does not report it).
    static func parse(_ stats: [String: Any]) -> GPUUtilization? {
        func ratio(_ key: String) -> Double? {
            (stats[key] as? NSNumber).map { min(max($0.doubleValue / percentScale, 0), 1) }
        }
        guard let device = ratio("Device Utilization %") else { return nil }
        return GPUUtilization(device: device, renderer: ratio("Renderer Utilization %") ?? 0, tiler: ratio("Tiler Utilization %") ?? 0)
    }
}

enum GameProcessScanner {
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)
    private static let winePrefix = "wine"

    static func all() -> [GameProcess] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).compactMap { pid in
            guard pid > 0, let path = path(of: pid) else { return nil }
            let isWine = (path as NSString).lastPathComponent.lowercased().hasPrefix(winePrefix)
            return GameProcess(pid: pid, path: path, args: isWine ? arguments(of: pid) : [])
        }
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// argv of a process, read only for wine processes whose .exe argument names the Windows game.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return parseArguments(Array(buffer.prefix(size)))
    }

    /// KERN_PROCARGS2 layout: Int32 argc, the executable path, NUL padding, then argc NUL-terminated strings.
    static func parseArguments(_ data: [UInt8]) -> [String] {
        let countSize = MemoryLayout<Int32>.size
        guard data.count > countSize else { return [] }
        let argc = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24
        var index = countSize
        while index < data.count, data[index] != 0 { index += 1 }
        while index < data.count, data[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < data.count {
            var end = index
            while end < data.count, data[end] != 0 { end += 1 }
            args.append(String(decoding: data[index..<end], as: UTF8.self))
            index = end + 1
        }
        return args
    }
}

// MARK: - Collector

/// Gaming time from Steam, CrossOver/Whisky, App Store games and remote play, plus controller
/// and GPU use. Reads only game names and playtime from Steam; accounts, friends, chat and
/// achievements are never opened.
final class GamingCollector: Collector {
    static let gamesDefaults = LabelPolicy(enabled: false, mode: .denylist, maxCardinality: 30)
    static let appFolders = ["/Applications", Paths.home.path + "/Applications"]
    static let appScanSeconds: TimeInterval = 3600
    static let persistSeconds: TimeInterval = 60
    private static let defaultSteamPath = "~/Library/Application Support/Steam"
    private static let crossOverMarkers = [
        "/Applications/CrossOver.app",
        Paths.home.path + "/Applications/CrossOver.app",
        Paths.home.path + "/Library/Application Support/CrossOver",
        Paths.home.path + "/Library/Containers/com.isaacmarovitz.Whisky",
    ]
    private static let sessionStartKey = "sessionStart"
    private static let sessionPlatformKey = "sessionPlatform"
    private static let lastQualifyingKey = "lastQualifying"
    private static let steamPlayKey = "steamPlay"

    let name = "gaming"
    let interval: TimeInterval

    private let steamRoot: URL
    private let libraryInterval: TimeInterval
    private let extraBundleIds: Set<String>
    private let extraProcessNames: Set<String>
    private let games: LabelLimiter
    private let sources: GamingSources
    private let store: StateStore

    private var state: GamingSessionState
    private var library = GameLibrary()
    private var lastLibraryRead: Date?
    private var lastAppScan: Date?
    private var knownApps: [GameApp] = []
    private var lastPersist: Date = .distantPast
    private var launchesSeenInProcesses = Set<String>()
    private var seeded = false

    private var active: Gauge?
    private var platformSeconds: Counter?
    private var gameSeconds: Counter?
    private var sessionSeconds: Gauge?
    private var sessions: Counter?
    private var launches: Counter?
    private var playtime: Gauge?
    private var lastPlayed: Gauge?
    private var installed: Gauge?
    private var libraryBytes: Gauge?
    private var controllerConnected: Gauge?
    private var controllerSeconds: Counter?
    private var gpuUtilization: Gauge?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, sources: GamingSources = .live) throws {
        interval = settings.interval(default: 5)
        steamRoot = URL(fileURLWithPath: Paths.expand(settings.string("steamPath", default: Self.defaultSteamPath)))
        libraryInterval = max(1, settings.double("libraryIntervalSeconds", default: 300))
        extraBundleIds = Set(settings.strings("extraGameBundleIds"))
        extraProcessNames = Set(settings.strings("extraProcessNames"))
        games = LabelLimiter(filter: try settings.filter("games", defaults: GamingCollector.gamesDefaults))
        state = GamingSessionState(gpuThreshold: settings.double("gpuThreshold", default: 0.3),
                                   maxGap: settings.double("maxGapSeconds", default: 180))
        self.sources = sources
        store = StateStore(collector: "gaming", folder: stateFolder)
        restoreSession()
    }

    func start(registry r: MetricsRegistry) throws {
        let platform = ["platform"]
        active = r.gauge("molly_gaming_active", help: "1 while a gaming session is open on the platform.", labels: platform)
        platformSeconds = r.counter("molly_gaming_platform_seconds_total", help: "Seconds of gaming per platform, without game names.", labels: platform)
        gameSeconds = r.counter("molly_gaming_seconds_total", help: "Seconds of gaming per game; only when the games policy is enabled.", labels: ["platform", "game"])
        sessionSeconds = r.gauge("molly_gaming_session_seconds", help: "Length of the open gaming session; 0 when idle.")
        sessions = r.counter("molly_gaming_sessions_total", help: "Gaming sessions started.", labels: platform)
        launches = r.counter("molly_gaming_launches_total", help: "Game launches; only when the games policy is enabled.", labels: ["platform", "game"])
        playtime = r.gauge("molly_gaming_playtime_minutes", help: "Lifetime Steam playtime per game; only when the games policy is enabled.", labels: ["game"])
        lastPlayed = r.gauge("molly_gaming_last_played_timestamp_seconds", help: "When Steam last recorded the game being played; only when the games policy is enabled.", labels: ["game"])
        installed = r.gauge("molly_gaming_installed_games", help: "Installed games per platform.", labels: platform)
        libraryBytes = r.gauge("molly_gaming_library_bytes", help: "Disk space used by installed Steam games.", labels: platform)
        controllerConnected = r.gauge("molly_gaming_controller_connected", help: "Game controllers attached, by kind.", labels: ["kind"])
        controllerSeconds = r.counter("molly_gaming_controller_seconds_total", help: "Gaming seconds with a controller attached.")
        gpuUtilization = r.gauge("molly_gpu_utilization_ratio", help: "GPU utilisation from the IORegistry; 1.0 is fully busy.", labels: ["kind"])
    }

    func collect() throws {
        let now = sources.now()
        try refreshLibrary(now: now)
        seedBaseline()

        let frontmost = sources.frontmost()
        let running = GameClassifier.running(processes: sources.processes(), library: library, frontmost: frontmost)
        let gpu = sources.gpu()
        let controllers = sources.controllers()
        let deltas = state.advance(to: now, running: running, gpuDevice: gpu?.device,
                                   controllers: controllers.gamepad + controllers.extended)
        publish(deltas, now: now, gpu: gpu, controllers: controllers)
        persistSession(now: now, force: deltas.sessionStarted != nil || deltas.sessionEnded)
    }

    // MARK: Publishing

    private func publish(_ d: GamingDeltas, now: Date, gpu: GPUUtilization?, controllers: ControllerCounts) {
        for (key, seconds) in d.seconds {
            platformSeconds?.add(seconds, labels: ["platform": key.platform.rawValue])
            if games.enabled { gameSeconds?.add(seconds, labels: ["platform": key.platform.rawValue, "game": games.label(key.name)]) }
        }
        if d.controllerSeconds > 0 { controllerSeconds?.add(d.controllerSeconds) }
        if let started = d.sessionStarted { sessions?.inc(labels: ["platform": started.rawValue]) }
        for key in d.launches {
            if key.platform == .steam { launchesSeenInProcesses.insert(key.name) }
            countLaunch(key)
        }
        for platform in GamePlatform.allCases {
            active?.set(state.active && state.platform == platform ? 1 : 0, labels: ["platform": platform.rawValue])
        }
        sessionSeconds?.set(state.sessionSeconds(at: now))
        controllerConnected?.set(controllers.gamepad, labels: ["kind": "gamepad"])
        controllerConnected?.set(controllers.extended, labels: ["kind": "extended"])
        if let gpu {
            gpuUtilization?.set(gpu.device, labels: ["kind": "device"])
            gpuUtilization?.set(gpu.renderer, labels: ["kind": "renderer"])
            gpuUtilization?.set(gpu.tiler, labels: ["kind": "tiler"])
        }
    }

    private func countLaunch(_ key: GameKey) {
        guard games.enabled else { return }
        launches?.inc(labels: ["platform": key.platform.rawValue, "game": games.label(key.name)])
    }

    /// Zero-valued series so rate() works from the first scrape; skipped until a source exists.
    private func seedBaseline() {
        guard !seeded else { return }
        seeded = true
        for platform in GamePlatform.allCases {
            platformSeconds?.touch(labels: ["platform": platform.rawValue])
            sessions?.touch(labels: ["platform": platform.rawValue])
        }
        controllerSeconds?.touch()
    }

    private func publishLibrary() {
        let installedSteam = library.steam.filter { $0.installed }
        installed?.reset()
        libraryBytes?.reset()
        if library.hasSteam {
            installed?.set(installedSteam.count, labels: ["platform": "steam"])
            libraryBytes?.set(installedSteam.reduce(0) { $0 + $1.sizeBytes }, labels: ["platform": "steam"])
        }
        if !library.apps.isEmpty { installed?.set(library.apps.count, labels: ["platform": "native"]) }

        playtime?.reset()
        lastPlayed?.reset()
        guard games.enabled else { return }
        var minutes: [String: Double] = [:]
        var newest: [String: Double] = [:]
        for game in installedSteam {
            guard let play = library.plays[game.appId] else { continue }
            minutes[game.name] = play.playtimeMinutes
            newest[game.name] = play.lastPlayed
        }
        for (label, value) in games.filter.labels(minutes) { playtime?.set(value, labels: ["game": label]) }
        for (label, value) in maxMerged(newest) { lastPlayed?.set(value, labels: ["game": label]) }
    }

    /// Labels a map with the games policy, keeping the largest value when labels collide.
    private func maxMerged(_ values: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        let limit = games.filter.maxCardinality
        let ranked = values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        for (index, entry) in ranked.enumerated() {
            let label = limit > 0 && index >= limit ? LabelPolicy.other : games.filter.label(entry.key)
            out[label] = max(out[label] ?? 0, entry.value)
        }
        return out
    }

    // MARK: Library

    private func refreshLibrary(now: Date) throws {
        if lastAppScan.map({ now.timeIntervalSince($0) >= Self.appScanSeconds }) ?? true {
            lastAppScan = now
            knownApps = sources.scanApps(extraBundleIds)
        }
        if lastLibraryRead.map({ now.timeIntervalSince($0) >= libraryInterval }) ?? true {
            lastLibraryRead = now
            library = readLibrary()
            countStoreLaunches()
            publishLibrary()
        }
        if library.isEmpty {
            throw CollectorUnavailable(reason: "no Steam, CrossOver or game apps found; set collectors.gaming.steamPath or extraGameBundleIds if they live elsewhere")
        }
    }

    private func readLibrary() -> GameLibrary {
        var out = GameLibrary()
        out.apps = knownApps
        out.extraProcessNames = extraProcessNames
        out.hasCrossOver = Self.crossOverMarkers.contains { FileManager.default.fileExists(atPath: $0) }
        out.hasSteam = FileManager.default.fileExists(atPath: steamRoot.path)
        guard out.hasSteam else { return out }
        for folder in steamLibraryFolders() {
            let manifests = (try? FileManager.default.contentsOfDirectory(atPath: folder + "/steamapps")) ?? []
            for file in manifests.sorted() where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                if let text = try? String(contentsOfFile: folder + "/steamapps/" + file, encoding: .utf8),
                   let game = SteamFiles.manifest(text) { out.steam.append(game) }
            }
        }
        out.plays = readPlays()
        return out
    }

    private func steamLibraryFolders() -> [String] {
        var folders = [steamRoot.path]
        let listing = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: listing, encoding: .utf8) {
            folders += SteamFiles.libraryPaths(text).filter { $0 != steamRoot.path }
        }
        return folders
    }

    /// The most recent LastPlayed and the largest Playtime across Steam users on this Mac.
    private func readPlays() -> [String: SteamPlay] {
        let users = (try? FileManager.default.contentsOfDirectory(atPath: steamRoot.path + "/userdata")) ?? []
        var merged: [String: SteamPlay] = [:]
        for user in users.sorted() where Int(user) != nil {
            let path = steamRoot.path + "/userdata/" + user + "/config/localconfig.vdf"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for (appId, play) in SteamFiles.plays(localConfig: text) {
                let before = merged[appId]
                merged[appId] = SteamPlay(lastPlayed: max(before?.lastPlayed ?? 0, play.lastPlayed),
                                          playtimeMinutes: max(before?.playtimeMinutes ?? 0, play.playtimeMinutes))
            }
        }
        return merged
    }

    // MARK: State

    /// Launches that happened while Molly was not looking (or restarted mid-game) show up as a
    /// LastPlayed newer than the stored cursor; a launch already seen in the process list is skipped.
    private func countStoreLaunches() {
        let stored = storedPlays()
        for appId in SteamFiles.launches(stored: stored, current: library.plays) {
            guard let game = library.steam.first(where: { $0.appId == appId }) else { continue }
            if launchesSeenInProcesses.remove(game.name) == nil { countLaunch(GameKey(platform: .steam, name: game.name)) }
        }
        guard !library.plays.isEmpty else { return }
        let encoded = library.plays.mapValues { JSONValue.object(["lastPlayed": .number($0.lastPlayed), "playtime": .number($0.playtimeMinutes)]) }
        store.set(Self.steamPlayKey, .object(encoded))
        save()
    }

    private func storedPlays() -> [String: SteamPlay] {
        var out: [String: SteamPlay] = [:]
        for (appId, value) in store.get(Self.steamPlayKey)?.objectValue ?? [:] {
            guard let last = value["lastPlayed"]?.doubleValue else { continue }
            out[appId] = SteamPlay(lastPlayed: last, playtimeMinutes: value["playtime"]?.doubleValue ?? 0)
        }
        return out
    }

    private func restoreSession() {
        guard let start = store.double(Self.sessionStartKey), start > 0,
              let platform = store.string(Self.sessionPlatformKey).flatMap(GamePlatform.init(rawValue:)),
              let last = store.double(Self.lastQualifyingKey) else { return }
        state.restore(start: Date(timeIntervalSince1970: start), platform: platform,
                      lastQualifying: Date(timeIntervalSince1970: last), now: sources.now())
    }

    private func persistSession(now: Date, force: Bool) {
        guard force || now.timeIntervalSince(lastPersist) >= Self.persistSeconds else { return }
        lastPersist = now
        if let start = state.sessionStart, let platform = state.platform, let last = state.lastQualifying {
            store.set(Self.sessionStartKey, start.timeIntervalSince1970)
            store.set(Self.sessionPlatformKey, platform.rawValue)
            store.set(Self.lastQualifyingKey, last.timeIntervalSince1970)
        } else {
            store.set(Self.sessionStartKey, 0)
        }
        save()
    }

    private func save() {
        do {
            try store.save()
        } catch {
            Log.warn("gaming: cannot save state: \(error)")
        }
    }
}
