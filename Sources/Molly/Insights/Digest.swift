import Foundation

/// One day (or week) of Molly's history, reduced to numbers. Everything comes
/// from Prometheus, so label policies have already been applied; the digest
/// is the only thing a narrative backend ever sees.
struct InsightsDigest: Codable, Equatable {
    enum Kind: String, Codable { case day, week }

    var kind: Kind
    /// The day, or the Monday of the week, as YYYY-MM-DD in local time.
    var date: String
    var user: String
    var host: String
    var from: Date
    var to: Date
    var generatedAt: Date
    /// Single numbers keyed by `DigestQuery.key`.
    var scalars: [String: Double] = [:]
    /// Label-value breakdowns keyed by `DigestQuery.key`.
    var breakdowns: [String: [String: Double]] = [:]
    /// Query keys that returned no series (collector off or no data).
    var missing: [String] = []
    /// Query keys that failed, with the error.
    var errors: [String: String] = [:]

    var isEmpty: Bool { scalars.isEmpty && breakdowns.isEmpty }
}

/// One PromQL query in the digest. `{s}` is the user/host selector and `{r}`
/// the window as a Prometheus duration; both are substituted at query time.
struct DigestQuery: Equatable {
    enum Shape: Equatable {
        case scalar
        case breakdown(label: String)
        /// The query yields an index into `labels`; only the label is reported.
        case bucket(labels: [String])
    }

    let key: String
    let title: String
    let unit: String
    let shape: Shape
    let promql: String

    static func scalar(_ key: String, _ title: String, _ unit: String, _ promql: String) -> DigestQuery {
        DigestQuery(key: key, title: title, unit: unit, shape: .scalar, promql: promql)
    }

    static func bucket(_ key: String, _ title: String, labels: [String], _ promql: String) -> DigestQuery {
        DigestQuery(key: key, title: title, unit: "", shape: .bucket(labels: labels), promql: promql)
    }

    static func breakdown(_ key: String, _ title: String, _ unit: String, by label: String, _ promql: String) -> DigestQuery {
        DigestQuery(key: key, title: title, unit: unit, shape: .breakdown(label: label), promql: promql)
    }

    /// `{s}` becomes the full selector; `{s,x="y"}` keeps the extra matchers.
    func rendered(selector: String, range: String) -> String {
        promql.replacingOccurrences(of: "{s}", with: "{\(selector)}")
            .replacingOccurrences(of: "{s,", with: "{\(selector),")
            .replacingOccurrences(of: "{r}", with: range)
    }
}

