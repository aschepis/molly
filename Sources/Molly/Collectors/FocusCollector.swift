import AppKit
import CoreGraphics
import Foundation

// MARK: - Pure state machine (unit-tested)

struct FocusApp: Hashable {
    let name: String
    let bundleID: String
}

/// What changed between two `advance` calls.
struct FocusDeltas: Equatable {
    /// Seconds credited to each app: only while the user was active.
    var focusSeconds: [FocusApp: Double] = [:]
    var activeSeconds: Double = 0
    var idleSeconds: Double = 0
    var switches = 0
    var lockEvents = 0
    var sleepEvents = 0
    var wakeEvents = 0
}

/// Tracks which app is frontmost and whether the user is present.
///
/// Each interval between two `advance` calls is attributed using the state
/// known at the start of it, so time is never credited retroactively: when the
/// user comes back from idle, up to one poll interval is still counted as idle.
struct FocusState {
    let idleThreshold: Double
    /// Intervals longer than this (process suspended, missed wake notification)
    /// are dropped rather than credited.
    let maxGap: Double

    private(set) var frontmost: FocusApp?
    private(set) var appSince: Date?
    private(set) var locked = false
    private(set) var asleep = false
    private(set) var userActive = false
    private var lastTick: Date?

    init(idleThreshold: Double = 300, maxGap: Double = 60) {
        self.idleThreshold = idleThreshold
        self.maxGap = maxGap
    }

    /// Seconds spent in the current frontmost app.
    func sessionSeconds(at now: Date) -> Double {
        appSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    mutating func advance(to now: Date, frontmost newApp: FocusApp?, idleSeconds: Double,
                          locked newLocked: Bool, asleep newAsleep: Bool) -> FocusDeltas {
        var deltas = FocusDeltas()
        if let last = lastTick {
            let elapsed = now.timeIntervalSince(last)
            if elapsed > 0, elapsed <= maxGap { attribute(elapsed, to: &deltas) }
        } else {
            appSince = now
        }
        lastTick = now

        if let newApp, newApp != frontmost {
            if frontmost != nil { deltas.switches += 1 }
            appSince = now
            frontmost = newApp
        }
        if newLocked && !locked { deltas.lockEvents += 1 }
        if newAsleep && !asleep { deltas.sleepEvents += 1 }
        if !newAsleep && asleep { deltas.wakeEvents += 1 }
        locked = newLocked
        asleep = newAsleep
        userActive = !newAsleep && !newLocked && idleSeconds < idleThreshold
        return deltas
    }

    private func attribute(_ elapsed: Double, to deltas: inout FocusDeltas) {
        if asleep { return }
        if userActive {
            deltas.activeSeconds = elapsed
            if let frontmost { deltas.focusSeconds[frontmost] = elapsed }
        } else {
            deltas.idleSeconds = elapsed
        }
    }
}

/// Bounds the number of distinct label values a counter can mint, because a
/// counter series cannot be folded into "other" after the fact.
struct CardinalityGuard {
    let limit: Int
    private var seen: Set<String> = []

    init(limit: Int) { self.limit = limit }

    mutating func admit(_ label: String) -> String {
        if limit <= 0 || seen.contains(label) { return label }
        if seen.count < limit {
            seen.insert(label)
            return label
        }
        return LabelPolicy.other
    }
}

// MARK: - Collector

/// App focus, presence, sleep/lock and window counts. Event-driven for
/// transitions, plus a poll for idle time (which has no notification).
final class FocusCollector: Collector {
    let name = "focus"
    let interval: TimeInterval

    // kCGAnyInputEventType is (CGEventType)(~0), which Swift does not expose by name.
    private static let anyInputEventType = CGEventType(rawValue: ~0)

