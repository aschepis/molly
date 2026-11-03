import Foundation

/// USD per million tokens. These are list-price estimates for a dashboard,
/// not a bill; override them with the `pricing` config key.
struct ModelPrice: Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
}

struct TokenUsage: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreation = 0
}

enum ClaudePricing {
    /// Matched by substring against the model id; the first match wins, so
    /// more specific patterns must come first.
    static let defaults: [(pattern: String, price: ModelPrice)] = [
        ("claude-opus", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        ("claude-sonnet", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-haiku", ModelPrice(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)),
        ("claude-fable", ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
    ]

    static func table(from settings: CollectorSettings) -> [(pattern: String, price: ModelPrice)] {
        let overrides = settings.section("pricing").raw.compactMap { pattern, value -> (String, ModelPrice)? in
            guard let o = value.objectValue else { return nil }
            let fallback = ModelPrice(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
            return (pattern, ModelPrice(input: o["input"]?.doubleValue ?? fallback.input,
                                        output: o["output"]?.doubleValue ?? fallback.output,
                                        cacheRead: o["cacheRead"]?.doubleValue ?? fallback.cacheRead,
                                        cacheWrite: o["cacheWrite"]?.doubleValue ?? fallback.cacheWrite))
        }
        return overrides.sorted { $0.0 < $1.0 }.map { (pattern: $0.0, price: $0.1) } + defaults
    }

    static func price(for model: String, in table: [(pattern: String, price: ModelPrice)]) -> ModelPrice? {
        table.first { model.contains($0.pattern) }?.price
    }

    static func cost(_ usage: TokenUsage, at price: ModelPrice) -> Double {
        (Double(usage.input) * price.input + Double(usage.output) * price.output
            + Double(usage.cacheRead) * price.cacheRead + Double(usage.cacheCreation) * price.cacheWrite) / 1_000_000
    }
}

/// One relevant JSONL line from a Claude Code session file.
struct ClaudeLine: Equatable {
    enum Role: String { case user, assistant }

    var role: Role
    var isSidechain: Bool
    var timestamp: Date?
    var cwd: String?
    var messageId: String?
    var model: String?
    var usage: TokenUsage?
    var toolNames: [String]
    /// False for user lines that only carry tool results or meta content.
    var countsAsMessage: Bool

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainTimestampFormatter = ISO8601DateFormatter()

    /// Returns nil for every line type other than user and assistant, and for
    /// lines that are not valid JSON. Message text is never inspected.
    static func parse(_ line: String) -> ClaudeLine? {
        guard let json = try? JSONValue.parse(Data(line.utf8)),
              let type = json["type"]?.stringValue, let role = Role(rawValue: type) else { return nil }
        let message = json["message"]
        let content = message?["content"]
        var parsed = ClaudeLine(role: role,
                                isSidechain: json["isSidechain"]?.boolValue ?? false,
                                timestamp: json["timestamp"]?.stringValue.flatMap(parseTimestamp),
                                cwd: json["cwd"]?.stringValue,
                                messageId: nil, model: nil, usage: nil, toolNames: [], countsAsMessage: false)
        switch role {
        case .assistant:
            parsed.messageId = message?["id"]?.stringValue
            parsed.model = message?["model"]?.stringValue
            parsed.toolNames = (content?.arrayValue ?? []).compactMap { block in
                block["type"]?.stringValue == "tool_use" ? block["name"]?.stringValue : nil
            }
            if let u = message?["usage"] {
                parsed.usage = TokenUsage(input: u["input_tokens"]?.intValue ?? 0,
                                          output: u["output_tokens"]?.intValue ?? 0,
                                          cacheRead: u["cache_read_input_tokens"]?.intValue ?? 0,
                                          cacheCreation: u["cache_creation_input_tokens"]?.intValue ?? 0)
            }
            parsed.countsAsMessage = true
        case .user:
            let isMeta = json["isMeta"]?.boolValue ?? false
            if content?.stringValue != nil {
                parsed.countsAsMessage = !isMeta
            } else if let blocks = content?.arrayValue {
                parsed.countsAsMessage = !isMeta && blocks.contains { $0["type"]?.stringValue != "tool_result" }
            }
        }
        return parsed
    }

    static func parseTimestamp(_ text: String) -> Date? {
        timestampFormatter.date(from: text) ?? plainTimestampFormatter.date(from: text)
    }
}

/// Bounded set of recently seen ids, so a message split over several JSONL
/// lines (one per content block, each repeating `usage`) is counted once.
struct RecentIDs {
    private var set = Set<String>()
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 512) { self.limit = limit }

    /// Returns true if the id was new.
    mutating func insert(_ id: String) -> Bool {
        guard set.insert(id).inserted else { return false }
        order.append(id)
        if order.count > limit { set.remove(order.removeFirst()) }
        return true
    }
}

/// Tails Claude Code session transcripts. Reads only counts, model names,
/// tool names, timestamps and the working directory; message text is never
/// examined or stored.
final class ClaudeCodeCollector: Collector {
    let name = "claude_code"
    let interval: TimeInterval

    private struct FileState {
        var cwd: String?
        var lastTimestamp: Date?
        var messageIds = RecentIDs()
    }

    private let projectsDir: String
    private let historyFile: String
    private let activeWindow: TimeInterval
    private let sessionGap: TimeInterval
    private let projectLimiter: LabelLimiter
    private let pricing: [(pattern: String, price: ModelPrice)]
    private let store: StateStore
    private let offsets: OffsetTable
    private let tracker: ProjectTracker
    private let startedAt: Date
    private var files: [String: FileState] = [:]

    private var sessionsActive: Gauge?
    private var sessionsTotal: Counter?
    private var sessionsToday: Gauge?
    private var messages: Counter?
    private var toolCalls: Counter?
    private var tokens: Counter?
    private var cost: Counter?
    private var subagentMessages: Counter?
    private var prompts: Counter?
    private var duration: Counter?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder,
         tracker: ProjectTracker = .shared, startedAt: Date = Date()) throws {
        interval = settings.interval(default: 60)
        projectsDir = Paths.expand(settings.string("projectsDir", default: "~/.claude/projects"))
        historyFile = Paths.expand(settings.string("historyFile", default: "~/.claude/history.jsonl"))
        activeWindow = settings.double("activeWindowSeconds", default: 300)
        sessionGap = settings.double("sessionGapSeconds", default: 1800)
        let defaults = LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 30)
        projectLimiter = LabelLimiter(filter: try settings.filter("projects", defaults: defaults))
        pricing = ClaudePricing.table(from: settings)
        store = StateStore(collector: "claude_code", folder: stateFolder)
        offsets = OffsetTable(store: store)
        self.tracker = tracker
        self.startedAt = startedAt
    }

    func start(registry: MetricsRegistry) throws {
        sessionsActive = registry.gauge("molly_claude_sessions_active", help: "Session files modified within activeWindowSeconds.")
        sessionsTotal = registry.counter("molly_claude_sessions_total", help: "Session files created since Molly started.")
        sessionsToday = registry.gauge("molly_claude_sessions_today", help: "Session files created today.")
        messages = registry.counter("molly_claude_messages_total", help: "Messages by role; tool results are not counted as user messages.", labels: ["role", "project"])
        toolCalls = registry.counter("molly_claude_tool_calls_total", help: "Tool invocations.", labels: ["tool", "project"])
        tokens = registry.counter("molly_claude_tokens_total", help: "Tokens by model and kind.", labels: ["model", "kind"])
        cost = registry.counter("molly_claude_estimated_cost_usd_total", help: "Estimated spend from list prices (not a bill).", labels: ["model"])
        subagentMessages = registry.counter("molly_claude_subagent_messages_total", help: "Messages from subagent (sidechain) conversations; a subset of messages_total.")
        prompts = registry.counter("molly_claude_prompts_total", help: "Prompts typed, from history.jsonl.")
        duration = registry.counter("molly_claude_session_duration_seconds_total", help: "Active wall time of sessions; gaps over sessionGapSeconds are idle.", labels: ["project"])
    }

    func collect() throws {
        guard FileManager.default.fileExists(atPath: projectsDir) else {
            throw CollectorUnavailable(reason: "\(projectsDir) does not exist")
        }
        let now = Date()
        let midnight = Clock.startOfToday(now: now)
        var live = Set<String>()
        var active = 0
        var today = 0

        for path in sessionFiles() {
            live.insert(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let modified = attributes[.modificationDate] as? Date
            let created = attributes[.creationDate] as? Date
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let isSession = isSessionFile(path)

            if let modified, now.timeIntervalSince(modified) <= activeWindow, isSession { active += 1 }
            if let created, created >= midnight, isSession { today += 1 }

            var offset: Int
            if let known = offsets.offset(for: path) {
                offset = known
            } else {
                offset = FileTail.initialOffset(size: size, created: created, modified: modified, startedAt: startedAt)
                if FileTail.isNewFile(created: created, modified: modified, startedAt: startedAt), isSession {
                    sessionsTotal?.inc()
                }
            }
            do {
                let chunk = try FileTail.read(path: path, from: offset)
                for line in chunk.lines { process(line, path: path) }
                offset = chunk.offset
            } catch {
                Log.debug("claude_code: \(path): \(error)")
            }
            offsets.set(offset, for: path)
        }
        sessionsActive?.set(active)
        sessionsToday?.set(today)
        files = files.filter { live.contains($0.key) }
        countPrompts(now: now)
        offsets.prune(keeping: live.union([historyFile]))
        offsets.save()
    }

    // MARK: - Files

    private func sessionFiles() -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: projectsDir) else { return [] }
        var paths: [String] = []
        for case let relative as String in enumerator where relative.hasSuffix(".jsonl") {
            paths.append(projectsDir + "/" + relative)
        }
        return paths.sorted()
    }

