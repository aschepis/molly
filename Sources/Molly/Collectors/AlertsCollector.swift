import Foundation
import UserNotifications

/// Prometheus rules fire into nothing on the local stack (no Alertmanager), so
/// this polls `/api/v1/alerts` and turns each new firing alert into a macOS
/// notification.
enum AlertSeverity: Int, Comparable {
    case info, warning, critical

    init(label: String?) {
        switch label?.lowercased() {
        case "critical": self = .critical
        case "warning": self = .warning
        default: self = .info
        }
    }

    static func < (a: AlertSeverity, b: AlertSeverity) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .info: return "info"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

struct FiringAlert: Equatable {
    let name: String
    let severity: AlertSeverity
    let summary: String
    let description: String
}

/// One row of the static catalog behind the Settings mute list. A test keeps
/// it in step with `deploy/prometheus/rules/molly.yml`.
struct AlertInfo: Equatable {
    let name: String
    let severity: AlertSeverity
    let summary: String
}

enum AlertCatalog {
    static let all: [AlertInfo] = [
        AlertInfo(name: "MollyDown", severity: .info, summary: "Prometheus cannot scrape Molly."),
        AlertInfo(name: "LongSessionNoBreak", severity: .info, summary: "Two hours of continuous activity."),
        AlertInfo(name: "LongGamingSession", severity: .info, summary: "Three hours in one gaming session."),
        AlertInfo(name: "HighMemoryPressure", severity: .info, summary: "Memory pressure elevated for 10 minutes."),
        AlertInfo(name: "BatteryLow", severity: .info, summary: "Battery below 15% and not on AC power."),
        AlertInfo(name: "SwitchRateSpike", severity: .info, summary: "App switching is twice your weekly norm."),
        AlertInfo(name: "NoBreakFourHours", severity: .info, summary: "Four hours without a break."),
        AlertInfo(name: "ActiveDayNoCommits", severity: .info, summary: "Six or more active hours and no commits today."),
        AlertInfo(name: "WindDownGaming", severity: .info, summary: "Gaming started after a long day."),
        AlertInfo(name: "MemoryPressureCritical", severity: .info, summary: "Critical memory pressure for 5 minutes."),
        AlertInfo(name: "HighClaudeSpend", severity: .info, summary: "Estimated Claude spend above the daily threshold."),
        AlertInfo(name: "MeetingMarathon", severity: .info, summary: "More than 4 hours of meetings today."),
        AlertInfo(name: "DiskAlmostFull", severity: .info, summary: "Less than 10% of the data volume free."),
        AlertInfo(name: "CollectorFailing", severity: .info, summary: "A collector keeps failing."),
        AlertInfo(name: "ScrapeLarge", severity: .info, summary: "Molly exposes more than 5000 series."),
        AlertInfo(name: "NotStandingEnough", severity: .info, summary: "90 minutes at the machine without standing up."),
    ]
}

struct AlertsSettings: Equatable {
    static let defaultInterval: TimeInterval = 30
    static let defaultRepeatAfter: TimeInterval = 4 * 3600

    var prometheusURL: String
    var notify: Bool
    var muted: Set<String>
    var minSeverity: AlertSeverity
    var repeatAfter: TimeInterval

    init(settings: CollectorSettings, links: Config.Links) {
        prometheusURL = settings.string("prometheusURL", default: links.prometheus)
        notify = settings.bool("notify", default: true)
        muted = Set(settings.strings("muted"))
        minSeverity = AlertSeverity(label: settings.string("minSeverity", default: "info"))
        repeatAfter = max(0, settings.double("repeatAfterSeconds", default: AlertsSettings.defaultRepeatAfter))
    }
}

/// Reads the `/api/v1/alerts` body. Pending alerts are ignored; they have not
/// held for their `for:` duration yet.
enum AlertsParser {
    static func parse(_ data: Data) throws -> [FiringAlert] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "success",
              let payload = root["data"] as? [String: Any],
              let alerts = payload["alerts"] as? [[String: Any]] else {
            throw PrometheusClient.ClientError.badResponse("not an alerts response")
        }
        var seen = Set<String>()
        var result: [FiringAlert] = []
        for alert in alerts where alert["state"] as? String == "firing" {
            let labels = alert["labels"] as? [String: String] ?? [:]
            let notes = alert["annotations"] as? [String: String] ?? [:]
            guard let name = labels["alertname"], seen.insert(name).inserted else { continue }
            result.append(FiringAlert(
                name: name, severity: AlertSeverity(label: labels["severity"]),
                summary: notes["summary"] ?? name, description: notes["description"] ?? ""))
        }
        return result
    }
}

/// Decides what to notify. Pure: the clock and the rules come in as arguments.
struct AlertTracker {
    struct Seen: Equatable {
        let severity: AlertSeverity
        let firing: Bool
    }

    struct Outcome: Equatable {
        /// Alerts that went from not firing to firing and passed every filter.
        var toNotify: [FiringAlert]
        /// Every alert seen so far; `firing` is false once it resolved.
        var seen: [String: Seen]
    }

