import AppKit
import Foundation

// MARK: - Pure logic (unit-tested)

struct MediaApp: Equatable {
    /// The `app` label value.
    let label: String
    let bundleID: String
}

struct NowPlaying: Equatable {
    let playing: Bool
    let track: String
    let artist: String
}

enum MediaParse {
    /// Music and Spotify expose the same player-state/current-track dictionary.
    static let apps: [MediaApp] = [
        MediaApp(label: "music", bundleID: "com.apple.Music"),
        MediaApp(label: "spotify", bundleID: "com.spotify.client"),
    ]

    /// A record separator no track name contains, so the two text fields can
    /// carry commas. Addressing by bundle id keeps osascript from launching
    /// the app by name.
    static let separator = "\u{1E}"

    static func script(bundleID: String) -> String {
        "tell application id \"\(bundleID)\" to return (player state as string) & \"\(separator)\" & (name of current track) & \"\(separator)\" & (artist of current track)"
    }

    /// "playing<RS>Song<RS>Artist". A stopped player has no current track and
    /// the script errors out, which the caller treats as not playing.
    static func nowPlaying(osascript output: String) -> NowPlaying? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: separator)
        guard parts.count == 3 else { return nil }
        let state = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !state.isEmpty else { return nil }
        return NowPlaying(playing: state == "playing",
                          track: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
                          artist: parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func selected(labels: [String], running: Set<String>) -> [MediaApp] {
        apps.filter { (labels.isEmpty || labels.contains($0.label)) && running.contains($0.bundleID) }
    }
}

/// Per-app playback state between polls. Only the (track, artist) pair of the
/// current song is held, in memory, to detect changes; it is never logged.
struct MediaState {
    struct Deltas: Equatable {
        var playingSeconds: Double = 0
        var trackChanges = 0
    }

    private(set) var playing = false
    private var current: NowPlaying?
    private var lastSeen: Date?

    /// `now` is nil when the app did not answer (stopped, or permission
    /// denied): that counts as not playing and keeps the remembered track, so
    /// a transient failure is not a track change.
    mutating func advance(to date: Date, now: NowPlaying?, maxGap: TimeInterval) -> Deltas {
        var deltas = Deltas()
        if let last = lastSeen, playing {
            deltas.playingSeconds = min(max(0, date.timeIntervalSince(last)), maxGap)
        }
        lastSeen = date
        guard let now else {
            playing = false
            return deltas
        }
        playing = now.playing
        if now.playing {
            if let current, current.track != now.track || current.artist != now.artist {
                deltas.trackChanges = 1
            }
            current = now
        }
        return deltas
    }
}

// MARK: - Collector

/// Playback state of Music and Spotify through AppleScript. The first run
/// triggers one Automation permission prompt per app. An app that is not
/// running is never asked, so Molly never launches one.
final class MediaCollector: Collector {
    static let tracksDefaults = LabelPolicy(enabled: false, mode: .denylist, hash: true, maxCardinality: 100)
    let name = "media"
    let interval: TimeInterval

    static let scriptTimeout: TimeInterval = 10

    private let labels: [String]
    private let trackFilter: LabelFilter
    private let runningBundleIDs: () -> Set<String>
    private let runScript: (String) throws -> ShellResult
    private var states: [String: MediaState] = [:]
    private var failed = Set<String>()
    private var warned = Set<String>()

    private var playing: Gauge?
    private var playingSeconds: Counter?
    private var trackChanges: Counter?
    private var trackInfo: Gauge?

    init(settings: CollectorSettings,
         running: @escaping () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) },
         runScript: @escaping (String) throws -> ShellResult = { try Shell.run("osascript", ["-e", $0], timeout: MediaCollector.scriptTimeout) }) throws {
        interval = settings.interval(default: 15)
        labels = settings.strings("apps").map { $0.lowercased() }
        trackFilter = try settings.filter("tracks", defaults: MediaCollector.tracksDefaults)
        runningBundleIDs = running
        self.runScript = runScript
    }

    func start(registry: MetricsRegistry) throws {
        playing = registry.gauge("molly_media_playing", help: "1 while the app reports it is playing.", labels: ["app"])
        playingSeconds = registry.counter("molly_media_playing_seconds_total", help: "Seconds of playback per app.", labels: ["app"])
        trackChanges = registry.counter("molly_media_track_changes_total", help: "Times the current track changed while playing.", labels: ["app"])
        if trackFilter.enabled {
            trackInfo = registry.gauge("molly_media_track_info", help: "The current track (policy media.tracks).", labels: ["app", "track", "artist"])
        }
    }

    func collect() throws {
        let targets = MediaParse.selected(labels: labels, running: runningBundleIDs())
        let now = Date()
        playing?.reset()
        trackInfo?.reset()
        for app in targets {
            let answer = query(app)
            var state = states[app.label] ?? MediaState()
            let deltas = state.advance(to: now, now: answer, maxGap: interval * 2)
            states[app.label] = state
            let labels = ["app": app.label]
            playing?.set(state.playing ? 1 : 0, labels: labels)
            playingSeconds?.add(deltas.playingSeconds, labels: labels)
            trackChanges?.add(Double(deltas.trackChanges), labels: labels)
            if let answer, answer.playing {
                trackInfo?.set(1, labels: ["app": app.label,
                                          "track": trackFilter.label(answer.track),
                                          "artist": trackFilter.label(answer.artist)])
            }
        }
        // A stopped player also fails its script (no current track), so only
        // a script-level failure from every running app counts as unavailable.
        if !targets.isEmpty, targets.allSatisfy({ failed.contains($0.label) }) {
            throw CollectorUnavailable(reason: "no running media app answered; grant Automation access in System Settings > Privacy & Security")
        }
    }

    private func query(_ app: MediaApp) -> NowPlaying? {
        do {
            let result = try runScript(MediaParse.script(bundleID: app.bundleID))
            if result.succeeded, let now = MediaParse.nowPlaying(osascript: result.stdout) {
                failed.remove(app.label)
                return now
            }
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // "Can't get name of current track" is an idle player, not a failure.
            if err.lowercased().contains("current track") {
                failed.remove(app.label)
            } else {
                failed.insert(app.label)
                warnOnce(app, "osascript failed (\(result.status)): \(err)")
            }
        } catch {
            failed.insert(app.label)
            warnOnce(app, "\(error)")
        }
        return nil
    }

    private func warnOnce(_ app: MediaApp, _ message: String) {
        guard warned.insert(app.label).inserted else { return }
        Log.warn("media: \(app.label): \(message)")
    }
}