enum DigestQueries {
    /// Order matters: this is the order sections appear in the Markdown.
    static let all: [DigestQuery] = [
        .scalar("active_hours", "Active hours", "h", "sum(increase(molly_active_seconds_total{s}[{r}])) / 3600"),
        .scalar("idle_hours", "Idle hours", "h", "sum(increase(molly_idle_seconds_total{s}[{r}])) / 3600"),
        .scalar("awake_hours", "Machine awake hours", "h", "max(max_over_time(molly_power_awake_seconds_today{s}[{r}])) / 3600"),
        .scalar("sleep_hours", "Machine asleep hours", "h", "max(max_over_time(molly_power_sleep_seconds_today{s}[{r}])) / 3600"),
        .scalar("flow_minutes", "Flow minutes", "min", "sum(count_over_time((molly:flow_state:5m{s} == 2)[{r}:5m])) * 5"),
        .scalar("focus_switches", "Focus switches", "", "sum(increase(molly_focus_switches_total{s}[{r}]))"),
        .scalar("screen_locks", "Screen locks", "", "sum(increase(molly_screen_lock_events_total{s}[{r}]))"),
        .scalar("meeting_minutes", "Meeting minutes", "min", "sum(increase(molly_meeting_seconds_total{s}[{r}])) / 60"),
        .scalar("calendar_event_hours", "Calendar event hours", "h", "max(max_over_time(molly_calendar_event_seconds_today{s}[{r}])) / 3600"),
        .scalar("gaming_seconds", "Gaming time", "s", "sum(increase(molly_gaming_platform_seconds_total{s}[{r}]))"),
        .scalar("gaming_sessions", "Gaming sessions", "", "sum(increase(molly_gaming_sessions_total{s}[{r}]))"),
        .scalar("late_night_gaming_seconds", "Gaming between 23:00 and 05:00", "s",
                "sum(sum_over_time((molly:gaming_seconds:increase1h{s} and on () ((hour() + scalar(molly:local_utc_offset_hours) + 24) % 24 <= 5))[{r}:1h]))"),
        .breakdown("top_platform", "Top gaming platform", "s", by: "platform", "topk(1, sum by (platform) (increase(molly_gaming_platform_seconds_total{s}[{r}])))"),
        .breakdown("focus_top_apps", "Top apps by focus", "min", by: "app", "topk(8, sum by (app) (increase(molly_focus_seconds_total{s}[{r}])) / 60)"),
        .breakdown("knowledge_top_apps", "Top apps by system usage", "min", by: "app", "topk(8, sum by (app) (increase(molly_knowledge_app_usage_seconds_total{s}[{r}])) / 60)"),
        .breakdown("projects_active", "Projects touched", "", by: "project", "max by (project) (max_over_time(molly_project_active{s}[{r}]))"),
        .breakdown("commits_by_repo", "Commits by repo (mine)", "", by: "repo", "sum by (repo) (increase(molly_git_commits_total{s,author=\"me\"}[{r}]))"),
        .scalar("lines_added", "Lines added", "", "sum(max_over_time(molly_git_lines_added_today{s}[{r}]))"),
        .scalar("lines_removed", "Lines removed", "", "sum(max_over_time(molly_git_lines_removed_today{s}[{r}]))"),
        .scalar("builds", "Builds", "", "sum(increase(molly_builds_total{s}[{r}]))"),
        .scalar("build_minutes", "Build minutes", "min", "sum(increase(molly_build_seconds_total{s}[{r}])) / 60"),
        .scalar("claude_sessions", "Claude Code sessions started", "", "sum(increase(molly_claude_sessions_total{s}[{r}]))"),
        .scalar("claude_prompts", "Claude Code prompts", "", "sum(increase(molly_claude_prompts_total{s}[{r}]))"),
        .scalar("claude_messages", "Claude Code messages", "", "sum(increase(molly_claude_messages_total{s}[{r}]))"),
        .scalar("claude_tool_calls", "Claude Code tool calls", "", "sum(increase(molly_claude_tool_calls_total{s}[{r}]))"),
        .scalar("claude_hook_events", "Claude Code hook events", "", "sum(increase(molly_claude_hook_events_total{s}[{r}]))"),
        .breakdown("claude_tools", "Top Claude Code tools", "", by: "tool", "topk(8, sum by (tool) (increase(molly_claude_tool_calls_total{s}[{r}])))"),
        .breakdown("claude_tokens_by_kind", "Claude tokens by kind", "", by: "kind", "sum by (kind) (increase(molly_claude_tokens_total{s}[{r}]))"),
        .breakdown("claude_cost_by_model", "Claude estimated cost by model", "USD", by: "model", "sum by (model) (increase(molly_claude_estimated_cost_usd_total{s}[{r}]))"),
        .scalar("claude_cost_usd", "Claude estimated cost", "USD", "sum(increase(molly_claude_estimated_cost_usd_total{s}[{r}]))"),
        .scalar("cursor_ai_events", "Cursor AI code events", "", "sum(increase(molly_cursor_ai_code_events_total{s}[{r}]))"),
        .breakdown("shell_commands_by_shell", "Shell commands", "", by: "shell", "sum by (shell) (increase(molly_shell_commands_total{s}[{r}]))"),
        .scalar("messages_sent", "Messages sent", "", "sum(increase(molly_messages_total{s,direction=\"sent\"}[{r}]))"),
        .scalar("messages_received", "Messages received", "", "sum(increase(molly_messages_total{s,direction=\"received\"}[{r}]))"),
        .breakdown("messages_sent_by_service", "Messages sent by service", "", by: "service", "sum by (service) (increase(molly_messages_total{s,direction=\"sent\"}[{r}]))"),
        .scalar("mail_received", "Mail received", "", "sum(increase(molly_mail_messages_total{s,direction=\"received\"}[{r}]))"),
        .scalar("notifications", "Notifications", "", "sum(increase(molly_knowledge_notifications_total{s}[{r}]))"),
        .breakdown("notifications_by_app", "Notifications by app", "", by: "app", "topk(8, sum by (app) (increase(molly_knowledge_notifications_total{s}[{r}])))"),
        .scalar("browser_visits", "Browser visits", "", "sum(increase(molly_browser_visits_total{s}[{r}]))"),
        .scalar("browser_distinct_domains", "Distinct domains visited", "", "sum(max_over_time(molly_browser_distinct_domains_today{s}[{r}]))"),
        .breakdown("browser_visits_by_browser", "Visits by browser", "", by: "browser", "sum by (browser) (increase(molly_browser_visits_total{s}[{r}]))"),
        .breakdown("browser_top_domains", "Top domains (only if the domains policy is on)", "", by: "domain", "topk(10, sum by (domain) (increase(molly_browser_domain_visits_total{s}[{r}])))"),
        .scalar("notes_created", "Notes created", "", "sum(increase(molly_notes_created_total{s}[{r}]))"),
        .scalar("notes_modified", "Notes modified", "", "sum(increase(molly_notes_modified_total{s}[{r}]))"),
        .scalar("clipboard_changes", "Clipboard copies", "", "sum(increase(molly_clipboard_changes_total{s}[{r}]))"),
        .scalar("input_keys_per_minute_avg", "Keys per minute (avg, if input is on)", "", "avg(avg_over_time(molly_input_keys_per_minute{s}[{r}]))"),
        .scalar("docked_ratio", "Share of time docked", "ratio", "avg(avg_over_time(molly_docked{s}[{r}]))"),
        .scalar("cpu_avg", "CPU utilization (avg)", "ratio", "avg(avg_over_time(molly_cpu_utilization_ratio{s}[{r}]))"),
        .scalar("cpu_max", "CPU utilization (max)", "ratio", "max(max_over_time(molly_cpu_utilization_ratio{s}[{r}]))"),
        .scalar("memory_pressure_max", "Memory pressure level (max; 1 ok, 2 warn, 4 critical)", "", "max(max_over_time(molly_memory_pressure_level{s}[{r}]))"),
        .scalar("battery_min_percent", "Battery minimum", "%", "min(min_over_time(molly_battery_percent{s}[{r}]))"),
        .scalar("molly_collector_errors", "Molly collector errors", "", "sum(increase(molly_collector_errors_total{s}[{r}]))"),
    ]