    private let appFilter: LabelFilter
    private let lock = NSLock()
    private var state: FocusState
    private var cardinality: CardinalityGuard
    private var screensaver = false
    private var lockedInput = false
    private var asleepInput = false
    private var frontmostApp: FocusApp?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private var focusApp: Gauge?
    private var focusSeconds: Counter?
    private var switches: Counter?
    private var sessionSeconds: Gauge?
    private var idleGauge: Gauge?
    private var userActive: Gauge?
    private var activeTotal: Counter?
    private var idleTotal: Counter?
    private var screenLocked: Gauge?
    private var lockEvents: Counter?
    private var screensaverGauge: Gauge?
    private var systemAsleep: Gauge?
    private var sleepEvents: Counter?
    private var wakeEvents: Counter?
    private var runningApps: Gauge?
    private var runningApp: Gauge?
    private var windows: Gauge?
    private var launches: Counter?
    private var terminations: Counter?

    init(settings: CollectorSettings) throws {
        interval = settings.interval(default: 5)
        appFilter = try settings.filter("apps", defaults: LabelPolicy(enabled: true, mode: .denylist))
        cardinality = CardinalityGuard(limit: appFilter.maxCardinality)
        state = FocusState(idleThreshold: settings.double("idleThresholdSeconds", default: 300),
                           maxGap: settings.double("maxGapSeconds", default: 60))
    }

