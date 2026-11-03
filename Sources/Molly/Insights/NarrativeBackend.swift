import Foundation

/// Turns a prompt into prose. The Claude API (with a key) and the local
/// `claude` CLI (billed to the user's subscription) both conform.
protocol NarrativeCompleter {
    var name: String { get }
    func complete(system: String, prompt: String) throws -> String
}

enum NarrativeError: Error, CustomStringConvertible {
    case noBackend
    case api(String)
    case cli(String)
    case refused(String)

    var description: String {
        switch self {
        case .noBackend:
            return "no narrative backend: set ANTHROPIC_API_KEY (or collectors.insights.apiKey), or install the claude CLI"
        case .api(let m): return "Claude API: \(m)"
        case .cli(let m): return "claude CLI: \(m)"
        case .refused(let m): return "Claude declined: \(m)"
        }
    }
}

/// Claude Messages API over raw HTTP. Swift has no official SDK.
struct ClaudeAPICompleter: NarrativeCompleter {
    static let defaultModel = "claude-sonnet-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let apiKey: String
    let model: String
    var maxTokens = 1500
    var timeout: TimeInterval = 120
    /// Injectable transport for tests: returns (status, body).
    var transport: (URLRequest) throws -> (Int, Data) = ClaudeAPICompleter.send

    var name: String { "api:\(model)" }

    init(apiKey: String, model: String = ClaudeAPICompleter.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    func complete(system: String, prompt: String) throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (status, data) = try transport(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NarrativeError.api("HTTP \(status): not JSON")
        }
        guard status == 200 else {
            let message = (root["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw NarrativeError.api("HTTP \(status): \(message)")
        }
        return try Self.text(from: root)
    }

    static func text(from root: [String: Any]) throws -> String {
        if root["stop_reason"] as? String == "refusal" {
            let details = root["stop_details"] as? [String: Any]
            throw NarrativeError.refused(details?["explanation"] as? String ?? "refusal")
        }
        let blocks = root["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw NarrativeError.api("empty response") }
        return text
    }

    static func send(_ request: URLRequest) throws -> (Int, Data) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        URLSession.shared.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = result.2 { throw NarrativeError.api(error.localizedDescription) }
        return ((result.1 as? HTTPURLResponse)?.statusCode ?? 0, result.0 ?? Data())
    }
}

/// Runs `claude -p` with the prompt on stdin. Uses the CLI's default model.
struct ClaudeCLICompleter: NarrativeCompleter {
    let executable: String
    var timeout: TimeInterval = 120

    var name: String { "cli" }

    static func findExecutable(home: URL = Paths.home) -> String? {
        if let onPath = Shell.which("claude") { return onPath }
        for candidate in [".local/bin/claude", ".claude/local/claude", ".claude/local/bin/claude"] {
            let path = home.appendingPathComponent(candidate).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    func complete(system: String, prompt: String) throws -> String {
        // The CLI refuses to start inside another Claude Code session, so
        // strip that marker; everything else about the environment is kept.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDECODE")
        let result: ShellResult
        do {
            result = try Shell.run(executable, ["-p", "--output-format", "text"], timeout: timeout,
                                   environment: environment, input: Data((system + "\n\n" + prompt).utf8))
        } catch {
            throw NarrativeError.cli(String(describing: error))
        }
        guard result.succeeded else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NarrativeError.cli("exit \(result.status): \(stderr.prefix(300))")
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NarrativeError.cli("produced no output") }
        return text
    }
}

enum NarrativeBackend {
    enum Choice: String { case auto, api, cli }

    /// API key first (env, then config), then the CLI; `choice` forces one.
    static func make(choice: Choice, apiKey: String?, model: String,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     cliLocator: () -> String? = { ClaudeCLICompleter.findExecutable() }) throws -> NarrativeCompleter {
        let key = [environment["ANTHROPIC_API_KEY"], apiKey].compactMap { $0 }.first { !$0.isEmpty }
        switch choice {
        case .api:
            guard let key else { throw NarrativeError.noBackend }
            return ClaudeAPICompleter(apiKey: key, model: model)
        case .cli:
            guard let path = cliLocator() else { throw NarrativeError.noBackend }
            return ClaudeCLICompleter(executable: path)
        case .auto:
            if let key { return ClaudeAPICompleter(apiKey: key, model: model) }
            if let path = cliLocator() { return ClaudeCLICompleter(executable: path) }
            throw NarrativeError.noBackend
        }
    }
}