    /// <project>/<session>.jsonl; deeper files are subagent transcripts.
    private func isSessionFile(_ path: String) -> Bool {
        path.dropFirst(projectsDir.count + 1).split(separator: "/").count == 2
    }

    private func projectDirectoryName(of path: String) -> String {
        String(path.dropFirst(projectsDir.count + 1).split(separator: "/").first ?? "")
    }

    private func countPrompts(now: Date) {
        guard FileManager.default.fileExists(atPath: historyFile),
              let attributes = try? FileManager.default.attributesOfItem(atPath: historyFile) else { return }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let offset = offsets.offset(for: historyFile) ?? FileTail.initialOffset(
            size: size, created: attributes[.creationDate] as? Date,
            modified: attributes[.modificationDate] as? Date, startedAt: startedAt)
        guard let chunk = try? FileTail.read(path: historyFile, from: offset) else { return }
        prompts?.add(Double(chunk.lines.count))
        offsets.set(chunk.offset, for: historyFile)
    }

    // MARK: - Lines

    private func process(_ text: String, path: String) {
        guard let line = ClaudeLine.parse(text) else { return }
        var state = files[path] ?? FileState()
        defer { files[path] = state }

        if let cwd = line.cwd { state.cwd = cwd }
        let projectPath = state.cwd ?? ProjectName.decodeClaudeDirectory(projectDirectoryName(of: path))
        let project = ProjectName.normalize(path: projectPath)
        let label = projectLimiter.label(project)

        if let time = line.timestamp {
            tracker.report(project: project, source: .claude, at: time)
            if let last = state.lastTimestamp {
                let gap = time.timeIntervalSince(last)
                if gap > 0, gap <= sessionGap { duration?.add(gap, labels: ["project": label]) }
            }
            if state.lastTimestamp.map({ time > $0 }) ?? true { state.lastTimestamp = time }
        }
        for tool in line.toolNames { toolCalls?.inc(labels: ["tool": tool, "project": label]) }

        let isNewMessage = line.messageId.map { state.messageIds.insert($0) } ?? true
        guard isNewMessage, line.countsAsMessage else { return }
        messages?.inc(labels: ["role": line.role.rawValue, "project": label])
        if line.isSidechain { subagentMessages?.inc() }
        if let usage = line.usage, let model = line.model { record(usage, model: model) }
    }

    private func record(_ usage: TokenUsage, model: String) {
        guard !model.hasPrefix("<") else { return }
        tokens?.add(Double(usage.input), labels: ["model": model, "kind": "input"])
        tokens?.add(Double(usage.output), labels: ["model": model, "kind": "output"])
        tokens?.add(Double(usage.cacheRead), labels: ["model": model, "kind": "cache_read"])
        tokens?.add(Double(usage.cacheCreation), labels: ["model": model, "kind": "cache_creation"])
        let price = ClaudePricing.price(for: model, in: pricing)
        cost?.add(price.map { ClaudePricing.cost(usage, at: $0) } ?? 0, labels: ["model": model])
    }
}
