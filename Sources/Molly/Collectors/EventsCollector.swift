import Foundation

/// Receives pushed events on `POST /event`. Claude Code hooks are the first
/// producer (`molly hook`); any script can post `{"source","event"}`.
/// Nothing from a payload is stored except the few label values below.
final class EventsCollector: Collector {
    enum Outcome: Equatable {
        case accepted
        case unauthorized
        case badRequest(String)
    }

    /// Claude Code hook payloads carry these keys; everything else is ignored.
    static let hookEventKey = "hook_event_name"
    static let toolNameKey = "tool_name"
    static let sessionKey = "session_id"
    static let cwdKey = "cwd"
    static let claudeSource = "claude_code"

    let name = "events"
    let interval: TimeInterval
    private let activeWindow: TimeInterval
    private let token: String
    private let projectsFilter: LabelFilter

    private var events: Counter?
    private var hookEvents: Counter?
    private var sessionsActive: Gauge?
    private var lastEvent: Gauge?

    private var sessions: [String: Date] = [:]
    private let lock = NSLock()
    private let now: () -> Date

    init(settings: CollectorSettings, now: @escaping () -> Date = Date.init) throws {
        interval = settings.interval(default: 60)
        activeWindow = settings.double("activeWindowSeconds", default: 300)
        token = settings.string("token", default: "")
        projectsFilter = try settings.filter("projects", defaults: LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 30))
        self.now = now
    }

    func start(registry: MetricsRegistry) throws {
        events = registry.counter("molly_events_total", help: "Events pushed to POST /event.", labels: ["source", "event"])
        hookEvents = registry.counter("molly_claude_hook_events_total", help: "Claude Code hook events received.", labels: ["event", "tool", "project"])
        sessionsActive = registry.gauge("molly_claude_hook_sessions_active", help: "Claude Code sessions seen by hooks within activeWindowSeconds and not ended.")
        lastEvent = registry.gauge("molly_claude_hook_last_event_timestamp_seconds", help: "Unix time of the last hook event.")
        sessionsActive?.set(0)
    }

    func collect() throws {
        refreshSessions()
    }

    /// Validates auth, then the payload, then records it. Order matters: a
    /// wrong token must not learn whether the body was valid.
    func handle(body: Data, authorization: String?) -> Outcome {
        if !token.isEmpty, authorization != "Bearer \(token)" {
            return .unauthorized
        }
        guard let json = try? JSONValue.parse(body), let object = json.objectValue else {
            return .badRequest("body must be a JSON object")
        }
        let isHook = object[EventsCollector.hookEventKey]?.stringValue != nil
        let source = object["source"]?.stringValue ?? (isHook ? EventsCollector.claudeSource : nil)
        guard let source, !source.isEmpty else { return .badRequest("source is required") }
        let event = object["event"]?.stringValue ?? object[EventsCollector.hookEventKey]?.stringValue ?? ""
        guard !event.isEmpty else { return .badRequest("event is required") }
        let value = object["value"]?.doubleValue ?? 1
        guard value >= 0 else { return .badRequest("value must be >= 0") }

        events?.add(value, labels: ["source": sanitize(source), "event": sanitize(event)])
        if source == EventsCollector.claudeSource {
            recordHook(event: event, object: object, value: value)
        }
        return .accepted
    }

    private func recordHook(event: String, object: [String: JSONValue], value: Double) {
        let labels = object["labels"]?.objectValue ?? [:]
        let tool = object[EventsCollector.toolNameKey]?.stringValue ?? labels[EventsCollector.toolNameKey]?.stringValue ?? ""
        let cwd = object[EventsCollector.cwdKey]?.stringValue ?? labels[EventsCollector.cwdKey]?.stringValue ?? ""
        let project = cwd.isEmpty ? LabelPolicy.other : projectsFilter.label(ProjectName.normalize(path: cwd))
        hookEvents?.add(value, labels: ["event": sanitize(event), "tool": sanitize(tool), "project": project])
        let at = now()
        lastEvent?.set(at.timeIntervalSince1970)
        if !cwd.isEmpty {
            ProjectTracker.shared.report(project: ProjectName.normalize(path: cwd), source: .claude, at: at)
        }
        if let session = object[EventsCollector.sessionKey]?.stringValue ?? labels[EventsCollector.sessionKey]?.stringValue,
           !session.isEmpty {
            lock.lock()
            if event == "SessionEnd" {
                sessions.removeValue(forKey: session)
            } else {
                sessions[session] = at
            }
            lock.unlock()
        }
        refreshSessions()
    }

    private func refreshSessions() {
        let cutoff = now().addingTimeInterval(-activeWindow)
        lock.lock()
        sessions = sessions.filter { $0.value >= cutoff }
        let count = sessions.count
        lock.unlock()
        sessionsActive?.set(count)
    }

    /// Label values come from untrusted payloads: keep them short and plain.
    private func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = trimmed.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == ":" || $0 == "/" }
        return String(plain.prefix(64))
    }
}