    private var firing: Set<String> = []
    private var severities: [String: AlertSeverity] = [:]
    private var lastNotified: [String: Date] = [:]

    var firingCount: Int { firing.count }

    mutating func update(current: [FiringAlert], now: Date, muted: Set<String>,
                         minSeverity: AlertSeverity, repeatAfter: TimeInterval) -> Outcome {
        var toNotify: [FiringAlert] = []
        for alert in current {
            severities[alert.name] = alert.severity
            guard !firing.contains(alert.name) else { continue }
            guard !muted.contains(alert.name), alert.severity >= minSeverity else { continue }
            if let last = lastNotified[alert.name], now.timeIntervalSince(last) < repeatAfter { continue }
            lastNotified[alert.name] = now
            toNotify.append(alert)
        }
        firing = Set(current.map { $0.name })
        let seen = severities.reduce(into: [String: Seen]()) {
            $0[$1.key] = Seen(severity: $1.value, firing: firing.contains($1.key))
        }
        return Outcome(toNotify: toNotify, seen: seen)
    }
}

protocol AlertNotifier: AnyObject {
    /// 1 granted, 0 denied or unavailable, -1 not asked yet.
    var authorization: Int { get }
    func post(_ alert: FiringAlert)
}

/// Firing count for the menu bar, written by the collector.
enum AlertsStatus {
    private static let lock = NSLock()
    private static var count = 0

    static var firingCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return count }
        set { lock.lock(); defer { lock.unlock() }; count = newValue }
    }
}

/// Posts through UNUserNotificationCenter, which raises an Objective-C
/// exception (not catchable in Swift) without an app bundle, so that case is
/// checked up front and logged once.
final class SystemAlertNotifier: AlertNotifier {
    private let lock = NSLock()
    private var state = -1
    // Only touched on the main queue.
    private var requested = false
    private var pending: [FiringAlert] = []

    var authorization: Int {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func setState(_ value: Int) {
        lock.lock()
        state = value
        lock.unlock()
    }

    func post(_ alert: FiringAlert) {
        DispatchQueue.main.async { [self] in
            guard MenuModel.isBundled(bundleURL: Bundle.main.bundleURL) else {
                if !requested {
                    requested = true
                    setState(0)
                    Log.warn("alerts: notifications need Molly.app; metrics continue without them")
                }
                return
            }
            pending.append(alert)
            if !requested {
                requested = true
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [self] granted, error in
                    if let error { Log.warn("alerts: notification authorization failed: \(error)") }
                    setState(granted ? 1 : 0)
                    DispatchQueue.main.async { self.flush() }
                }
            } else if authorization >= 0 {
                flush()
            }
        }
    }

    private func flush() {
        let alerts = pending
        pending = []
        guard authorization == 1 else { return }
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.summary
            content.body = alert.description
            center.add(UNNotificationRequest(identifier: "molly-alert-\(alert.name)", content: content, trigger: nil)) { error in
                if let error { Log.warn("alerts: could not post \(alert.name): \(error)") }
            }
        }
    }
}

final class AlertsCollector: Collector {
    let name = "alerts"
    let interval: TimeInterval
    private let settings: AlertsSettings
    private let client: PrometheusClient
    private let notifier: AlertNotifier
    private var tracker = AlertTracker()
    private var active: Gauge?
    private var notifications: Counter?
    private var authorized: Gauge?

    init(settings: CollectorSettings, config: Config, notifier: AlertNotifier = SystemAlertNotifier()) throws {
        self.settings = AlertsSettings(settings: settings, links: config.links)
        interval = settings.interval(default: AlertsSettings.defaultInterval)
        client = try PrometheusClient(baseURL: self.settings.prometheusURL)
        self.notifier = notifier
    }

    func start(registry: MetricsRegistry) throws {
        active = registry.gauge("molly_alert_active", help: "1 while a Prometheus alert is firing, 0 once an alert seen earlier has resolved.", labels: ["alertname", "severity"])
        notifications = registry.counter("molly_alert_notifications_total", help: "macOS notifications posted for firing alerts.", labels: ["alertname"])
        authorized = registry.gauge("molly_alert_notifications_authorized", help: "Notification permission: 1 granted, 0 denied or unavailable, -1 not asked yet.")
        authorized?.set(notifier.authorization)
    }

    func collect() throws {
        let data: Data
        do {
            data = try client.alertsJSON()
        } catch PrometheusClient.ClientError.unreachable {
            throw CollectorUnavailable(reason: "Prometheus not reachable at \(settings.prometheusURL)")
        }
        let outcome = tracker.update(
            current: try AlertsParser.parse(data), now: Date(), muted: settings.muted,
            minSeverity: settings.minSeverity, repeatAfter: settings.repeatAfter)
        for (name, entry) in outcome.seen {
            active?.set(entry.firing ? 1 : 0, labels: ["alertname": name, "severity": entry.severity.label])
        }
        AlertsStatus.firingCount = tracker.firingCount
        if settings.notify {
            for alert in outcome.toNotify {
                notifier.post(alert)
                notifications?.inc(labels: ["alertname": alert.name])
            }
        }
        authorized?.set(notifier.authorization)
    }
}
