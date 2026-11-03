import Foundation

/// Apple Health numbers pushed by an iPhone Shortcut to `POST /health`.
/// macOS has no HealthKit, so the phone is the only source. Opt-in, token
/// protected, and refused on a non-loopback bind unless `allowRemoteBind` says
/// the user accepted that health data travels over the LAN.
final class HealthCollector: Collector {
    enum Outcome: Equatable {
        case accepted(accepted: Int, rejected: [String: Int])
        case unauthorized
        case forbidden
        case badRequest(String)
    }

    static let stateDaysKey = "days"
    static let stateLastSampleKey = "lastSample"
    static let stateLastPostKey = "lastPost"
    static let stateDevicesKey = "devices"
    static let bearerPrefix = "Bearer "
    static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
    static let remoteBindMessage = "health data stays on this machine unless you set "
        + "collectors.health.allowRemoteBind to true; server.bind is not a loopback address"
    private static let nightTypes: [HealthType] = [.sleepMinutes, .bedtime, .wakeTime]

    let name = "health"
    let interval: TimeInterval
    private let token: String
    private let maxAge: TimeInterval
    private let allowRemoteBind: Bool
    private let bind: String
    private let calendar: Calendar
    private let now: () -> Date
    private let store: StateStore

    private var today: Gauge?
    private var yesterday: Gauge?
    private var lastSample: Gauge?
    private var samplesTotal: Counter?
    private var rejectedTotal: Counter?
    private var lastPost: Gauge?
    private var deviceInfo: Gauge?
    private var sleepLastNight: Gauge?
    private var bedtimeSeconds: Gauge?

    private let lock = NSLock()
    private var days = HealthDays()
    private var lastSampleAt: [String: Double] = [:]
    private var lastPostAt: Double?
    private var devices: [String] = []

    init(settings: CollectorSettings, bind: String, now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current, stateFolder: URL = Paths.stateFolder) {
        interval = settings.interval(default: 60)
        token = settings.string("token", default: "")
        maxAge = settings.double("maxAgeSeconds", default: HealthLimits.defaultMaxAgeSeconds)
        allowRemoteBind = settings.bool("allowRemoteBind", default: false)
        self.bind = bind
        self.now = now
        self.calendar = calendar
        store = StateStore(collector: "health", folder: stateFolder)
    }

