import Foundation

/// Aggregates one day (or the day so far) and the current moment from
/// Prometheus into short text blocks. Everything here is PromQL over Molly's
/// own metrics; nothing reads the source databases.
struct DaySummary {
    let source: MetricsQuerying
    var now: () -> Date = { Date() }

    static func parseDay(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    func render(day: Date?) -> String {
        let start = Calendar.current.startOfDay(for: day ?? now())
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let end = min(nextDay, now())
        let seconds = max(60, Int(end.timeIntervalSince(start)))
        let window = "[\(seconds)s]"
        let isToday = Calendar.current.isDate(start, inSameDayAs: now())

        func scalar(_ q: String) -> Double? {
            (try? source.query(q, at: end))?.first?.value
        }
        func grouped(_ q: String, label: String, top: Int = 5) -> [(String, Double)] {
            let samples = (try? source.query(q, at: end)) ?? []
            return Array(samples
                .map { ($0.labels[label] ?? "?", $0.value) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .prefix(top))
        }
        func hours(_ seconds: Double?) -> String {
            guard let seconds else { return "n/a" }
            return String(format: "%.1fh", seconds / 3600)
        }
        func list(_ items: [(String, Double)], _ render: (Double) -> String) -> String {
            items.map { "\($0.0) \(render($0.1))" }.joined(separator: ", ")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var lines = ["Day: \(formatter.string(from: start)) (covering \(seconds / 3600)h \((seconds % 3600) / 60)m)"]

        let active = scalar("sum(increase(molly_active_seconds_total\(window)))")
        let idle = scalar("sum(increase(molly_idle_seconds_total\(window)))")
        lines.append("Active: \(hours(active)), idle: \(hours(idle))")
        if let flow = scalar("count_over_time((molly:flow_state:5m == 2)[\(seconds)s:5m]) * 5") {
            lines.append("Flow minutes: \(Int(flow))")
        }
        if let switches = scalar("sum(increase(molly_focus_switches_total\(window)))") {
            lines.append("App switches: \(Int(switches))")
        }
        let apps = grouped("sum by (app) (increase(molly_focus_seconds_total\(window)))", label: "app")
        if !apps.isEmpty { lines.append("Top apps: " + list(apps) { hours($0) }) }

        let repos = grouped("sum by (repo) (increase(molly_git_commits_total{author=\"me\"}\(window)))", label: "repo")
        if !repos.isEmpty {
            lines.append("Commits: " + list(repos) { String(Int($0)) })
        } else if let commits = scalar("sum(increase(molly_git_commits_total\(window)))") {
            lines.append("Commits: \(Int(commits))")
        }
        if isToday, let added = scalar("sum(molly_git_lines_added_today)"),
           let removed = scalar("sum(molly_git_lines_removed_today)") {
            lines.append("Lines today: +\(Int(added)) -\(Int(removed))")
        }
        if let cost = scalar("sum(increase(molly_claude_estimated_cost_usd_total\(window)))") {
            let tokens = grouped("sum by (kind) (increase(molly_claude_tokens_total\(window)))", label: "kind", top: 4)
            let calls = scalar("sum(increase(molly_claude_tool_calls_total\(window)))") ?? 0
            let tokenText = tokens.isEmpty ? "n/a" : list(tokens) { String(Int($0)) }
            lines.append(String(format: "Claude: $%.2f estimated, %d tool calls, tokens %@", cost, Int(calls), tokenText))
        }
        let messages = grouped("sum by (direction) (increase(molly_messages_total\(window)))", label: "direction", top: 2)
        if !messages.isEmpty { lines.append("Messages: " + list(messages) { String(Int($0)) }) }
        let visits = grouped("sum by (browser) (increase(molly_browser_visits_total\(window)))", label: "browser")
        if !visits.isEmpty { lines.append("Browser visits: " + list(visits) { String(Int($0)) }) }
        if let meetingSeconds = scalar("sum(increase(molly_meeting_seconds_total\(window)))") {
            let count = scalar("sum(increase(molly_meetings_total\(window)))") ?? 0
            lines.append("Meetings: \(Int(count)) totalling \(Int(meetingSeconds / 60)) min")
        }
        let builds = grouped("sum by (tool) (increase(molly_builds_total\(window)))", label: "tool")
        if !builds.isEmpty { lines.append("Builds: " + list(builds) { String(Int($0)) }) }
        if let commands = scalar("sum(increase(molly_shell_commands_total\(window)))") {
            lines.append("Shell commands: \(Int(commands))")
        }
        if let sleeps = scalar("sum(increase(molly_power_sleep_events_total{kind=\"sleep\"}\(window)))") {
            lines.append("Sleeps: \(Int(sleeps))")
        }
        if let cpu = scalar("avg_over_time(molly_cpu_utilization_ratio\(window))") {
            let pressure = scalar("max_over_time(molly_memory_pressure_level\(window))") ?? 1
            lines.append(String(format: "CPU avg %.0f%%, worst memory pressure level %d", cpu * 100, Int(pressure)))
        }
        return lines.joined(separator: "\n")
    }

    /// What is happening right now, from instant queries.
    func currentContext() -> String {
        func samples(_ q: String) -> [PrometheusClient.Sample] { (try? source.query(q, at: nil)) ?? [] }
        func value(_ q: String) -> Double? { samples(q).first?.value }
        func flag(_ q: String) -> String? {
            guard let v = value(q) else { return nil }
            return v >= 1 ? "yes" : "no"
        }

        var lines: [String] = []
        if let app = samples("molly_focus_app == 1").first {
            lines.append("Focused app: \(app.labels["app"] ?? "?")")
        }
        if let idle = value("molly_idle_seconds") {
            lines.append("Idle for: \(Int(idle))s (user active: \(flag("molly_user_active") ?? "n/a"))")
        }
        if let locked = flag("molly_screen_locked") { lines.append("Screen locked: \(locked)") }
        if let meeting = flag("molly_meeting_active") { lines.append("In a meeting (mic or camera in use): \(meeting)") }
        if let inEvent = flag("molly_calendar_in_event") {
            var text = "Calendar event now: \(inEvent)"
            if let next = value("molly_calendar_next_event_start_seconds"), next >= 0 {
                text += ", next starts in \(Int(next / 60)) min"
            }
            lines.append(text)
        }
        let projects = samples("molly_project_active == 1").compactMap { $0.labels["project"] }
        if !projects.isEmpty { lines.append("Active projects: \(projects.sorted().joined(separator: ", "))") }
        if let sessions = value("molly_claude_sessions_active") { lines.append("Claude Code sessions active: \(Int(sessions))") }
        if let building = flag("molly_build_active") { lines.append("Build running: \(building)") }
        if let flow = value("molly:flow_state:5m") {
            let names = ["break", "shallow", "flow"]
            lines.append("Flow state (last 5m): \(names[min(2, max(0, Int(flow)))])")
        }
        if let battery = value("molly_battery_percent") {
            lines.append("Battery: \(Int(battery))% (on AC: \(flag("molly_battery_on_ac") ?? "n/a"))")
        }
        if let cpu = value("molly_cpu_utilization_ratio") {
            let pressure = Int(value("molly_memory_pressure_level") ?? 1)
            lines.append(String(format: "CPU: %.0f%%, memory pressure level %d", cpu * 100, pressure))
        }
        if let docked = flag("molly_docked") { lines.append("Docked: \(docked)") }
        if lines.isEmpty { return "No current data (is Molly running and scraped by Prometheus?)" }
        return lines.joined(separator: "\n")
    }
}
