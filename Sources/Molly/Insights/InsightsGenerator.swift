import Foundation

/// The `insights` config section.
struct InsightsSettings {
    var enabled: Bool
    var interval: TimeInterval
    var dailyAtHour: Int
    var weekly: Bool
    var model: String
    var apiKey: String?
    var backend: NarrativeBackend.Choice
    var prometheusURL: String

    init(settings: CollectorSettings, links: Config.Links) {
        enabled = settings.enabled(default: false)
        interval = settings.interval(default: 300)
        dailyAtHour = min(23, max(0, settings.int("dailyAtHour", default: 21)))
        weekly = settings.bool("weekly", default: true)
        model = settings.string("model", default: ClaudeAPICompleter.defaultModel)
        let key = settings.string("apiKey", default: "")
        apiKey = key.isEmpty ? nil : key
        backend = NarrativeBackend.Choice(rawValue: settings.string("backend", default: "auto")) ?? .auto
        prometheusURL = settings.string("prometheusURL", default: links.prometheus)
    }
}

/// Where reports live and how they are named: `<data>/insights/<date>.md`
/// for a day, `<date>-week.md` for the week starting on that Monday.
struct InsightsStore {
    let folder: URL

    init(folder: URL = Paths.dataFolder.appendingPathComponent("insights")) {
        self.folder = folder
    }

    func url(kind: InsightsDigest.Kind, date: String) -> URL {
        folder.appendingPathComponent(kind == .day ? "\(date).md" : "\(date)-week.md")
    }

    func exists(kind: InsightsDigest.Kind, date: String) -> Bool {
        FileManager.default.fileExists(atPath: url(kind: kind, date: date).path)
    }

    func read(kind: InsightsDigest.Kind, date: String) -> String? {
        try? String(contentsOf: url(kind: kind, date: date), encoding: .utf8)
    }

    func write(_ text: String, kind: InsightsDigest.Kind, date: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: url(kind: kind, date: date), atomically: true, encoding: .utf8)
    }

    /// The newest daily report by file name (dates sort lexically).
    func latest(kind: InsightsDigest.Kind = .day) -> (date: String, text: String)? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let suffix = kind == .day ? ".md" : "-week.md"
        let dates = names.compactMap { name -> String? in
            guard name.hasSuffix(suffix) else { return nil }
            let date = String(name.dropLast(suffix.count))
            guard DigestBuilder.parseDate(date) != nil else { return nil }
            if kind == .day, name.hasSuffix("-week.md") { return nil }
            return date
        }
        guard let date = dates.max(), let text = read(kind: kind, date: date) else { return nil }
        return (date, text)
    }
}

enum InsightsPrompt {
    static let system = """
    You are reviewing one period of a software developer's machine usage, measured by Molly, \
    a local observability tool. You only see aggregate numbers that the user chose to record. \
    Be concrete, warm and brief. Never invent numbers; every claim must point at a figure in \
    the digest. Where data is missing, say nothing about it. A collector whose source is absent \
    on this machine is expected, not a malfunction: never recommend fixing data collection \
    because of it. Claude cost is a list-price estimate; when the digest says the pricing mode \
    is subscription, call it a list-price equivalent and never recommend reducing spend.
    """

    static func user(digest: InsightsDigest) -> String {
        let period = digest.kind == .day ? "day" : "week"
        return """
        Write a Markdown report about this \(period) with exactly these sections:

        ## Narrative
        120 to 200 words describing how the \(period) went: when the work happened, what it \
        was spent on, how focused it was, and what stood out.

        ## Recommendations
        Three bullet points. Each must name a specific number from the digest and say what to \
        change or keep doing because of it.

        ## Pattern to watch
        One sentence naming a trend or risk suggested by the numbers.

        Use plain language, no headings other than the three above, no preamble.

        \(digest.markdown())
        """
    }
}

/// Builds the digest, asks a completer for prose, writes and caches the
/// report, and keeps the insights metrics current.
final class InsightsGenerator {
    struct Result {
        let date: String
        let kind: InsightsDigest.Kind
        let markdown: String
        let digest: InsightsDigest
        let cached: Bool
        let backend: String
    }

    let store: InsightsStore
    let user: String
    let host: String
    private let client: PrometheusClient
    private let extraQueries: [DigestQuery]
    private let makeCompleter: () throws -> NarrativeCompleter
    private var lastGenerated: Gauge?
    private var generations: Counter?

