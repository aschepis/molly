import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Pure aggregation (unit-tested)

/// Counts input events by kind and keeps a rolling window of timestamps so
/// per-minute rates can be derived. Invariant: this type has no field that
/// could hold a keycode, character, or pointer position. Only counts exist.
struct InputAggregator: Equatable {
    enum Kind: String, CaseIterable { case key, click, scroll }

    let window: TimeInterval
    private(set) var totals: [Kind: Int] = [:]
    private var recent: [Kind: [Date]] = [:]

    init(window: TimeInterval = 60) { self.window = window }

    mutating func record(_ kind: Kind, at now: Date) {
        totals[kind, default: 0] += 1
        recent[kind, default: []].append(now)
    }

    /// Events of `kind` inside the trailing window ending at `now`.
    mutating func countInWindow(_ kind: Kind, now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-window)
        let kept = (recent[kind] ?? []).filter { $0 > cutoff }
        recent[kind] = kept
        return kept.count
    }

    /// Takes and resets the per-kind counts accumulated since the last drain.
    mutating func drain() -> [Kind: Int] {
        defer { totals = [:] }
        return totals
    }

    static func kind(of type: CGEventType) -> Kind? {
        switch type {
        case .keyDown, .flagsChanged: return .key
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .click
        case .scrollWheel: return .scroll
        default: return nil
        }
    }
}

// MARK: - Collector

/// Typing and clicking intensity from a listen-only event tap. Needs
/// Accessibility (or Input Monitoring) permission; off by default.
final class InputCollector: Collector {
    let name = "input"
    let interval: TimeInterval

    private let lock = NSLock()
    private var aggregator = InputAggregator()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    private var eventsTotal: Counter?
    private var keysPerMinute: Gauge?
    private var clicksPerMinute: Gauge?
    private var scrollsPerMinute: Gauge?
    private var available: Gauge?

    init(settings: CollectorSettings) {
        interval = settings.interval(default: 5)
    }

    func start(registry r: MetricsRegistry) throws {
        eventsTotal = r.counter("molly_input_events_total", help: "Input events by kind. Counts only; never keycodes or positions.", labels: ["kind"])
        keysPerMinute = r.gauge("molly_input_keys_per_minute", help: "Key events in the trailing 60 seconds.")
        clicksPerMinute = r.gauge("molly_input_clicks_per_minute", help: "Mouse clicks in the trailing 60 seconds.")
        scrollsPerMinute = r.gauge("molly_input_scrolls_per_minute", help: "Scroll events in the trailing 60 seconds.")
        available = r.gauge("molly_input_available", help: "1 when the event tap is installed (Accessibility granted).")
        for kind in InputAggregator.Kind.allCases { eventsTotal?.touch(labels: ["kind": kind.rawValue]) }
        startTap()
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    func collect() throws {
        guard tap != nil else {
            available?.set(0)
            throw CollectorUnavailable(reason: "event tap not installed: grant Accessibility (or Input Monitoring) to the molly binary or Molly.app in System Settings > Privacy & Security")
        }
        available?.set(1)
        let now = Date()
        lock.lock()
        let drained = aggregator.drain()
        let keys = aggregator.countInWindow(.key, now: now)
        let clicks = aggregator.countInWindow(.click, now: now)
        let scrolls = aggregator.countInWindow(.scroll, now: now)
        lock.unlock()
        for (kind, n) in drained where n > 0 {
            eventsTotal?.add(Double(n), labels: ["kind": kind.rawValue])
        }
        keysPerMinute?.set(keys)
        clicksPerMinute?.set(clicks)
        scrollsPerMinute?.set(scrolls)
    }

    // MARK: Tap plumbing

    private func startTap() {
        let mask: CGEventMask = [CGEventType.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: inputTapCallback, userInfo: selfPointer) else {
            available?.set(0)
            Log.warn("input: could not create event tap (Accessibility permission missing?)")
            return
        }
        self.tap = tap
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let loop = CFRunLoopGetCurrent()
            self.runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "molly.input.tap"
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
        available?.set(1)
    }

    fileprivate func handle(type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS disables slow taps; a listen-only tap can simply be re-armed.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let kind = InputAggregator.kind(of: type) else { return }
        lock.lock()
        aggregator.record(kind, at: Date())
        lock.unlock()
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<InputCollector>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type)
    }
    return Unmanaged.passUnretained(event)
}
