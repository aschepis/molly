import Foundation

/// Which projects are being worked on, derived from what the git and
/// claude_code collectors report to the shared ProjectTracker. Shell working
/// directories only count under `roots` or inside a git repository.
final class ProjectsCollector: Collector {
    static let projectsDefaults = LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 30)
    let name = "projects"
    let interval: TimeInterval

    private let activeWindow: TimeInterval
    private let retention: TimeInterval
    private let filter: LabelFilter
    private let tracker: ProjectTracker
    private let roots: [String]

    private var active: Gauge?
    private var lastActivity: Gauge?
    private var activeCount: Gauge?

    init(settings: CollectorSettings, tracker: ProjectTracker = .shared) throws {
        interval = settings.interval(default: 60)
        activeWindow = settings.double("activeWindowSeconds", default: 1800)
        retention = settings.double("retentionSeconds", default: 86400)
        filter = try settings.filter("projects", defaults: ProjectsCollector.projectsDefaults)
        roots = ProjectResolver.roots(from: settings)
        self.tracker = tracker
    }

    func start(registry: MetricsRegistry) throws {
        ProjectResolver.shared.setRoots(roots)
        active = registry.gauge("molly_project_active", help: "1 for projects with activity within activeWindowSeconds.", labels: ["project"])
        lastActivity = registry.gauge("molly_project_last_activity_timestamp_seconds", help: "Unix time of the latest activity per project and source.", labels: ["project", "source"])
        activeCount = registry.gauge("molly_projects_active", help: "Projects with activity within activeWindowSeconds.")
    }

    func collect() throws {
        let now = Date()
        let snapshot = tracker.snapshot()

        var latest: [String: Date] = [:]
        for sources in snapshot.values {
            for (project, date) in sources where now.timeIntervalSince(date) <= retention {
                latest[project] = max(latest[project] ?? .distantPast, date)
            }
        }
        activeCount?.set(latest.values.filter { now.timeIntervalSince($0) <= activeWindow }.count)

        var shown = latest.sorted { $0.value > $1.value }.map(\.key)
        if filter.enabled, filter.maxCardinality > 0 { shown = Array(shown.prefix(filter.maxCardinality)) }
        let shownSet = Set(shown)

        var activeLabels: [String: Double] = [:]
        for project in shown where now.timeIntervalSince(latest[project] ?? .distantPast) <= activeWindow {
            activeLabels[filter.label(project)] = 1
        }
        active?.reset()
        for label in activeLabels.keys { active?.set(1, labels: ["project": label]) }

        struct Series: Hashable {
            let project: String
            let source: String
        }
        var times: [Series: Double] = [:]
        for (source, projects) in snapshot {
            for (project, date) in projects where shownSet.contains(project) {
                let key = Series(project: filter.label(project), source: source.rawValue)
                times[key] = max(times[key] ?? 0, date.timeIntervalSince1970)
            }
        }
        lastActivity?.reset()
        for (key, value) in times {
            lastActivity?.set(value, labels: ["project": key.project, "source": key.source])
        }
    }
}