    init(client: PrometheusClient, store: InsightsStore, user: String, host: String,
         extraQueries: [DigestQuery] = [], makeCompleter: @escaping () throws -> NarrativeCompleter) {
        self.client = client
        self.store = store
        self.user = user
        self.host = host
        self.extraQueries = extraQueries
        self.makeCompleter = makeCompleter
    }

    func register(on registry: MetricsRegistry) {
        lastGenerated = registry.gauge("molly_insights_last_generated_timestamp_seconds",
                                       help: "Unix time of the last insights report written.")
        generations = registry.counter("molly_insights_generations_total",
                                       help: "Insights report generation attempts.", labels: ["kind", "status"])
        for kind in ["day", "week"] {
            for status in ["ok", "error", "cached"] {
                generations?.touch(labels: ["kind": kind, "status": status])
            }
        }
    }

    func digest(kind: InsightsDigest.Kind, date: Date, now: Date = Date()) -> InsightsDigest {
        DigestBuilder.build(client: client, kind: kind, date: date, user: user, host: host, now: now,
                            queries: DigestQueries.all + extraQueries)
    }

    /// Generates (or returns the cached) report for the period containing `date`.
    func generate(kind: InsightsDigest.Kind, date: Date, force: Bool = false, now: Date = Date()) throws -> Result {
        let window = DigestBuilder.window(kind: kind, containing: date, now: now)
        if !force, let cached = store.read(kind: kind, date: window.label) {
            generations?.inc(labels: ["kind": kind.rawValue, "status": "cached"])
            let digest = InsightsDigest(kind: kind, date: window.label, user: user, host: host,
                                        from: window.from, to: window.to, generatedAt: now)
            return Result(date: window.label, kind: kind, markdown: cached, digest: digest, cached: true, backend: "cache")
        }
        let digest = self.digest(kind: kind, date: date, now: now)
        guard !digest.isEmpty else {
            generations?.inc(labels: ["kind": kind.rawValue, "status": "error"])
            throw CollectorUnavailable(reason: "no data in Prometheus for \(window.label); is the stack running?")
        }
        let completer: NarrativeCompleter
        let narrative: String
        do {
            completer = try makeCompleter()
            narrative = try completer.complete(system: InsightsPrompt.system, prompt: InsightsPrompt.user(digest: digest))
        } catch {
            generations?.inc(labels: ["kind": kind.rawValue, "status": "error"])
            throw error
        }
        let markdown = Self.render(narrative: narrative, digest: digest, backend: completer.name)
        try store.write(markdown, kind: kind, date: window.label)
        generations?.inc(labels: ["kind": kind.rawValue, "status": "ok"])
        lastGenerated?.set(now.timeIntervalSince1970)
        return Result(date: window.label, kind: kind, markdown: markdown, digest: digest, cached: false, backend: completer.name)
    }

    static func render(narrative: String, digest: InsightsDigest, backend: String) -> String {
        let title = digest.kind == .day ? "Molly insights for \(digest.date)" : "Molly insights for the week of \(digest.date)"
        return """
        # \(title)

        \(narrative.trimmingCharacters(in: .whitespacesAndNewlines))

        <details>
        <summary>Digest (generated \(InsightsDigest.timestamp(digest.generatedAt)) via \(backend))</summary>

        \(digest.markdown())
        </details>

        """
    }
}

/// When the daemon should generate reports. Pure so it can be tested.
enum InsightsSchedule {
    struct Decision: Equatable {
        var day: Bool
        var week: Bool
    }

    /// The daily report is due once local time passes `dailyAtHour` and the
    /// file is missing. The weekly report for the previous week is due on
    /// Mondays (any hour) when `weekly` is on and its file is missing.
    static func due(now: Date, dailyAtHour: Int, weekly: Bool, exists: (InsightsDigest.Kind, String) -> Bool,
                    calendar: Calendar = .current) -> Decision {
        let hour = calendar.component(.hour, from: now)
        let today = DigestBuilder.dateLabel(now, calendar: calendar)
        let day = hour >= dailyAtHour && !exists(.day, today)
        var week = false
        if weekly, calendar.component(.weekday, from: now) == 2,
           let lastWeek = calendar.date(byAdding: .day, value: -7, to: now) {
            let label = DigestBuilder.window(kind: .week, containing: lastWeek, now: now, calendar: calendar).label
            week = !exists(.week, label)
        }
        return Decision(day: day, week: week)
    }
}
