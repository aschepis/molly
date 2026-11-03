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
        try add("git") { try GitCollector(settings: $0) }
        try add("claude_code") { try ClaudeCodeCollector(settings: $0) }
        try add("cursor") { CursorCollector(settings: $0) }
        try add("codex") { CodexCollector(settings: $0) }
        try add("shell") { try ShellCollector(settings: $0) }
        // After git and claude_code so a once-run sees what they reported.
        try add("projects") { try ProjectsCollector(settings: $0) }
        return collectors
    }
}

extension CollectorRegistry {
    /// Names with a config section; `molly validate` warns about anything else.
    static let knownNames: Set<String> = ["process", "git", "claude_code", "cursor", "codex", "shell", "projects"]
}
