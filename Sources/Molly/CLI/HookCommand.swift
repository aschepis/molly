import Foundation

/// `molly hook`: the Claude Code side of live events. The bare command reads
/// a hook payload on stdin and posts it to the running Molly; it always exits
/// 0 so a stopped Molly can never block Claude Code.
enum HookCommand {
    static let hookEvents = [
        "PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop", "SubagentStop",
        "SessionStart", "SessionEnd", "Notification",
    ]
    static let commandSuffix = "molly hook"

    static func run(_ arguments: [String]) {
        switch arguments.first {
        case nil:
            post()
        case "snippet":
            print(snippetJSON(executable: currentExecutable()))
        case "install":
            install()
        case "uninstall":
            uninstall()
        default:
            FileHandle.standardError.write(Data("usage: molly hook [snippet|install|uninstall]\n".utf8))
            exit(2)
        }
    }

    // MARK: posting

    private static func post() {
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        guard !payload.isEmpty, (try? JSONValue.parse(payload))?.objectValue != nil else { exit(0) }
        let config = (try? Config.load()) ?? Config()
        var body = payload
        if let merged = withSource(payload) { body = merged }
        let url = URL(string: "http://\(config.server.bind):\(config.server.port)/event")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = config.collector("events").string("token", default: "")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 3)
        exit(0)
    }

    /// Adds "source": "claude_code" unless the payload already names one.
    static func withSource(_ payload: Data) -> Data? {
        guard let json = try? JSONValue.parse(payload), var object = json.objectValue else { return nil }
        if object["source"] == nil { object["source"] = .string(EventsCollector.claudeSource) }
        return try? JSONEncoder().encode(JSONValue.object(object))
    }

    // MARK: settings.json

    static var settingsURL: URL {
        Paths.home.appendingPathComponent(".claude/settings.json")
    }

    static func currentExecutable() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    /// The hooks block Claude Code expects: one matcher-less group per event.
    static func hookEntries(executable: String) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let command = "\(executable) hook"
        for event in hookEvents {
            out[event] = .array([
                .object([
                    "hooks": .array([
                        .object(["type": .string("command"), "command": .string(command), "timeout": .number(5)])
                    ])
                ])
            ])
        }
        return out
    }

    static func snippetJSON(executable: String) -> String {
        let root = JSONValue.object(["hooks": .object(hookEntries(executable: executable))])
        return prettyJSON(root)
    }

    /// Merges Molly's hook groups into an existing settings object. Groups
    /// already present (identified by a command ending in "molly hook") are
    /// replaced, everything else is kept, so running it twice is a no-op.
    static func merge(settings: JSONValue, executable: String) throws -> JSONValue {
        guard var root = settings.objectValue else { throw ConfigError.invalid("settings.json must be a JSON object") }
        // uninstall finds our groups by this suffix, so a renamed binary would be unremovable.
        guard "\(executable) hook".hasSuffix(commandSuffix) else {
            throw ConfigError.invalid("the executable must be named molly (got \(executable))")
        }
        var hooks = root["hooks"]?.objectValue ?? [:]
        for (event, group) in hookEntries(executable: executable) {
            let existing = hooks[event]?.arrayValue ?? []
            let kept = existing.filter { !isMollyGroup($0) }
            hooks[event] = .array(kept + (group.arrayValue ?? []))
        }
        root["hooks"] = .object(hooks)
        return .object(root)
    }

    /// Removes exactly the groups `merge` adds. Events left empty are dropped;
    /// an empty hooks object is dropped too.
    static func unmerge(settings: JSONValue) throws -> JSONValue {
        guard var root = settings.objectValue else { throw ConfigError.invalid("settings.json must be a JSON object") }
        guard var hooks = root["hooks"]?.objectValue else { return settings }
        for (event, groups) in hooks {
            let kept = (groups.arrayValue ?? []).filter { !isMollyGroup($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = .array(kept) }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = .object(hooks) }
        return .object(root)
    }

    static func isMollyGroup(_ group: JSONValue) -> Bool {
        guard let inner = group["hooks"]?.arrayValue else { return false }
        return inner.contains { $0["command"]?.stringValue?.hasSuffix(commandSuffix) == true }
    }

    static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func install() {
        rewriteSettings { try merge(settings: $0, executable: currentExecutable()) }
        print("hooks installed in \(settingsURL.path); restart Claude Code sessions to pick them up")
    }

    private static func uninstall() {
        rewriteSettings { try unmerge(settings: $0) }
        print("molly hooks removed from \(settingsURL.path)")
    }

    private static func rewriteSettings(_ transform: (JSONValue) throws -> JSONValue) {
        let fm = FileManager.default
        var current = JSONValue.object([:])
        if fm.fileExists(atPath: settingsURL.path) {
            guard let data = try? Data(contentsOf: settingsURL), let parsed = try? JSONValue.parse(data) else {
                FileHandle.standardError.write(Data("refusing to touch \(settingsURL.path): not valid JSON\n".utf8))
                exit(1)
            }
            current = parsed
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.molly-backup-\(stamp)")
            try? fm.copyItem(at: settingsURL, to: backup)
        }
        do {
            let updated = try transform(current)
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((prettyJSON(updated) + "\n").utf8).write(to: settingsURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
