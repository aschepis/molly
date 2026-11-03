import XCTest
@testable import Molly

private func settings(_ json: String, name: String) throws -> CollectorSettings {
    let config = try Config.parse(Data(#"{"collectors": {"\#(name)": \#(json)}}"#.utf8))
    return config.collector(name)
}

final class MediaParseTests: XCTestCase {
    private let rs = MediaParse.separator

    func testParsesPlayingAndPaused() {
        XCTAssertEqual(MediaParse.nowPlaying(osascript: "playing\(rs)Blue, in Green\(rs)Miles Davis\n"),
                       NowPlaying(playing: true, track: "Blue, in Green", artist: "Miles Davis"))
        XCTAssertEqual(MediaParse.nowPlaying(osascript: "paused\(rs)Song\(rs)Artist")?.playing, false)
    }

    func testRejectsMalformedOutput() {
        XCTAssertNil(MediaParse.nowPlaying(osascript: ""))
        XCTAssertNil(MediaParse.nowPlaying(osascript: "playing, Song, Artist"))
        XCTAssertNil(MediaParse.nowPlaying(osascript: "\(rs)Song\(rs)Artist"))
    }

    func testScriptAddressesByBundleID() {
        let script = MediaParse.script(bundleID: "com.spotify.client")
        XCTAssertTrue(script.hasPrefix("tell application id \"com.spotify.client\""))
        XCTAssertTrue(script.contains("player state"))
        XCTAssertFalse(script.contains("activate"))
    }

    func testSelectedRespectsConfigAndRunning() {
        let running: Set<String> = ["com.spotify.client", "com.apple.Safari"]
        XCTAssertEqual(MediaParse.selected(labels: [], running: running).map(\.label), ["spotify"])
        XCTAssertEqual(MediaParse.selected(labels: ["music"], running: running), [])
    }
}

final class MediaStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let a = NowPlaying(playing: true, track: "A", artist: "X")
    private let b = NowPlaying(playing: true, track: "B", artist: "X")

    func testAccumulatesSecondsOnlyWhilePlaying() {
        var s = MediaState()
        XCTAssertEqual(s.advance(to: t0, now: a, maxGap: 30), MediaState.Deltas())
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(15), now: a, maxGap: 30).playingSeconds, 15)
        let paused = NowPlaying(playing: false, track: "A", artist: "X")
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(30), now: paused, maxGap: 30).playingSeconds, 15)
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(45), now: paused, maxGap: 30).playingSeconds, 0)
        XCTAssertFalse(s.playing)
    }

    func testGapIsCapped() {
        var s = MediaState()
        _ = s.advance(to: t0, now: a, maxGap: 30)
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(600), now: a, maxGap: 30).playingSeconds, 30)
    }

    func testTrackChangeCountedOnlyWhilePlaying() {
        var s = MediaState()
        _ = s.advance(to: t0, now: a, maxGap: 30)
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(1), now: a, maxGap: 30).trackChanges, 0)
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(2), now: b, maxGap: 30).trackChanges, 1)
        // A missing answer keeps the remembered track, so coming back is not a change.
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(3), now: nil, maxGap: 30).trackChanges, 0)
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(4), now: b, maxGap: 30).trackChanges, 0)
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(5), now: a, maxGap: 30).trackChanges, 1)
    }
}

final class MediaCollectorTests: XCTestCase {
    private let rs = MediaParse.separator

    private func make(json: String = "{}", running: Set<String>, answer: @escaping (String) throws -> ShellResult) throws -> MediaCollector {
        try MediaCollector(settings: settings(json, name: "media"), running: { running }, runScript: answer)
    }

    func testPlayingAppPublishesGaugesWithoutTrackLabelsByDefault() throws {
        let registry = MetricsRegistry()
        let c = try make(running: ["com.spotify.client"]) { _ in
            ShellResult(status: 0, stdout: "playing\(self.rs)Secret Song\(self.rs)Private Artist", stderr: "")
        }
        try c.start(registry: registry)
        try c.collect()
        try c.collect()
        XCTAssertEqual(registry.gauge("molly_media_playing", help: "", labels: ["app"]).value(labels: ["app": "spotify"]), 1)
        XCTAssertGreaterThanOrEqual(registry.counter("molly_media_playing_seconds_total", help: "", labels: ["app"]).value(labels: ["app": "spotify"]) ?? -1, 0)
        XCTAssertFalse(registry.familyNames.contains("molly_media_track_info"))
        XCTAssertFalse(registry.render().contains("Secret Song"))
    }

