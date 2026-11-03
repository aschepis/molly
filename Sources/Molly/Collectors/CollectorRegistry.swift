import Foundation

/// The one place collectors are wired up. Each collector reads its own
/// section with `config.collector("<name>")` and is skipped when disabled.
enum CollectorRegistry {
    /// Collectors that need an explicit opt-in because of permissions or
    /// sensitivity. Must match the `defaultEnabled: false` lines below.
    static let disabledByDefault: Set<String> = ["input", "mail", "tabs", "media", "titles", "insights"]

    static func makeCollectors(config: Config) throws -> [Collector] {
        var collectors: [Collector] = []
        func add(_ name: String, defaultEnabled: Bool = true, _ make: (CollectorSettings) throws -> Collector) throws {
            let settings = config.collector(name)
            guard settings.enabled(default: defaultEnabled) else {
                Log.info("collector \(name) disabled")
                return
            }
            collectors.append(try make(settings))
        }

        try add("process") { ProcessSelfCollector(settings: $0) }
        try add("system") { try SystemCollector(settings: $0) }
        try add("processes") { try ProcessesCollector(settings: $0) }
        try add("focus") { try FocusCollector(settings: $0) }
        try add("docker") { try DockerCollector(settings: $0) }
        try add("meeting") { MeetingCollector(settings: $0) }
        try add("input", defaultEnabled: false) { InputCollector(settings: $0) }
        try add("clipboard") { ClipboardCollector(settings: $0) }
        try add("hardware") { try HardwareCollector(settings: $0) }
        try add("browser") { try BrowserCollector(settings: $0) }
        try add("messages") { MessagesCollector(settings: $0) }
        try add("notes") { try NotesCollector(settings: $0) }
        try add("knowledge") { try KnowledgeCollector(settings: $0) }
        try add("calendar") { try CalendarCollector(settings: $0) }
        try add("reminders") { try RemindersCollector(settings: $0) }
        try add("mail", defaultEnabled: false) { MailCollector(settings: $0) }
        try add("git") { try GitCollector(settings: $0) }
        try add("claude_code") { try ClaudeCodeCollector(settings: $0) }
        try add("cursor") { CursorCollector(settings: $0) }
        try add("codex") { CodexCollector(settings: $0) }
        try add("shell") { try ShellCollector(settings: $0) }
        // After git and claude_code so a once-run sees what they reported.
        try add("projects") { try ProjectsCollector(settings: $0) }
        try add("power") { PowerCollector(settings: $0) }
        try add("builds") { BuildsCollector(settings: $0) }
        try add("tabs", defaultEnabled: false) { TabsCollector(settings: $0) }
        try add("media", defaultEnabled: false) { try MediaCollector(settings: $0) }
        try add("titles", defaultEnabled: false) { try TitlesCollector(settings: $0, config: config) }
        try add("events") { try EventsCollector(settings: $0) }
        try add("insights", defaultEnabled: false) { try InsightsCollector(settings: $0, config: config) }
        return collectors
    }
}

extension CollectorRegistry {
    /// Names with a config section; `molly validate` warns about anything else.
    static let knownNames: Set<String> = [
        "process", "system", "processes", "focus", "docker", "meeting", "input", "clipboard", "hardware",
        "browser", "messages", "notes", "knowledge", "calendar", "reminders", "mail",
        "git", "claude_code", "cursor", "codex", "shell", "projects",
        "power", "builds", "tabs", "events", "insights", "media", "titles",
    ]
}
