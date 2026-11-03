import Foundation

/// One relevant line of a Codex CLI rollout file. The format is not a
/// documented contract; unknown lines are ignored.
struct CodexLine: Equatable {
    var role: String?
    var model: String?
    var usage: TokenUsage?
    /// Cumulative total in the same event, used to skip repeated token_count events.
    var totalTokens: Int?

    static func parse(_ text: String) -> CodexLine? {
        guard let json = try? JSONValue.parse(Data(text.utf8)), let type = json["type"]?.stringValue else { return nil }
        let payload = json["payload"]
        var line = CodexLine()
        switch type {
        case "response_item":
            guard payload?["type"]?.stringValue == "message" else { return nil }
            line.role = payload?["role"]?.stringValue
        case "message":
            line.role = json["role"]?.stringValue
        case "turn_context":
            line.model = payload?["model"]?.stringValue
        case "event_msg":
            guard payload?["type"]?.stringValue == "token_count", let info = payload?["info"],
                  let last = info["last_token_usage"] else { return nil }
            let cached = last["cached_input_tokens"]?.intValue ?? 0
            line.usage = TokenUsage(input: max(0, (last["input_tokens"]?.intValue ?? 0) - cached),
                                    output: last["output_tokens"]?.intValue ?? 0,
                                    cacheRead: cached, cacheCreation: 0)
            line.totalTokens = info["total_token_usage"]?["total_tokens"]?.intValue
        default:
            return nil
        }
        guard line.role == "user" || line.role == "assistant" || line.model != nil || line.usage != nil else { return nil }
        return line
    }
}

/// OpenAI Codex CLI sessions (~/.codex/sessions). Same incremental tailing as
/// claude_code, reduced to session, message and token counts.
final class CodexCollector: Collector {
    let name = "codex"
    let interval: TimeInterval

    private struct FileState {
        var model = "unknown"
        var lastTotal: Int?
    }

    private let sessionsDir: String
    private let activeWindow: TimeInterval
    private let store: StateStore
    private let offsets: OffsetTable
    private let startedAt: Date
    private var files: [String: FileState] = [:]

    private var sessionsActive: Gauge?
    private var sessionsTotal: Counter?
    private var messages: Counter?
    private var tokens: Counter?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, startedAt: Date = Date()) {
        interval = settings.interval(default: 120)
        sessionsDir = Paths.expand(settings.string("sessionsDir", default: "~/.codex/sessions"))
        activeWindow = settings.double("activeWindowSeconds", default: 300)
        store = StateStore(collector: "codex", folder: stateFolder)
        offsets = OffsetTable(store: store)
        self.startedAt = startedAt
    }

    func start(registry: MetricsRegistry) throws {
        sessionsActive = registry.gauge("molly_codex_sessions_active", help: "Codex session files modified within activeWindowSeconds.")
        sessionsTotal = registry.counter("molly_codex_sessions_total", help: "Codex session files created since Molly started.")
        messages = registry.counter("molly_codex_messages_total", help: "Codex messages by role.", labels: ["role"])
        tokens = registry.counter("molly_codex_tokens_total", help: "Codex tokens by model and kind.", labels: ["model", "kind"])
    }

    func collect() throws {
        guard let enumerator = FileManager.default.enumerator(atPath: sessionsDir) else {
            throw CollectorUnavailable(reason: "\(sessionsDir) does not exist (Codex CLI not used on this machine)")
        }
        var live = Set<String>()
        var active = 0
        let now = Date()
        for case let relative as String in enumerator where relative.hasSuffix(".jsonl") {
            let path = sessionsDir + "/" + relative
            live.insert(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let modified = attributes[.modificationDate] as? Date
            if let modified, now.timeIntervalSince(modified) <= activeWindow { active += 1 }

            var offset: Int
            if let known = offsets.offset(for: path) {
                offset = known
            } else {
                offset = FileTail.initialOffset(size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                                                created: attributes[.creationDate] as? Date,
                                                modified: modified, startedAt: startedAt)
                if FileTail.isNewFile(created: attributes[.creationDate] as? Date, modified: modified, startedAt: startedAt) {
                    sessionsTotal?.inc()
                }
            }
            do {
                let chunk = try FileTail.read(path: path, from: offset)
                for line in chunk.lines { process(line, path: path) }
                offset = chunk.offset
            } catch {
                Log.debug("codex: \(path): \(error)")
            }
            offsets.set(offset, for: path)
        }
        sessionsActive?.set(active)
        files = files.filter { live.contains($0.key) }
        offsets.prune(keeping: live)
        offsets.save()
    }

    private func process(_ text: String, path: String) {
        guard let line = CodexLine.parse(text) else { return }
        var state = files[path] ?? FileState()
        defer { files[path] = state }
        if let model = line.model { state.model = model }
        if let role = line.role { messages?.inc(labels: ["role": role]) }
        guard let usage = line.usage else { return }
        if let total = line.totalTokens {
            if total == state.lastTotal { return }
            state.lastTotal = total
        }
        let labels = ["model": state.model]
        tokens?.add(Double(usage.input), labels: labels.merging(["kind": "input"]) { $1 })
        tokens?.add(Double(usage.output), labels: labels.merging(["kind": "output"]) { $1 })
        tokens?.add(Double(usage.cacheRead), labels: labels.merging(["kind": "cache_read"]) { $1 })
    }
}