    /// Thresholds for the coarse health buckets; nothing finer reaches the
    /// model unless `collectors.health.detailedInsights` is true.
    static let shortSleepMinutes = 360
    static let longSleepMinutes = 540
    static let lowSteps = 5000
    static let highSteps = 12000
    static let restingHeartRateShiftBpm = 2
    static let restingBaselineRange = "28d"

    static let healthCoarse: [DigestQuery] = {
        let sleep = "max(max_over_time(molly_health_sleep_minutes_last_night{s}[{r}]))"
        let steps = "max(max_over_time(molly_health_today{s,type=\"steps\"}[{r}]))"
        let recent = "avg(avg_over_time(molly_health_today{s,type=\"resting_heart_rate_bpm\"}[{r}]))"
        let baseline = "avg(avg_over_time(molly_health_today{s,type=\"resting_heart_rate_bpm\"}[\(restingBaselineRange)]))"
        return [
            .bucket("health_sleep", "Sleep last night", labels: ["short", "ok", "long"],
                    "(\(sleep) >= bool \(shortSleepMinutes)) + (\(sleep) > bool \(longSleepMinutes))"),
            .bucket("health_movement", "Movement", labels: ["low", "ok", "high"],
                    "(\(steps) >= bool \(lowSteps)) + (\(steps) > bool \(highSteps))"),
            .bucket("health_rest", "Resting heart rate vs your 4-week norm", labels: ["down", "flat", "up"],
                    "(\(recent) > bool (\(baseline) + \(restingHeartRateShiftBpm))) + 1 - (\(recent) < bool (\(baseline) - \(restingHeartRateShiftBpm)))"),
        ]
    }()

    static let healthDetailed: [DigestQuery] = [
        .scalar("health_sleep_minutes", "Sleep last night", "min", "max(max_over_time(molly_health_sleep_minutes_last_night{s}[{r}]))"),
        .scalar("health_steps", "Steps (best day)", "", "max(max_over_time(molly_health_today{s,type=\"steps\"}[{r}]))"),
        .scalar("health_exercise_minutes", "Exercise minutes (best day)", "min", "max(max_over_time(molly_health_today{s,type=\"exercise_minutes\"}[{r}]))"),
        .scalar("health_stand_hours", "Stand hours (best day)", "h", "max(max_over_time(molly_health_today{s,type=\"stand_hours\"}[{r}]))"),
        .scalar("health_resting_hr", "Resting heart rate (avg)", "bpm", "avg(avg_over_time(molly_health_today{s,type=\"resting_heart_rate_bpm\"}[{r}]))"),
        .scalar("health_hrv", "HRV (avg)", "ms", "avg(avg_over_time(molly_health_today{s,type=\"hrv_ms\"}[{r}]))"),
    ]

    /// Health queries to add to the digest: none unless the collector is on.
    static func health(config: Config) -> [DigestQuery] {
        let settings = config.collector("health")
        guard settings.enabled(default: false) else { return [] }
        return settings.bool("detailedInsights", default: false) ? healthCoarse + healthDetailed : healthCoarse
    }

    static func selector(user: String, host: String) -> String {
        "user=\"\(user)\",host=\"\(host)\""
    }

    static func range(from: Date, to: Date) -> String {
        "\(max(60, Int(to.timeIntervalSince(from))))s"
    }
}

