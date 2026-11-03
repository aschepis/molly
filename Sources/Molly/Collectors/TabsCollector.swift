import AppKit
import Foundation

// MARK: - Pure logic (unit-tested)

struct BrowserApp: Equatable {
    /// The `browser` label value.
    let label: String
    let bundleID: String
}

struct TabCounts: Equatable {
    let windows: Int
    let tabs: Int
}

enum TabsParse {
    /// Safari and the Chromium family share the window/tab dictionary shape.
    static let browsers: [BrowserApp] = [
        BrowserApp(label: "safari", bundleID: "com.apple.Safari"),
        BrowserApp(label: "chrome", bundleID: "com.google.Chrome"),
        BrowserApp(label: "brave", bundleID: "com.brave.Browser"),
        BrowserApp(label: "arc", bundleID: "company.thebrowser.Browser"),
        BrowserApp(label: "edge", bundleID: "com.microsoft.edgemac"),
        BrowserApp(label: "vivaldi", bundleID: "com.vivaldi.Vivaldi"),
    ]

    /// Asks only for counts; titles and URLs are never requested. Addressing the
    /// app by bundle id keeps the script from resolving a name to a launch.
    static func script(bundleID: String) -> String {
        "tell application id \"\(bundleID)\" to return (count of windows) & (count of tabs of windows)"
    }

    /// osascript flattens the list: "2, 5, 3" is two windows with 5 and 3 tabs,
    /// and "0" is no windows. Anything that is not a list of integers is nil.
    static func counts(osascript output: String) -> TabCounts? {
        let numbers = output.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !numbers.isEmpty, !numbers.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
        let values = numbers.compactMap { $0 }
        return TabCounts(windows: values[0], tabs: values.dropFirst().reduce(0, +))
    }

    /// Configured labels intersected with what is running. An empty config means all.
    static func selected(labels: [String], running: Set<String>) -> [BrowserApp] {
        browsers.filter { (labels.isEmpty || labels.contains($0.label)) && running.contains($0.bundleID) }
    }
}

// MARK: - Collector

/// Window and tab counts per running browser through AppleScript. The first
/// run triggers one Automation permission prompt per browser. A browser that
/// is not running is never asked, so Molly never launches one.
final class TabsCollector: Collector {
    let name = "tabs"
    let interval: TimeInterval

    static let scriptTimeout: TimeInterval = 10

    private let labels: [String]
    private let runningBundleIDs: () -> Set<String>
    private let runScript: (String) throws -> ShellResult
    private var warned = Set<String>()

    private var windows: Gauge?
    private var tabs: Gauge?

    init(settings: CollectorSettings,
         running: @escaping () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) },
         runScript: @escaping (String) throws -> ShellResult = { try Shell.run("osascript", ["-e", $0], timeout: TabsCollector.scriptTimeout) }) {
        interval = settings.interval(default: 60)
        labels = settings.strings("browsers").map { $0.lowercased() }
        runningBundleIDs = running
        self.runScript = runScript
    }

    func start(registry: MetricsRegistry) throws {
        windows = registry.gauge("molly_browser_windows", help: "Open browser windows, from AppleScript.", labels: ["browser"])
        tabs = registry.gauge("molly_browser_tabs", help: "Open browser tabs across all windows, from AppleScript.", labels: ["browser"])
    }

    func collect() throws {
        let targets = TabsParse.selected(labels: labels, running: runningBundleIDs())
        windows?.reset()
        tabs?.reset()
        var failures = 0
        for browser in targets {
            guard let counts = query(browser) else { failures += 1; continue }
            windows?.set(counts.windows, labels: ["browser": browser.label])
            tabs?.set(counts.tabs, labels: ["browser": browser.label])
        }
        if !targets.isEmpty, failures == targets.count {
            throw CollectorUnavailable(reason: "no running browser answered; grant Automation access in System Settings > Privacy & Security")
        }
    }

    private func query(_ browser: BrowserApp) -> TabCounts? {
        do {
            let result = try runScript(TabsParse.script(bundleID: browser.bundleID))
            if result.succeeded, let counts = TabsParse.counts(osascript: result.stdout) { return counts }
            warnOnce(browser, "osascript failed (\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch {
            warnOnce(browser, "\(error)")
        }
        return nil
    }

    private func warnOnce(_ browser: BrowserApp, _ message: String) {
        guard warned.insert(browser.label).inserted else { return }
        Log.warn("tabs: \(browser.label): \(message)")
    }
}
