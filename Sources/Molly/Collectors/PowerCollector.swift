import Foundation

// MARK: - Pure parsers (unit-tested)

enum PowerEventKind: String, CaseIterable {
    case sleep, darkwake, wake
}

struct PowerEvent: Equatable {
    let time: Date
    let kind: PowerEventKind
    /// Normalised token for full wakes; empty for sleeps and dark wakes.
    let reason: String
}

enum PowerParse {
    static let reasonLid = "lid"
    static let reasonPowerButton = "power button"
    static let reasonUserActivity = "user activity"
    static let reasonScheduled = "scheduled"
    static let reasonNotification = "notification"
    static let reasonOther = "other"

    private static let timestampLength = 25 // "2026-11-03 08:41:12 -0500"

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }

    /// pmset prints local time with a numeric offset.
    static func timestamp(_ text: String) -> Date? {
        formatter().date(from: text)
    }

    /// Sleep, Wake and DarkWake lines only. The log is mostly Assertions noise,
    /// which is skipped before any date parsing.
    static func events(_ log: String) -> [PowerEvent] {
        let dateFormatter = formatter()
        var out: [PowerEvent] = []
        for line in log.split(whereSeparator: \.isNewline) {
            guard line.count > timestampLength + 2 else { continue }
            let rest = line.dropFirst(timestampLength + 1)
            let fields = rest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let kind = kind(of: fields[0].trimmingCharacters(in: .whitespaces)),
                  let time = dateFormatter.date(from: String(line.prefix(timestampLength))) else { continue }
            let reason = kind == .wake ? wakeReason(String(fields[1])) : ""
            out.append(PowerEvent(time: time, kind: kind, reason: reason))
        }
        return out.sorted { $0.time < $1.time }
    }

    private static func kind(of type: String) -> PowerEventKind? {
        switch type {
        case "Sleep": return .sleep
        case "Wake": return .wake
        case "DarkWake": return .darkwake
        default: return nil
        }
    }

    /// Maps the free-text reason onto a small fixed set; the raw text never leaves this function.
    static func wakeReason(_ detail: String) -> String {
        let lower = detail.lowercased()
        let afterDueTo = lower.range(of: "due to").map { String(lower[$0.upperBound...]) } ?? lower
        let text = afterDueTo.components(separatedBy: " using ").first ?? afterDueTo
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if words.contains("lid") { return reasonLid }
        if text.contains("power button") || words.contains("pwrb") || words.contains("powerbutton") { return reasonPowerButton }
        if !words.isDisjoint(with: ["hid", "keyboard", "trackpad", "mouse"]) { return reasonUserActivity }
        if !words.isDisjoint(with: ["rtc", "alarm", "maintenance", "timer", "scheduled"]) { return reasonScheduled }
        if words.contains("notification") { return reasonNotification }
        return reasonOther
    }

    /// `kern.boottime: { sec = 1789156556, usec = 652 } Fri Sep 11 15:55:56 2026`
    static func bootTime(sysctl text: String) -> Date? {
        guard let secRange = text.range(of: "sec = ") else { return nil }
        let digits = text[secRange.upperBound...].prefix { $0.isNumber }
        return Double(digits).map { Date(timeIntervalSince1970: $0) }
    }

    /// A boot is new when it is later than the last one seen; with nothing seen,
    /// only boots after the backfill floor count.
    static func isNewBoot(_ boot: Double, lastSeen: Double?, floor: Double) -> Bool {
        boot > (lastSeen ?? floor)
    }

    /// Seconds awake and asleep between `dayStart` and `now`. Full wakes are
    /// awake; sleeps and dark wakes (maintenance, Power Nap) are asleep. The
    /// state at `dayStart` comes from the last earlier event, or is inferred
    /// from the day's first event when the log starts later. Nil with no events.
    static func dayTotals(events: [PowerEvent], now: Date, dayStart: Date) -> (awake: Double, asleep: Double)? {
        let sorted = events.filter { $0.time <= now }.sorted { $0.time < $1.time }
        guard let first = sorted.first else { return nil }
        var awake = sorted.last { $0.time <= dayStart }.map { $0.kind == .wake } ?? (first.kind == .sleep)
        var cursor = dayStart
        var awakeSeconds = 0.0
        var asleepSeconds = 0.0
        func close(at end: Date) {
            let span = max(0, end.timeIntervalSince(cursor))
            if awake { awakeSeconds += span } else { asleepSeconds += span }
            cursor = end
        }
        for event in sorted where event.time > dayStart {
            close(at: event.time)
            awake = event.kind == .wake
        }
        close(at: now)
        return (awakeSeconds, asleepSeconds)
    }
}

// MARK: - Collector