    func testTrackInfoHashedWhenPolicyEnabled() throws {
        let registry = MetricsRegistry()
        let c = try make(json: #"{"tracks": {"enabled": true}}"#, running: ["com.apple.Music"]) { _ in
            ShellResult(status: 0, stdout: "playing\(self.rs)Secret Song\(self.rs)Private Artist", stderr: "")
        }
        try c.start(registry: registry)
        try c.collect()
        let text = registry.render()
        XCTAssertTrue(text.contains("molly_media_track_info"))
        XCTAssertFalse(text.contains("Secret Song"), text)
        XCTAssertTrue(text.contains("track=\"h_"), text)
    }

    func testPlainTrackNamesNeedExplicitHashFalse() throws {
        let registry = MetricsRegistry()
        let c = try make(json: #"{"tracks": {"enabled": true, "hash": false}}"#, running: ["com.apple.Music"]) { _ in
            ShellResult(status: 0, stdout: "playing\(self.rs)Song\(self.rs)Artist", stderr: "")
        }
        try c.start(registry: registry)
        try c.collect()
        XCTAssertTrue(registry.render().contains("track=\"song\",artist=\"artist\""))
    }

    func testIdlePlayerIsNotAFailure() throws {
        let registry = MetricsRegistry()
        let c = try make(running: ["com.apple.Music"]) { _ in
            ShellResult(status: 1, stdout: "", stderr: "execution error: Music got an error: Can’t get name of current track. (-1728)")
        }
        try c.start(registry: registry)
        XCTAssertNoThrow(try c.collect())
        XCTAssertEqual(registry.gauge("molly_media_playing", help: "", labels: ["app"]).value(labels: ["app": "music"]), 0)
    }

    func testScriptFailureForEveryAppIsUnavailable() throws {
        let registry = MetricsRegistry()
        let c = try make(running: ["com.apple.Music", "com.spotify.client"]) { _ in
            ShellResult(status: 1, stdout: "", stderr: "Not authorized to send Apple events")
        }
        try c.start(registry: registry)
        XCTAssertThrowsError(try c.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
    }

    func testNoRunningAppMeansNoSeriesAndNoScript() throws {
        var calls = 0
        let registry = MetricsRegistry()
        let c = try make(running: ["com.apple.Safari"]) { _ in calls += 1; return ShellResult(status: 0, stdout: "", stderr: "") }
        try c.start(registry: registry)
        try c.collect()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(registry.render().contains("molly_media_playing"))
    }
}

final class TitleNormalizerTests: XCTestCase {
    func testStripsSuffixesAndWhitespace() {
        XCTAssertEqual(TitleNormalizer.normalize("  Pull Request #42   - Google Chrome "), "Pull Request #42")
        XCTAssertEqual(TitleNormalizer.normalize("notes.md — Edited - Visual Studio Code"), "notes.md")
        XCTAssertEqual(TitleNormalizer.normalize("Plain"), "Plain")
        XCTAssertEqual(TitleNormalizer.normalize(""), "")
    }

    func testTruncates() {
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(TitleNormalizer.normalize(long).count, TitleNormalizer.maxLength)
    }
}

final class TitlesStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let a = WindowTitle(app: "Safari", title: "A")
    private let b = WindowTitle(app: "Safari", title: "B")

    func testCreditsSecondsToPreviousWindowAndFlagsChanges() {
        var s = TitlesState()
        XCTAssertEqual(s.advance(to: t0, window: a, maxGap: 10), TitlesState.Deltas(seconds: 0, changed: true))
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(5), window: a, maxGap: 10), TitlesState.Deltas(seconds: 5, changed: false))
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(10), window: b, maxGap: 10), TitlesState.Deltas(seconds: 5, changed: true))
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(60), window: b, maxGap: 10).seconds, 10)
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(61), window: nil, maxGap: 10).changed, true)
        XCTAssertEqual(s.advance(to: t0.addingTimeInterval(62), window: nil, maxGap: 10).seconds, 0)
    }
}

