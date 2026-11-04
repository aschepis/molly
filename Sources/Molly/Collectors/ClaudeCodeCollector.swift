import Foundation

/// USD per million tokens. These are list-price estimates for a dashboard,
/// not a bill; add or override rows with the `pricing` config key.
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
    ]

    /// `list` presents the series as an estimate of API cost; `subscription`
    /// marks it a list-price equivalent so alerts and summaries do not call it spend.
    enum Mode: String, CaseIterable {
        case list, subscription
    }

    static func mode(from settings: CollectorSettings) -> Mode {
        Mode(rawValue: settings.section("pricing").string("mode", default: Mode.list.rawValue)) ?? .list
    }

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

/// A model without a price row costs 0; say so once instead of silently.
struct UnknownModelWarnings {
    private var seen: Set<String> = []

    mutating func shouldWarn(_ model: String) -> Bool {
        seen.insert(model).inserted
    }

    func message(model: String) -> String {
        "claude_code: no price for model \"\(model)\", its cost counts as 0. Add a row under collectors.claude_code.pricing (see docs/CONFIG.md)."
    }
}

struct ToolUse: Equatable {
    var id: String?
    var name: String

    /// `mcp__<server>__<tool>` belongs to <server>; everything else is built in.
    var server: String { ToolUse.server(for: name) }

    static let builtinServer = "builtin"

    static func server(for tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty else { return builtinServer }
        return parts[1]
    }
}