    func start(registry r: MetricsRegistry) throws {
        let app = ["app"]
        focusApp = r.gauge("molly_focus_app", help: "The frontmost app (exactly one series).", labels: ["app", "bundle_id"])
        focusSeconds = r.counter("molly_focus_seconds_total", help: "Frontmost time per app while the user is active.", labels: app)
        switches = r.counter("molly_focus_switches_total", help: "Frontmost app changes.")
        sessionSeconds = r.gauge("molly_focus_session_seconds", help: "Time in the current frontmost app.")
        idleGauge = r.gauge("molly_idle_seconds", help: "Seconds since the last keyboard or mouse input.")
        userActive = r.gauge("molly_user_active", help: "1 when recently active, screen unlocked and awake.")
        activeTotal = r.counter("molly_active_seconds_total", help: "Seconds the user was active.")
        idleTotal = r.counter("molly_idle_seconds_total", help: "Awake seconds the user was not active (idle or locked).")
        screenLocked = r.gauge("molly_screen_locked", help: "1 while the screen is locked.")
        lockEvents = r.counter("molly_screen_lock_events_total", help: "Screen lock events.")
        screensaverGauge = r.gauge("molly_screensaver_active", help: "1 while the screensaver runs.")
        systemAsleep = r.gauge("molly_system_asleep", help: "1 while asleep (only visible to scrapes around a sleep).")
        sleepEvents = r.counter("molly_sleep_events_total", help: "Sleep events.")
        wakeEvents = r.counter("molly_wake_events_total", help: "Wake events.")
        runningApps = r.gauge("molly_running_apps", help: "Running regular (Dock) apps.")
        runningApp = r.gauge("molly_running_app", help: "A running regular app.", labels: app)
        windows = r.gauge("molly_windows_on_screen", help: "Normal-layer windows on screen (no titles are read).")
        launches = r.counter("molly_app_launches_total", help: "App launches.", labels: app)
        terminations = r.counter("molly_app_terminations_total", help: "App terminations.", labels: app)

        frontmostApp = NSWorkspace.shared.frontmostApplication.flatMap(Self.focusApp)
        for c in [switches, activeTotal, idleTotal, lockEvents, sleepEvents, wakeEvents] { c?.touch() }
        registerObservers()
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    func collect() throws {
        tick()
        refreshSnapshots()
    }

    // MARK: Events

    private func registerObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            self?.apply { $0.frontmostApp = Self.application(in: note).flatMap(Self.focusApp) }
        }
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            self?.count(self?.launches, app: Self.application(in: note))
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            self?.count(self?.terminations, app: Self.application(in: note))
        }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in self?.apply { $0.asleepInput = true } }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in self?.apply { $0.asleepInput = false } }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.apply { $0.lockedInput = true } }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.apply { $0.lockedInput = false } }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { [weak self] _ in self?.apply { $0.screensaver = true } }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { [weak self] _ in self?.apply { $0.screensaver = false } }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: handler)))
    }

    /// Updates an input under the lock, then folds the elapsed time in at the moment of the event.
    private func apply(_ change: (FocusCollector) -> Void) {
        lock.lock()
        change(self)
        lock.unlock()
        tick()
    }

    private func count(_ counter: Counter?, app: NSRunningApplication?) {
        guard appFilter.enabled, let app, app.activationPolicy == .regular, let label = appLabel(app.localizedName ?? "") else { return }
        counter?.inc(labels: ["app": label])
    }

    private static func application(in note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private static func focusApp(_ app: NSRunningApplication) -> FocusApp? {
        guard let name = app.localizedName else { return nil }
        return FocusApp(name: name, bundleID: app.bundleIdentifier ?? "")
    }

    // MARK: Time accounting

    private func idleSecondsNow() -> Double {
        guard let any = Self.anyInputEventType else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private func tick() {
        let idle = idleSecondsNow()
        lock.lock()
        let now = Date()
        let deltas = state.advance(to: now, frontmost: frontmostApp, idleSeconds: idle,
                                   locked: lockedInput, asleep: asleepInput)
        let snapshot = (state.frontmost, state.sessionSeconds(at: now), state.userActive, state.locked,
                        state.asleep, screensaver, cardinalityLabels(deltas.focusSeconds))
        lock.unlock()

        publish(deltas, labeledFocus: snapshot.6)
        idleGauge?.set(idle)
        sessionSeconds?.set(snapshot.1)
        userActive?.set(snapshot.2 ? 1 : 0)
        screenLocked?.set(snapshot.3 ? 1 : 0)
        systemAsleep?.set(snapshot.4 ? 1 : 0)
        screensaverGauge?.set(snapshot.5 ? 1 : 0)
        publishFocusApp(snapshot.0)
    }

    /// Must be called with the lock held: it mutates the cardinality guard.
    private func cardinalityLabels(_ seconds: [FocusApp: Double]) -> [String: Double] {
        guard appFilter.enabled else { return [:] }
        var out: [String: Double] = [:]
        for (app, value) in seconds {
            out[cardinality.admit(appFilter.label(app.name)), default: 0] += value
        }
        return out
    }

    private func publish(_ d: FocusDeltas, labeledFocus: [String: Double]) {
        for (label, seconds) in labeledFocus { focusSeconds?.add(seconds, labels: ["app": label]) }
        if d.activeSeconds > 0 { activeTotal?.add(d.activeSeconds) }
        if d.idleSeconds > 0 { idleTotal?.add(d.idleSeconds) }
        if d.switches > 0 { switches?.add(Double(d.switches)) }
        if d.lockEvents > 0 { lockEvents?.add(Double(d.lockEvents)) }
        if d.sleepEvents > 0 { sleepEvents?.add(Double(d.sleepEvents)) }
        if d.wakeEvents > 0 { wakeEvents?.add(Double(d.wakeEvents)) }
    }

    private func publishFocusApp(_ app: FocusApp?) {
        focusApp?.reset()
        guard appFilter.enabled, let app else { return }
        focusApp?.set(1, labels: ["app": appLabel(app.name) ?? LabelPolicy.other,
                                  "bundle_id": appFilter.label(app.bundleID)])
    }

    private func appLabel(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cardinality.admit(appFilter.label(name))
    }

    // MARK: Snapshots

    private func refreshSnapshots() {
        let apps = onMain { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { $0.localizedName } }
        runningApps?.set(Double(apps.count))
        runningApp?.reset()
        if appFilter.enabled {
            for (label, n) in appFilter.labels(Dictionary(apps.map { ($0, 1.0) }, uniquingKeysWith: +)) {
                runningApp?.set(n, labels: ["app": label])
            }
        }
        windows?.set(Double(Self.onScreenWindowCount()))
    }

    /// NSWorkspace is main-thread API; `once` already runs on main, the daemon does not.
    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    static func onScreenWindowCount() -> Int {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.count
    }
}