enum DigestBuilder {
    /// The local-time window a digest covers. A day ends at the next midnight
    /// or now, whichever is earlier; a week starts on its Monday.
    static func window(kind: InsightsDigest.Kind, containing date: Date, now: Date = Date(),
                       calendar: Calendar = .current) -> (from: Date, to: Date, label: String) {
        var start: Date
        var end: Date
        switch kind {
        case .day:
            start = calendar.startOfDay(for: date)
            end = calendar.date(byAdding: .day, value: 1, to: start)!
        case .week:
            let weekday = calendar.component(.weekday, from: date)
            // Calendar weekdays are 1 = Sunday; shift to a Monday-based week.
            let daysSinceMonday = (weekday + 5) % 7
            start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysSinceMonday, to: date)!)
            end = calendar.date(byAdding: .day, value: 7, to: start)!
        }
        if end > now { end = now }
        return (start, end, dateLabel(start, calendar: calendar))
    }

    static func dateLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func parseDate(_ text: String, calendar: Calendar = .current) -> Date? {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f.date(from: text)
    }

    /// Runs every digest query at the end of the window and collects results.
    static func build(client: PrometheusClient, kind: InsightsDigest.Kind, date: Date, user: String, host: String,
                      now: Date = Date(), queries: [DigestQuery] = DigestQueries.all) -> InsightsDigest {
        let w = window(kind: kind, containing: date, now: now)
        var digest = InsightsDigest(kind: kind, date: w.label, user: user, host: host, from: w.from, to: w.to, generatedAt: now)
        let selector = DigestQueries.selector(user: user, host: host)
        let range = DigestQueries.range(from: w.from, to: w.to)
        for query in queries {
            let promql = query.rendered(selector: selector, range: range)
            // increase() extrapolates, so plain counts come back fractional.
            let precision: Double = query.unit.isEmpty ? 1 : 100
            do {
                let samples = try client.query(promql, at: w.to)
                switch query.shape {
                case .scalar:
                    guard let value = samples.first?.value, value.isFinite else {
                        digest.missing.append(query.key)
                        continue
                    }
                    digest.scalars[query.key] = round(value * precision) / precision
                case .bucket(let labels):
                    guard let value = samples.first?.value, value.isFinite, labels.indices.contains(Int(value)) else {
                        digest.missing.append(query.key)
                        continue
                    }
                    digest.scalars[query.key] = value.rounded()
                case .breakdown(let label):
                    var values: [String: Double] = [:]
                    for sample in samples where sample.value.isFinite && sample.value > 0 {
                        values[sample.labels[label] ?? "", default: 0] += round(sample.value * precision) / precision
                    }
                    if values.isEmpty {
                        digest.missing.append(query.key)
                    } else {
                        digest.breakdowns[query.key] = values
                    }
                }
            } catch {
                digest.errors[query.key] = String(describing: error)
            }
        }
        return digest
    }
}

extension InsightsDigest {
    /// Compact Markdown: one line per number, grouped in query order.
    func markdown(queries: [DigestQuery] = DigestQueries.all + DigestQueries.healthCoarse + DigestQueries.healthDetailed) -> String {
        var out = "## Digest: \(kind == .day ? "day" : "week of") \(date) (\(user)@\(host))\n"
        out += "Window: \(Self.timestamp(from)) to \(Self.timestamp(to))\n\n"
        for query in queries {
            switch query.shape {
            case .scalar:
                guard let value = scalars[query.key] else { continue }
                out += "- \(query.title): \(Self.number(value))\(Self.unitSuffix(query.unit))\n"
            case .bucket(let labels):
                guard let value = scalars[query.key], labels.indices.contains(Int(value)) else { continue }
                out += "- \(query.title): \(labels[Int(value)])\n"
            case .breakdown:
                guard let values = breakdowns[query.key], !values.isEmpty else { continue }
                let ranked = values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                let parts = ranked.map { "\($0.key.isEmpty ? "(none)" : $0.key) \(Self.number($0.value))\(Self.unitSuffix(query.unit))" }
                out += "- \(query.title): " + parts.joined(separator: ", ") + "\n"
            }
        }
        if !missing.isEmpty {
            out += "\nNo data for: " + missing.sorted().joined(separator: ", ") + "\n"
        }
        if !errors.isEmpty {
            out += "\nQuery errors: " + errors.keys.sorted().joined(separator: ", ") + "\n"
        }
        return out
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func number(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e12 { return String(Int64(value)) }
        return String(format: "%.2f", value)
    }

    static func unitSuffix(_ unit: String) -> String {
        switch unit {
        case "": return ""
        case "%": return "%"
        case "ratio": return " (0-1)"
        default: return " \(unit)"
        }
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
