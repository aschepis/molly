import Foundation

/// Pure helpers behind the menu bar items, kept free of AppKit so they can be
/// unit-tested.
enum MenuModel {
    /// True when at least one daily insights report exists.
    static func hasInsights(folder: URL) -> Bool {
        InsightsStore(folder: folder).latest(kind: .day) != nil
    }

    /// One line per collector for the Status submenu.
    static func statusLines(_ statuses: [CollectorManager.Status], now: Date = Date()) -> [String] {
        statuses.map { status in
            if status.unavailable {
                return "\(status.name) · unavailable"
            }
            if let success = status.lastSuccess {
                let age = Int(now.timeIntervalSince(success))
                let errors = status.errors > 0 ? " · \(status.errors) errors" : ""
                return "\(status.name) · ok \(age)s ago\(errors)"
            }
            if status.errors > 0 {
                return "\(status.name) · \(status.errors) errors"
            }
            return "\(status.name) · waiting"
        }
    }

    static func alertsLine(firing: Int) -> String {
        "\(firing) alert\(firing == 1 ? "" : "s") firing"
    }

    static func healthDashboardURL(grafana: String) -> String {
        grafana.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/d/molly-health"
    }

    /// Summary for the doctor notification.
    static func doctorSummary(_ checks: [DoctorCommand.Check]) -> String {
        let failing = checks.filter { !$0.ok }
        if failing.isEmpty { return "All \(checks.count) checks passed" }
        return "\(checks.count - failing.count) ok, \(failing.count) failing: " + failing.map { $0.name }.joined(separator: ", ")
    }

    /// Whether this process runs from an app bundle (required for SMAppService).
    static func isBundled(bundleURL: URL) -> Bool {
        bundleURL.pathExtension == "app"
    }
}
