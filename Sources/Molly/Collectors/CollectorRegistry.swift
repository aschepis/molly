import Foundation

/// The one place collectors are wired up. Each collector reads its own
/// section with `config.collector("<name>")` and is skipped when disabled.
enum CollectorRegistry {
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
        try add("browser") { try BrowserCollector(settings: $0) }
        try add("messages") { MessagesCollector(settings: $0) }
        try add("notes") { try NotesCollector(settings: $0) }
        try add("knowledge") { try KnowledgeCollector(settings: $0) }
        try add("calendar") { try CalendarCollector(settings: $0) }
        try add("mail", defaultEnabled: false) { MailCollector(settings: $0) }
        return collectors
    }
}

extension CollectorRegistry {
    /// Names with a config section; `molly validate` warns about anything else.
    static let knownNames: Set<String> = [
        "process", "system", "processes", "focus", "docker", "meeting",
        "browser", "messages", "notes", "knowledge", "calendar", "mail",
    ]
}