/// Sleep, wake and boot history from `pmset -g log`. The first run backfills
/// `backfillSeconds` so a fresh install explains the last day; after that a
/// cursor on the newest parsed event keeps counters incremental.
final class PowerCollector: Collector {
    let name = "power"
    let interval: TimeInterval

    private static let pmsetTimeout: TimeInterval = 30
    private static let sysctlTimeout: TimeInterval = 5
    private static let cursorKey = "cursor"
    private static let bootKey = "boot"

    private let backfillSeconds: Double
    private let store: StateStore
    private let startedAt: Date

    private var sleepEvents: Counter?
    private var lastSleep: Gauge?
    private var lastWake: Gauge?
    private var lastWakeReason: Gauge?
    private var boots: Counter?
    private var lastBoot: Gauge?
    private var awakeToday: Gauge?
    private var sleepToday: Gauge?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, startedAt: Date = Date()) {
        interval = settings.interval(default: 300)
        backfillSeconds = max(0, settings.double("backfillSeconds", default: 86400))
        store = StateStore(collector: "power", folder: stateFolder)
        self.startedAt = startedAt
    }

    func start(registry: MetricsRegistry) throws {
        sleepEvents = registry.counter("molly_power_sleep_events_total", help: "Sleep, dark wake and wake events from the power log.", labels: ["kind"])
        lastSleep = registry.gauge("molly_power_last_sleep_timestamp_seconds", help: "Unix time of the latest sleep.")
        lastWake = registry.gauge("molly_power_last_wake_timestamp_seconds", help: "Unix time of the latest full wake.")
        lastWakeReason = registry.gauge("molly_power_last_wake_reason_info", help: "Always 1; the reason token of the latest full wake.", labels: ["reason"])
        boots = registry.counter("molly_power_boots_total", help: "Boots seen since the backfill window started.")
        lastBoot = registry.gauge("molly_power_last_boot_timestamp_seconds", help: "Unix time of the latest boot.")
        awakeToday = registry.gauge("molly_power_awake_seconds_today", help: "Seconds fully awake since local midnight.")
        sleepToday = registry.gauge("molly_power_sleep_seconds_today", help: "Seconds asleep, including dark wakes, since local midnight.")
        for kind in PowerEventKind.allCases { sleepEvents?.touch(labels: ["kind": kind.rawValue]) }
        boots?.touch()
    }

    func collect() throws {
        let result: ShellResult
        do {
            result = try Shell.run("/usr/bin/pmset", ["-g", "log"], timeout: Self.pmsetTimeout)
        } catch {
            throw CollectorUnavailable(reason: "pmset unavailable: \(error)")
        }
        guard result.succeeded else { throw CollectorUnavailable(reason: "pmset -g log exited \(result.status)") }

        let events = PowerParse.events(result.stdout)
        let floor = startedAt.timeIntervalSince1970 - backfillSeconds
        let cursor = store.double(Self.cursorKey) ?? floor
        let fresh = events.filter { $0.time.timeIntervalSince1970 > cursor }
        for event in fresh { sleepEvents?.inc(labels: ["kind": event.kind.rawValue]) }
        store.set(Self.cursorKey, fresh.last?.time.timeIntervalSince1970 ?? cursor)

        publishLatest(events)
        publishDay(events)
        collectBoot(floor: floor)
        do { try store.save() } catch { Log.warn("power: cannot save state: \(error)") }
    }

    private func publishLatest(_ events: [PowerEvent]) {
        if let sleep = events.last(where: { $0.kind == .sleep }) {
            lastSleep?.set(sleep.time.timeIntervalSince1970)
        }
        if let wake = events.last(where: { $0.kind == .wake }) {
            lastWake?.set(wake.time.timeIntervalSince1970)
            lastWakeReason?.reset()
            lastWakeReason?.set(1, labels: ["reason": wake.reason])
        }
    }

    private func publishDay(_ events: [PowerEvent]) {
        let now = Date()
        guard let totals = PowerParse.dayTotals(events: events, now: now, dayStart: Clock.startOfToday(now: now)) else { return }
        awakeToday?.set(totals.awake)
        sleepToday?.set(totals.asleep)
    }

    private func collectBoot(floor: Double) {
        guard let result = try? Shell.run("/usr/sbin/sysctl", ["kern.boottime"], timeout: Self.sysctlTimeout), result.succeeded,
              let boot = PowerParse.bootTime(sysctl: result.stdout) else { return }
        let seconds = boot.timeIntervalSince1970
        if PowerParse.isNewBoot(seconds, lastSeen: store.double(Self.bootKey), floor: floor) { boots?.inc() }
        store.set(Self.bootKey, seconds)
        lastBoot?.set(seconds)
    }
}