final class TitlesCollectorTests: XCTestCase {
    private func make(json: String = "{}", focusJSON: String = "{}", permission: Bool = true,
                      window: @escaping () -> WindowTitle?) throws -> TitlesCollector {
        let config = try Config.parse(Data(#"{"collectors": {"titles": \#(json), "focus": \#(focusJSON)}}"#.utf8))
        return try TitlesCollector(settings: config.collector("titles"), config: config,
                                   hasPermission: { permission }, frontWindow: window)
    }

    func testMissingPermissionIsUnavailable() throws {
        let c = try make(permission: false) { WindowTitle(app: "Safari", title: "x") }
        try c.start(registry: MetricsRegistry())
        XCTAssertThrowsError(try c.collect()) { error in
            XCTAssertTrue(error is CollectorUnavailable)
            XCTAssertTrue("\(error)".contains("Screen Recording"))
        }
    }

    func testTitlesAreHashedByDefaultAndSingleSeries() throws {
        let registry = MetricsRegistry()
        var current = WindowTitle(app: "Safari", title: "Secret Document - Google Chrome")
        let c = try make { current }
        try c.start(registry: registry)
        try c.collect()
        var text = registry.render()
        XCTAssertFalse(text.contains("Secret"), text)
        XCTAssertTrue(text.contains("molly_focus_window_info{app=\"safari\",title=\"h_"), text)
        current = WindowTitle(app: "Safari", title: "Other")
        try c.collect()
        text = registry.render()
        XCTAssertEqual(text.components(separatedBy: "\nmolly_focus_window_info{").count - 1, 1)
        XCTAssertTrue(text.contains("molly_focus_window_seconds_total{app=\"safari\",title=\"h_"), text)
    }

    func testPlainTitlesWithHashFalseAndDenylist() throws {
        let registry = MetricsRegistry()
        var current = WindowTitle(app: "Safari", title: "Bank Statement")
        let c = try make(json: #"{"titles": {"hash": false, "patterns": ["bank*"]}}"#) { current }
        try c.start(registry: registry)
        try c.collect()
        XCTAssertTrue(registry.render().contains("title=\"redacted\""))
        current = WindowTitle(app: "Safari", title: "Docs")
        try c.collect()
        XCTAssertTrue(registry.render().contains("title=\"docs\""))
    }

    func testAppLabelFollowsFocusPolicy() throws {
        let registry = MetricsRegistry()
        let c = try make(json: #"{"titles": {"hash": false}}"#, focusJSON: #"{"apps": {"patterns": ["1password"]}}"#) {
            WindowTitle(app: "1Password", title: "Vault")
        }
        try c.start(registry: registry)
        try c.collect()
        XCTAssertTrue(registry.render().contains("app=\"redacted\",title=\"vault\""))
    }

    func testEmptyTitleBecomesOther() throws {
        let registry = MetricsRegistry()
        let c = try make { WindowTitle(app: "Finder", title: "") }
        try c.start(registry: registry)
        try c.collect()
        XCTAssertTrue(registry.render().contains("app=\"finder\",title=\"other\""))
    }

    func testRegistryWiresBothAsOptIn() throws {
        XCTAssertTrue(CollectorRegistry.disabledByDefault.isSuperset(of: ["media", "titles"]))
        XCTAssertTrue(CollectorRegistry.knownNames.isSuperset(of: ["media", "titles"]))
        let names = try CollectorRegistry.makeCollectors(config: Config()).map(\.name)
        XCTAssertFalse(names.contains("media"))
        XCTAssertFalse(names.contains("titles"))
        let on = try Config.parse(Data(#"{"collectors": {"media": {"enabled": true}, "titles": {"enabled": true}}}"#.utf8))
        let enabled = try CollectorRegistry.makeCollectors(config: on).map(\.name)
        XCTAssertTrue(enabled.contains("media"))
        XCTAssertTrue(enabled.contains("titles"))
    }
}