    static func isLoopback(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased()) || host.hasPrefix("127.")
    }

    /// The route and `start` share this: false means health data must not be served.
    var bindIsAllowed: Bool { allowRemoteBind || HealthCollector.isLoopback(bind) }

    func start(registry: MetricsRegistry) throws {
        guard bindIsAllowed else { throw CollectorUnavailable(reason: HealthCollector.remoteBindMessage) }
        today = registry.gauge("molly_health_today", help: "Apple Health value so far today, by type.", labels: ["type"])
        yesterday = registry.gauge("molly_health_yesterday", help: "Apple Health value for yesterday, by type.", labels: ["type"])
        lastSample = registry.gauge("molly_health_last_sample_timestamp_seconds", help: "Unix time of the newest accepted sample, by type.", labels: ["type"])
        samplesTotal = registry.counter("molly_health_samples_total", help: "Health samples accepted from POST /health.", labels: ["type"])
        rejectedTotal = registry.counter("molly_health_samples_rejected_total", help: "Health samples refused, by reason.", labels: ["reason"])
        lastPost = registry.gauge("molly_health_last_post_timestamp_seconds", help: "Unix time of the last authenticated POST /health.")
        deviceInfo = registry.gauge("molly_health_device_info", help: "Devices that have posted health data; always 1.", labels: ["device"])
        sleepLastNight = registry.gauge("molly_health_sleep_minutes_last_night", help: "Minutes asleep in the night that ended most recently.")
        bedtimeSeconds = registry.gauge("molly_health_bedtime_seconds", help: "Bedtime of the last night, in seconds after the previous midnight (01:15 is 90900).")
        for reason in HealthRejection.allCases { rejectedTotal?.touch(labels: ["reason": reason.rawValue]) }
        loadState()
        publish()
    }

    func collect() throws {
        lock.lock()
        defer { lock.unlock() }
        pruneOldDays()
        publish()
        persist()
    }

    /// Order matters: the guard and the token come before the body is judged,
    /// so a wrong token learns nothing about the payload.
    func handle(body: Data, authorization: String?) -> Outcome {
        guard bindIsAllowed else { return .forbidden }
        let object = (try? JSONValue.parse(body))?.objectValue
        guard isAuthorized(header: authorization, body: object) else { return .unauthorized }
        guard let object else { return .badRequest("body must be a JSON object") }
        let parser = HealthPayloadParser(now: now(), maxAge: maxAge, calendar: calendar)
        guard let result = parser.parse(object) else { return .badRequest("samples or totals is required") }

        lock.lock()
        defer { lock.unlock() }
        let at = now()
        for sample in result.samples {
            days.apply(sample)
            lastSampleAt[sample.type.rawValue] = max(lastSampleAt[sample.type.rawValue] ?? 0, sample.at.timeIntervalSince1970)
            samplesTotal?.inc(labels: ["type": sample.type.rawValue])
        }
        for (reason, count) in result.rejected {
            rejectedTotal?.add(Double(count), labels: ["reason": reason.rawValue])
        }
        registerDevice(HealthDevice.sanitize(result.device))
        lastPostAt = at.timeIntervalSince1970
        pruneOldDays()
        publish()
        persist()
        let rejected = Dictionary(uniqueKeysWithValues: result.rejected.map { ($0.key.rawValue, $0.value) })
        return .accepted(accepted: result.samples.count, rejected: rejected)
    }

    // MARK: auth

    /// An empty token disables the endpoint entirely.
    private func isAuthorized(header: String?, body: [String: JSONValue]?) -> Bool {
        guard !token.isEmpty else { return false }
        if let header, header.hasPrefix(HealthCollector.bearerPrefix),
           HealthCollector.constantTimeEquals(String(header.dropFirst(HealthCollector.bearerPrefix.count)), token) {
            return true
        }
        if let posted = body?["token"]?.stringValue {
            return HealthCollector.constantTimeEquals(posted, token)
        }
        return false
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        var difference = x.count ^ y.count
        for index in 0..<min(x.count, y.count) {
            difference |= Int(x[index] ^ y[index])
        }
        return difference == 0
    }

    // MARK: state

    private func registerDevice(_ device: String) {
        let distinct = devices.filter { $0 != HealthLimits.otherDevice }
        let label = distinct.contains(device) || distinct.count < HealthLimits.maxDevices ? device : HealthLimits.otherDevice
        if !devices.contains(label) { devices.append(label) }
    }

    /// Keeps enough days for `maxAgeSeconds` plus today and yesterday.
    private func pruneOldDays() {
        let today = HealthTime.dayKey(now(), calendar: calendar)
        let retained = max(2, Int((maxAge / HealthLimits.secondsPerDay).rounded(.up)) + 1)
        let keep = (0..<retained).compactMap { HealthTime.addingDays(-$0, to: today, calendar: calendar) }
        days.prune(keeping: Set(keep))
    }

    private func loadState() {
        lock.lock()
        defer { lock.unlock() }
        if let json = store.get(HealthCollector.stateDaysKey),
           let data = try? JSONEncoder().encode(json),
           let loaded = try? JSONDecoder().decode(HealthDays.self, from: data) {
            days = loaded
        }
        lastSampleAt = (store.get(HealthCollector.stateLastSampleKey)?.objectValue ?? [:]).compactMapValues { $0.doubleValue }
        lastPostAt = store.double(HealthCollector.stateLastPostKey)
        devices = (store.get(HealthCollector.stateDevicesKey)?.arrayValue ?? []).compactMap { $0.stringValue }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(days), let json = try? JSONValue.parse(data) {
            store.set(HealthCollector.stateDaysKey, json)
        }
        store.set(HealthCollector.stateLastSampleKey, .object(lastSampleAt.mapValues { .number($0) }))
        if let lastPostAt { store.set(HealthCollector.stateLastPostKey, lastPostAt) }
        store.set(HealthCollector.stateDevicesKey, .array(devices.map { .string($0) }))
        do {
            try store.save()
        } catch {
            Log.warn("health: could not save state: \(error)")
        }
    }

    /// Rebuilds every gauge from the day table, so a type with no data today
    /// disappears instead of showing yesterday's number.
    private func publish() {
        let todayKey = HealthTime.dayKey(now(), calendar: calendar)
        let yesterdayKey = HealthTime.addingDays(-1, to: todayKey, calendar: calendar) ?? todayKey
        today?.reset()
        yesterday?.reset()
        for type in HealthType.allCases {
            let labels = ["type": type.rawValue]
            if let value = days.value(type, day: todayKey) { today?.set(value, labels: labels) }
            if let value = days.value(type, day: yesterdayKey) { yesterday?.set(value, labels: labels) }
        }
        for (type, timestamp) in lastSampleAt { lastSample?.set(timestamp, labels: ["type": type]) }
        if let lastPostAt { lastPost?.set(lastPostAt) }
        for device in devices { deviceInfo?.set(1, labels: ["device": device]) }

        // "Last night" is the wake-up day's sleep, or yesterday's until today's arrives.
        let night = days.hasAny(HealthCollector.nightTypes, day: todayKey) ? todayKey : yesterdayKey
        sleepLastNight?.reset()
        bedtimeSeconds?.reset()
        if let minutes = days.value(.sleepMinutes, day: night) { sleepLastNight?.set(minutes) }
        if let bedtime = days.value(.bedtime, day: night) { bedtimeSeconds?.set(bedtime) }
    }
}