struct ToolResult: Equatable {
    var toolUseId: String
    var isError: Bool
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
    var toolUses: [ToolUse]
    var toolResults: [ToolResult]
    /// From the top-level toolUseResult object of a tool-result line.
    var interrupted: Bool
    var permissionDecision: String?
    var sandboxed: Bool
    var toolNames: [String] { toolUses.map(\.name) }
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
                                messageId: nil, model: nil, usage: nil, toolUses: [], toolResults: [],
                                interrupted: false, permissionDecision: nil, sandboxed: false, countsAsMessage: false)
        switch role {
        case .assistant:
            parsed.messageId = message?["id"]?.stringValue
            parsed.model = message?["model"]?.stringValue
            parsed.toolUses = (content?.arrayValue ?? []).compactMap { block in
                guard block["type"]?.stringValue == "tool_use", let name = block["name"]?.stringValue else { return nil }
                return ToolUse(id: block["id"]?.stringValue, name: name)
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
            parsed.toolResults = (content?.arrayValue ?? []).compactMap { block in
                guard block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue else { return nil }
                return ToolResult(toolUseId: id, isError: block["is_error"]?.boolValue ?? false)
            }
            // One interrupted flag cannot be attributed to several results on the same line.
            parsed.interrupted = parsed.toolResults.count == 1 && (json["toolUseResult"]?["interrupted"]?.boolValue ?? false)
            parsed.permissionDecision = json["permissionDecision"]?.stringValue
            parsed.sandboxed = json["sandboxed"]?.boolValue ?? false
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

/// A tool_use waiting for its tool_result. Persisted so a restart does not lose in-flight calls.
struct PendingTool: Equatable {
    var startedAt: Date
    var tool: String
    var project: String

    init(startedAt: Date, tool: String, project: String) {
        self.startedAt = startedAt
        self.tool = tool
        self.project = project
    }

    init?(json: JSONValue) {
        guard let seconds = json["t"]?.doubleValue, let tool = json["tool"]?.stringValue,
              let project = json["project"]?.stringValue else { return nil }
        self.init(startedAt: Date(timeIntervalSince1970: seconds), tool: tool, project: project)
    }

    var json: JSONValue {
        .object(["t": .number(startedAt.timeIntervalSince1970), "tool": .string(tool), "project": .string(project)])
    }
}

/// Tails Claude Code session transcripts. Reads only counts, model names,
/// tool names, timestamps and the working directory; message text is never
/// examined or stored.
final class ClaudeCodeCollector: Collector {
    static let projectsDefaults = LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 30)
    static let defaultToolTimeoutSeconds = 3600.0
    static let toolDurationBuckets: [Double] = [0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600]
    static let turnLatencyBuckets: [Double] = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600]
    static let permissionDecisions: Set<String> = ["allow", "deny", "ask"]
    static let pendingKey = "pending_tools"
    static let unknownLabel = "unknown"
    let name = "claude_code"
    let interval: TimeInterval

    private struct FileState {
        var cwd: String?
        var lastTimestamp: Date?
        var messageIds = RecentIDs()
        /// Set by a typed prompt, cleared by the next assistant line in this file.
        var promptAt: Date?
    }

    private let projectsDir: String
    private let historyFile: String
    private let activeWindow: TimeInterval
    private let sessionGap: TimeInterval
    private let projectLimiter: LabelLimiter
    private let pricing: [(pattern: String, price: ModelPrice)]
    private let pricingMode: ClaudePricing.Mode
    private var unknownModels = UnknownModelWarnings()
    private let store: StateStore
    private let offsets: OffsetTable
    private let tracker: ProjectTracker
    private let startedAt: Date
    private let toolTimeout: TimeInterval
    private let now: () -> Date
    private var pending: [String: PendingTool] = [:]
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
    private var toolDuration: Histogram?
    private var toolUnmatched: Counter?
    private var toolErrors: Counter?
    private var turnLatency: Histogram?
    private var permissionDecisions: Counter?
    private var sandboxedCalls: Counter?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder,
         tracker: ProjectTracker = .shared, startedAt: Date = Date(),
         now: @escaping () -> Date = { Date() }) throws {
        interval = settings.interval(default: 60)
        projectsDir = Paths.expand(settings.string("projectsDir", default: "~/.claude/projects"))
        historyFile = Paths.expand(settings.string("historyFile", default: "~/.claude/history.jsonl"))
        activeWindow = settings.double("activeWindowSeconds", default: 300)
        sessionGap = settings.double("sessionGapSeconds", default: 1800)
        projectLimiter = LabelLimiter(filter: try settings.filter("projects", defaults: ClaudeCodeCollector.projectsDefaults))
        pricing = ClaudePricing.table(from: settings)
        pricingMode = ClaudePricing.mode(from: settings)
        store = StateStore(collector: "claude_code", folder: stateFolder)
        offsets = OffsetTable(store: store)
        self.tracker = tracker
        self.startedAt = startedAt
        self.now = now
        toolTimeout = settings.double("toolTimeoutSeconds", default: ClaudeCodeCollector.defaultToolTimeoutSeconds)
        for (id, value) in store.get(ClaudeCodeCollector.pendingKey)?.objectValue ?? [:] {
            if let entry = PendingTool(json: value) { pending[id] = entry }
        }
    }

    func start(registry: MetricsRegistry) throws {
        sessionsActive = registry.gauge("molly_claude_sessions_active", help: "Session files modified within activeWindowSeconds.")
        sessionsTotal = registry.counter("molly_claude_sessions_total", help: "Session files created since Molly started.")
        sessionsToday = registry.gauge("molly_claude_sessions_today", help: "Session files created today.")
        messages = registry.counter("molly_claude_messages_total", help: "Messages by role; tool results are not counted as user messages.", labels: ["role", "project"])
        toolCalls = registry.counter("molly_claude_tool_calls_total", help: "Tool invocations. server is the MCP server, or builtin.", labels: ["tool", "server", "project"])
        tokens = registry.counter("molly_claude_tokens_total", help: "Tokens by model, kind and project.", labels: ["model", "kind", "project"])
        cost = registry.counter("molly_claude_estimated_cost_usd_total", help: "Token counts at list prices: never a bill, and a list-price equivalent under a subscription.", labels: ["model", "project"])
        let modeGauge = registry.gauge("molly_claude_pricing_mode", help: "1 for the configured pricing mode (list or subscription).", labels: ["mode"])
        for mode in ClaudePricing.Mode.allCases {
            modeGauge.set(mode == pricingMode ? 1 : 0, labels: ["mode": mode.rawValue])
        }
        subagentMessages = registry.counter("molly_claude_subagent_messages_total", help: "Messages from subagent (sidechain) conversations; a subset of messages_total.")
        prompts = registry.counter("molly_claude_prompts_total", help: "Prompts typed, from history.jsonl.")
        duration = registry.counter("molly_claude_session_duration_seconds_total", help: "Active wall time of sessions; gaps over sessionGapSeconds are idle.", labels: ["project"])
        toolDuration = registry.histogram("molly_claude_tool_duration_seconds", help: "Seconds from a tool_use to its tool_result, by transcript timestamps.",
                                          labels: ["tool", "server", "project"], buckets: ClaudeCodeCollector.toolDurationBuckets)
        toolUnmatched = registry.counter("molly_claude_tool_calls_unmatched_total", help: "Tool calls that never got a result within toolTimeoutSeconds.", labels: ["tool"])
        toolErrors = registry.counter("molly_claude_tool_errors_total", help: "Tool results that failed (error) or were interrupted.", labels: ["tool", "server", "project", "kind"])
        turnLatency = registry.histogram("molly_claude_turn_latency_seconds", help: "Seconds from a typed prompt to the first assistant line.",
                                         labels: ["project", "model"], buckets: ClaudeCodeCollector.turnLatencyBuckets)
        permissionDecisions = registry.counter("molly_claude_permission_decisions_total", help: "Tool permission decisions: allow, deny, ask or other.", labels: ["tool", "decision"])
        sandboxedCalls = registry.counter("molly_claude_sandboxed_tool_calls_total", help: "Tool results from sandboxed runs.", labels: ["tool"])
    }

    func collect() throws {
        guard FileManager.default.fileExists(atPath: projectsDir) else {
            throw CollectorUnavailable(reason: "\(projectsDir) does not exist")
        }
        let now = self.now()
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
        expirePending(now: now)
        store.set(ClaudeCodeCollector.pendingKey, .object(pending.mapValues { $0.json }))
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
        for use in line.toolUses {
            toolCalls?.inc(labels: ["tool": use.name, "server": use.server, "project": label])
            if let id = use.id, let time = line.timestamp {
                pending[id] = PendingTool(startedAt: time, tool: use.name, project: project)
            }
        }
        recordResults(of: line, label: label)
        recordTurn(of: line, state: &state, label: label)

        let isNewMessage = line.messageId.map { state.messageIds.insert($0) } ?? true
        guard isNewMessage, line.countsAsMessage else { return }
        messages?.inc(labels: ["role": line.role.rawValue, "project": label])
        if line.isSidechain { subagentMessages?.inc() }
        if let usage = line.usage, let model = line.model { record(usage, model: model, project: label) }
    }

    private func recordResults(of line: ClaudeLine, label: String) {
        for result in line.toolResults {
            let started = pending.removeValue(forKey: result.toolUseId)
            let tool = started?.tool ?? ClaudeCodeCollector.unknownLabel
            let server = started.map { ToolUse.server(for: $0.tool) } ?? ClaudeCodeCollector.unknownLabel
            let project = started.map { projectLimiter.label($0.project) } ?? label
            if let started, let end = line.timestamp {
                let seconds = max(0, end.timeIntervalSince(started.startedAt))
                toolDuration?.observe(seconds, labels: ["tool": tool, "server": server, "project": project])
            }
            if let kind = line.interrupted ? "interrupted" : (result.isError ? "error" : nil) {
                toolErrors?.inc(labels: ["tool": tool, "server": server, "project": project, "kind": kind])
            }
            if let decision = line.permissionDecision {
                let known = decision.lowercased()
                let value = ClaudeCodeCollector.permissionDecisions.contains(known) ? known : "other"
                permissionDecisions?.inc(labels: ["tool": tool, "decision": value])
            }
            if line.sandboxed { sandboxedCalls?.inc(labels: ["tool": tool]) }
        }
    }

    private func recordTurn(of line: ClaudeLine, state: inout FileState, label: String) {
        guard !line.isSidechain, let time = line.timestamp else { return }
        switch line.role {
        case .user:
            if line.countsAsMessage { state.promptAt = time }
        case .assistant:
            guard let start = state.promptAt else { return }
            state.promptAt = nil
            guard let model = line.model, !model.hasPrefix("<") else { return }
            turnLatency?.observe(max(0, time.timeIntervalSince(start)), labels: ["project": label, "model": model])
        }
    }

    private func expirePending(now: Date) {
        let cutoff = now.addingTimeInterval(-toolTimeout)
        for (id, entry) in pending where entry.startedAt < cutoff {
            toolUnmatched?.inc(labels: ["tool": entry.tool])
            pending.removeValue(forKey: id)
        }
    }

    private func record(_ usage: TokenUsage, model: String, project: String) {
        guard !model.hasPrefix("<") else { return }
        let base = ["model": model, "project": project]
        tokens?.add(Double(usage.input), labels: base.merging(["kind": "input"]) { $1 })
        tokens?.add(Double(usage.output), labels: base.merging(["kind": "output"]) { $1 })
        tokens?.add(Double(usage.cacheRead), labels: base.merging(["kind": "cache_read"]) { $1 })
        tokens?.add(Double(usage.cacheCreation), labels: base.merging(["kind": "cache_creation"]) { $1 })
        let price = ClaudePricing.price(for: model, in: pricing)
        if price == nil, unknownModels.shouldWarn(model) { Log.warn(unknownModels.message(model: model)) }
        cost?.add(price.map { ClaudePricing.cost(usage, at: $0) } ?? 0, labels: base)
    }
}
