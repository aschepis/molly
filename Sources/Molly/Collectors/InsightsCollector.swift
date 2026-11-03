import Foundation

/// Generates the daily (and weekly) insights report inside the daemon once
/// the configured hour has passed. Off by default: it sends a digest of
/// aggregate numbers to Claude, which costs money or subscription budget.
final class InsightsCollector: Collector {
    let name = "insights"
    let interval: TimeInterval
    let settings: InsightsSettings
    let generator: InsightsGenerator
    private let calendar = Calendar.current

    init(settings: CollectorSettings, config: Config) throws {
        let insights = InsightsSettings(settings: settings, links: config.links)
        self.settings = insights
        interval = insights.interval
        let client = try PrometheusClient(baseURL: insights.prometheusURL)
        generator = InsightsGenerator(
            client: client, store: InsightsStore(),
            user: config.constLabels["user"] ?? Config.defaultUser,
            host: config.constLabels["host"] ?? Config.defaultHost,
            makeCompleter: { try NarrativeBackend.make(choice: insights.backend, apiKey: insights.apiKey, model: insights.model) })
    }

    func start(registry: MetricsRegistry) throws {
        generator.register(on: registry)
    }

    func collect() throws {
        let now = Date()
        let decision = InsightsSchedule.due(now: now, dailyAtHour: settings.dailyAtHour, weekly: settings.weekly,
                                            exists: { generator.store.exists(kind: $0, date: $1) }, calendar: calendar)
        if decision.day {
            let result = try generator.generate(kind: .day, date: now, now: now)
            Log.info("insights: wrote daily report \(result.date) via \(result.backend)")
        }
        if decision.week, let lastWeek = calendar.date(byAdding: .day, value: -7, to: now) {
            let result = try generator.generate(kind: .week, date: lastWeek, now: now)
            Log.info("insights: wrote weekly report \(result.date) via \(result.backend)")
        }
    }
}
