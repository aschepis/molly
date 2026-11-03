import AppKit
import Foundation

// MARK: - Pure logic (unit-tested)

enum TitleNormalizer {
    static let maxLength = 80

    /// Suffixes browsers and editors append; stripping them keeps one series
    /// per document rather than one per app-document pair.
    static let suffixes: [String] = [
        " - Google Chrome", " - Brave", " - Microsoft Edge", " - Vivaldi", " — Mozilla Firefox", " - Mozilla Firefox",
        " - Visual Studio Code", " — Edited", " - Edited", " — Locked", " - Locked",
    ]

    /// Collapses whitespace, strips known app suffixes and edit markers, and
    /// truncates. Returns "" for an empty title.
    static func normalize(_ raw: String) -> String {
        var title = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var stripped = true
        while stripped {
            stripped = false
            for suffix in suffixes where title.lowercased().hasSuffix(suffix.lowercased()) {
                title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        if title.count > maxLength {
            title = String(title.prefix(maxLength))
        }
        return title
    }
}

struct WindowTitle: Equatable {
    let app: String
    let title: String
}

/// Which window is frontmost, and for how long, between polls.
struct TitlesState: Equatable {
    struct Deltas: Equatable {
        var seconds: Double = 0
        var changed = false
    }

    private(set) var current: WindowTitle?
    private var lastSeen: Date?

    mutating func advance(to date: Date, window: WindowTitle?, maxGap: TimeInterval) -> Deltas {
        var deltas = Deltas()
        if let last = lastSeen, current != nil {
            deltas.seconds = min(max(0, date.timeIntervalSince(last)), maxGap)
        }
        lastSeen = date
        if window != current {
            deltas.changed = true
            current = window
        }
        return deltas
    }
}

// MARK: - Collector

/// The frontmost window's title, hashed by default. Needs Screen Recording
/// permission: without it CGWindowListCopyWindowInfo omits titles entirely.
final class TitlesCollector: Collector {
    let name = "titles"
    let interval: TimeInterval

    static let permissionHint = "window titles need Screen Recording: System Settings > Privacy & Security > Screen Recording, add the molly binary or Molly.app"

    private let titleFilter: LabelFilter
    private let appFilter: LabelFilter
    private var titleCardinality: CardinalityGuard
    private let hasPermission: () -> Bool
    private let frontWindow: () -> WindowTitle?
    private var state = TitlesState()

    private var windowInfo: Gauge?
    private var windowSeconds: Counter?

    init(settings: CollectorSettings, config: Config,
         hasPermission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         frontWindow: @escaping () -> WindowTitle? = TitlesCollector.systemFrontWindow) throws {
        interval = settings.interval(default: 5)
        titleFilter = try settings.filter("titles", defaults: LabelPolicy(enabled: true, mode: .denylist, hash: true, maxCardinality: 100))
        // Same policy the focus collector reads, so app names agree across both.
        appFilter = try config.collector("focus").filter("apps", defaults: LabelPolicy(enabled: true, mode: .denylist))
        titleCardinality = CardinalityGuard(limit: titleFilter.maxCardinality)
        self.hasPermission = hasPermission
        self.frontWindow = frontWindow
    }

    func start(registry: MetricsRegistry) throws {
        windowInfo = registry.gauge("molly_focus_window_info", help: "The frontmost window (exactly one series; policy titles.titles).", labels: ["app", "title"])
        windowSeconds = registry.counter("molly_focus_window_seconds_total", help: "Frontmost time per window title.", labels: ["app", "title"])
    }

    func collect() throws {
        guard hasPermission() else {
            windowInfo?.reset()
            throw CollectorUnavailable(reason: TitlesCollector.permissionHint)
        }
        let window = frontWindow().map { WindowTitle(app: $0.app, title: TitleNormalizer.normalize($0.title)) }
        let previous = state.current
        let deltas = state.advance(to: Date(), window: window, maxGap: interval * 2)
        if let previous, deltas.seconds > 0 {
            windowSeconds?.add(deltas.seconds, labels: labels(for: previous))
        }
        if deltas.changed {
            windowInfo?.reset()
            if let window { windowInfo?.set(1, labels: labels(for: window)) }
        }
    }

    private func labels(for window: WindowTitle) -> [String: String] {
        let title = window.title.isEmpty ? LabelPolicy.other : titleCardinality.admit(titleFilter.label(window.title))
        return ["app": appFilter.label(window.app), "title": title]
    }

    /// The first on-screen, layer-0 window owned by the frontmost app. Titles
    /// are only present in the list when Screen Recording is granted.
    static func systemFrontWindow() -> WindowTitle? {
        let work = { () -> (pid_t, String)? in
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return (app.processIdentifier, app.localizedName ?? app.bundleIdentifier ?? "unknown")
        }
        guard let front = Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work) else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == front.0,
                  (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let title = (window[kCGWindowName as String] as? String) ?? ""
            return WindowTitle(app: front.1, title: title)
        }
        return WindowTitle(app: front.1, title: "")
    }
}
