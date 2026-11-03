import Foundation

/// Pure parsing of shell history files and command lines. Command text is
/// only ever held in memory long enough to extract a name and hosts.
enum ShellParsing {
    struct Entry: Equatable {
        var command: String
        var timestamp: Int?
    }

    struct Analysis: Equatable {
        var name: String?
        var hosts: [String]
    }

    // MARK: History formats

    /// zsh extended history: ": <epoch>:<duration>;<command>", multi-line
    /// commands continue on lines after a trailing backslash. Feed it batches;
    /// an unfinished multi-line command is held until the next batch.
    struct ZshParser {
        private var pending: Entry?
        private static let header = try! NSRegularExpression(pattern: "^: (\\d+):\\d+;")

        mutating func feed(_ lines: [String]) -> [Entry] {
            var done: [Entry] = []
            for line in lines {
                if var open = pending {
                    open.command += "\n" + line
                    if line.hasSuffix("\\") {
                        pending = open
                    } else {
                        pending = nil
                        done.append(open)
                    }
                    continue
                }
                let entry = ZshParser.entry(from: line)
                if line.hasSuffix("\\") {
                    pending = entry
                } else {
                    done.append(entry)
                }
            }
            return done
        }

        private static func entry(from line: String) -> Entry {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = header.firstMatch(in: line, range: range),
                  let epoch = Range(match.range(at: 1), in: line),
                  let whole = Range(match.range, in: line) else {
                return Entry(command: line, timestamp: nil)
            }
            return Entry(command: String(line[whole.upperBound...]), timestamp: Int(line[epoch]))
        }
    }

    /// bash: one command per line; "#<epoch>" lines appear only with HISTTIMEFORMAT.
    static func parseBash(_ lines: [String]) -> [Entry] {
        var entries: [Entry] = []
        var stamp: Int?
        for line in lines {
            if line.hasPrefix("#"), line.count > 1, let epoch = Int(line.dropFirst()) {
                stamp = epoch
            } else if !line.isEmpty {
                entries.append(Entry(command: line, timestamp: stamp))
                stamp = nil
            }
        }
        return entries
    }

    /// fish: "- cmd: <command>" followed by "  when: <epoch>" (and "paths").
    static func parseFish(_ lines: [String]) -> [Entry] {
        var entries: [Entry] = []
        for line in lines {
            if line.hasPrefix("- cmd: ") {
                entries.append(Entry(command: String(line.dropFirst("- cmd: ".count)), timestamp: nil))
            } else if line.hasPrefix("  when: "), !entries.isEmpty, entries[entries.count - 1].timestamp == nil {
                entries[entries.count - 1].timestamp = Int(line.dropFirst("  when: ".count))
            }
        }
        return entries
    }

    // MARK: Command lines

    /// Splits a command line into segments at unquoted `|`, `||`, `|&`, `&&`,
    /// `&`, `;` and newlines, and each segment into words with quotes removed.
    static func segments(_ command: String) -> [[String]] {
        var result: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        let chars = Array(command)
        var i = 0

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { result.append(words) }
            words = []
        }

        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\", q == "\"", i + 1 < chars.count {
                    word.append(chars[i + 1])
                    i += 1
                } else {
                    word.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                inWord = true
            case "\\":
                if i + 1 < chars.count {
                    let isLineContinuation = chars[i + 1] == "\n"
                    if !isLineContinuation {
                        word.append(chars[i + 1])
                        inWord = true
                    }
                    i += 1
                }
            case " ", "\t":
                endWord()
            case "|":
                endSegment()
                if i + 1 < chars.count, chars[i + 1] == "|" || chars[i + 1] == "&" { i += 1 }
            case ";", "\n":
                endSegment()
            case "&":
                let isRedirect = (i > 0 && (chars[i - 1] == ">" || chars[i - 1] == "<"))
                    || (i + 1 < chars.count && chars[i + 1] == ">")
                if isRedirect {
                    word.append(c)
                    inWord = true
                } else {
                    endSegment()
                    if i + 1 < chars.count, chars[i + 1] == "&" { i += 1 }
                }
            case "#" where !inWord:
                endSegment()
                return result
            default:
                word.append(c)
                inWord = true
            }
            i += 1
        }
        endSegment()
        return result
    }

    private static let sudoFlagsWithValue: Set<String> = ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U"]
    private static let envAssignment = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*=")

    /// Drops `FOO=bar`, `sudo [flags]`, `time` and `nohup` from the front of a segment.
    static func stripPrefixes(_ words: [String]) -> [String] {
        var rest = words[...]
        while let first = rest.first {
            if envAssignment.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) != nil {
                rest = rest.dropFirst()
            } else if first == "sudo" {
                rest = rest.dropFirst()
                while let flag = rest.first, flag.hasPrefix("-") {
                    rest = rest.dropFirst(sudoFlagsWithValue.contains(flag) ? 2 : 1)
                }
            } else if first == "time" || first == "nohup" {
                rest = rest.dropFirst()
            } else {
                break
            }
        }
        return Array(rest)
    }

    static func basename(_ word: String) -> String? {
        let name = word.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The whole line counts as one command whose name comes from its first
    /// segment. Hosts are collected from every segment when `wantHosts`.
    static func analyze(_ command: String, wantHosts: Bool) -> Analysis {
        let parsed = segments(command).map(stripPrefixes).filter { !$0.isEmpty }
        let name = parsed.first?.first.flatMap(basename)
        guard wantHosts else { return Analysis(name: name, hosts: []) }
        var hosts: [String] = []
        func add(_ host: String?) {
            if let host, !hosts.contains(host) { hosts.append(host) }
        }
        for words in parsed {
            for word in words { urlHosts(in: word).forEach { add($0) } }
            if let tool = basename(words[0])?.lowercased() { add(hostArgument(tool: tool, arguments: Array(words.dropFirst()))) }
        }
        return Analysis(name: name, hosts: hosts)
    }

    // MARK: Hosts

    private static let urlPattern = try! NSRegularExpression(
        pattern: "https?://(?:[^/\\s@]*@)?(\\[[0-9a-fA-F:]+\\]|[A-Za-z0-9][A-Za-z0-9._-]*)")

    static func urlHosts(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return urlPattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { normalizeHost(String(text[$0])) }
        }
    }

    private static let valueFlagsByTool: [String: Set<String>] = {
        let scp: Set<String> = ["-i", "-P", "-o", "-F", "-J", "-c", "-l", "-S"]
        return [
            "ssh": ["-i", "-p", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-E", "-e", "-I", "-m", "-O", "-Q", "-S", "-W", "-w"],
            "scp": scp,
            "sftp": scp.union(["-b"]),
            "curl": ["-H", "-d", "-o", "-X", "-u", "-A", "-e", "-b", "-c", "-F", "-m", "-w", "-T", "-x", "-K", "-r", "-z", "-E",
                     "--header", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--output", "--request", "--user",
                     "--user-agent", "--max-time", "--cookie", "--form", "--proxy", "--connect-timeout", "--cert", "--key",
                     "--cacert", "--retry", "--referer"],
            "wget": ["-O", "-o", "-P", "-t", "-T", "-U", "-e", "-i", "-w", "-a", "-B", "--header", "--output-document",
                     "--user-agent", "--tries", "--timeout"],
            "ping": ["-c", "-i", "-W", "-w", "-t", "-s", "-I", "-m", "-M", "-S", "-p", "-Q", "-T"],
            "nc": ["-p", "-w", "-s", "-i", "-T", "-x", "-X", "-I", "-O", "-P", "-q", "-m"],
            "telnet": ["-b", "-l", "-e", "-S"],
            "dig": ["-b", "-c", "-f", "-k", "-m", "-p", "-q", "-t", "-x", "-y"],
            "nslookup": [],
            "host": ["-t", "-W", "-c", "-N", "-R", "-m"],
        ]
    }()

    /// First non-flag argument of a network tool, minus user@ and :port.
    /// For scp/sftp it is the first `host:path` operand.
    static func hostArgument(tool: String, arguments: [String]) -> String? {
        guard let valueFlags = valueFlagsByTool[tool] else { return nil }
        var index = 0
        var flagsEnded = false
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            if !flagsEnded, arg == "--" { flagsEnded = true; continue }
            if !flagsEnded, arg.hasPrefix("-"), arg.count > 1 {
                if valueFlags.contains(arg) { index += 1 }
                continue
            }
            if arg.hasPrefix("@") { continue }
            if tool == "scp" || tool == "sftp" {
                guard let colon = arg.firstIndex(of: ":"), !arg.hasPrefix("/"), !arg.hasPrefix(".") else {
                    if tool == "sftp" { return normalizeHost(arg) }
                    continue
                }
                if arg.contains("://") { return normalizeHost(arg) }
                return normalizeHost(String(arg[..<colon]))
            }
            return normalizeHost(arg)
        }
        return nil
    }

    /// Reduces "user@Host:22", "https://host/path" or "[::1]:80" to a bare
    /// lowercase host, or nil when the text does not look like one.
    static func normalizeHost(_ raw: String) -> String? {
        var text = raw
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let end = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { text = String(text[..<end]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        while text.hasSuffix(".") { text.removeLast() }
        text = text.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-:")
        guard !text.isEmpty, !text.hasPrefix("-"), text.rangeOfCharacter(from: allowed.inverted) == nil,
              text.contains(where: { $0.isLetter || $0 == "." || $0 == ":" }) else { return nil }
        return text
    }
}

/// Shell history: how many commands, optionally which programs and which
/// network hosts. Arguments and command text are never stored or exported.
final class ShellCollector: Collector {
    let name = "shell"
    let interval: TimeInterval

    private enum Format { case zsh, bash, fish }

    private struct Source {
        let shell: String
        let format: Format
        let path: String
    }

    private let sources: [Source]
    private let commandLimiter: LabelLimiter
    private let hostLimiter: LabelLimiter
    private let store: StateStore
    private let offsets: OffsetTable
    private let startedAt: Date
    private var zshParsers: [String: ShellParsing.ZshParser] = [:]
    private var lastTimestamps: [String: Int] = [:]
    private var seeded = Set<String>()
    private var today: [String: Int] = [:]
    private var todayStart: Date = .distantPast

    private var commandsTotal: Counter?
    private var commandsToday: Gauge?
    private var commandNames: Counter?
    private var networkHosts: Counter?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, startedAt: Date = Date()) throws {
        interval = settings.interval(default: 60)
        let enabledShells = Set(settings.strings("shells", default: ["zsh", "bash", "fish"]))
        let candidates = [
            Source(shell: "zsh", format: .zsh, path: Paths.expand(settings.string("zshHistory", default: "~/.zsh_history"))),
            Source(shell: "bash", format: .bash, path: Paths.expand(settings.string("bashHistory", default: "~/.bash_history"))),
            Source(shell: "fish", format: .fish, path: Paths.expand(settings.string("fishHistory", default: "~/.local/share/fish/fish_history"))),
        ]
        sources = candidates.filter { enabledShells.contains($0.shell) }
        commandLimiter = LabelLimiter(filter: try settings.filter("commands", defaults: LabelPolicy(enabled: false, mode: .allowlist, maxCardinality: 50)))
        hostLimiter = LabelLimiter(filter: try settings.filter("hosts", defaults: LabelPolicy(enabled: false, mode: .denylist, maxCardinality: 50)))
        store = StateStore(collector: "shell", folder: stateFolder)
        offsets = OffsetTable(store: store)
        self.startedAt = startedAt
    }

    func start(registry: MetricsRegistry) throws {
        commandsTotal = registry.counter("molly_shell_commands_total", help: "Shell commands run (pipelines and && chains count once).", labels: ["shell"])
        commandsToday = registry.gauge("molly_shell_commands_today", help: "Shell commands run today.", labels: ["shell"])
        commandNames = registry.counter("molly_shell_command_names_total", help: "Commands by program name; off unless the commands policy is enabled.", labels: ["command"])
        networkHosts = registry.counter("molly_shell_network_hosts_total", help: "Network hosts named in commands; off unless the hosts policy is enabled.", labels: ["remote_host"])
    }

    func collect() throws {
        let present = sources.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !present.isEmpty else {
            throw CollectorUnavailable(reason: "no shell history file found")
        }
        let midnight = Clock.startOfToday()
        if midnight != todayStart {
            today = [:]
            todayStart = midnight
            seeded = []
        }
        for source in present {
            do {
                try collect(source, midnight: midnight)
            } catch {
                Log.debug("shell: \(source.shell) history: \(error)")
            }
        }
        for source in present { commandsToday?.set(today[source.shell] ?? 0, labels: ["shell": source.shell]) }
        offsets.save()
        do { try store.save() } catch { Log.warn("shell: cannot save state: \(error)") }
    }

    private func collect(_ source: Source, midnight: Date) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let baseline = lastTimestamps[source.shell] ?? store.int("lastTs:" + source.shell) ?? Int(startedAt.timeIntervalSince1970)
        lastTimestamps[source.shell] = baseline

        if !seeded.contains(source.shell) {
            seeded.insert(source.shell)
            try seedToday(source, midnight: Int(midnight.timeIntervalSince1970), before: baseline)
        }
        let offset = offsets.offset(for: source.path) ?? FileTail.initialOffset(
            size: size, created: attributes[.creationDate] as? Date,
            modified: attributes[.modificationDate] as? Date, startedAt: startedAt)
        let chunk = try FileTail.read(path: source.path, from: offset)
        offsets.set(chunk.offset, for: source.path)
        count(entries(from: chunk.lines, source: source), source: source, baseline: baseline)
    }

    private func entries(from lines: [String], source: Source) -> [ShellParsing.Entry] {
        switch source.format {
        case .zsh:
            var parser = zshParsers[source.shell] ?? ShellParsing.ZshParser()
            defer { zshParsers[source.shell] = parser }
            return parser.feed(lines)
        case .bash: return ShellParsing.parseBash(lines)
        case .fish: return ShellParsing.parseFish(lines)
        }
    }

    /// Entries older than the baseline predate this run and were not counted
    /// by any counter, so they only feed the "today" gauge.
    private func seedToday(_ source: Source, midnight: Int, before baseline: Int) throws {
        guard source.format != .bash else { return }
        let chunk = try FileTail.read(path: source.path, from: 0)
        var parser = ShellParsing.ZshParser()
        let all = source.format == .zsh ? parser.feed(chunk.lines) : ShellParsing.parseFish(chunk.lines)
        let earlier = all.filter { entry in entry.timestamp.map { $0 >= midnight && $0 < baseline } ?? false }
        today[source.shell, default: 0] += earlier.count
    }

    private func count(_ entries: [ShellParsing.Entry], source: Source, baseline: Int) {
        let fresh = entries.filter { $0.timestamp.map { $0 >= baseline } ?? true }
        commandsTotal?.add(Double(fresh.count), labels: ["shell": source.shell])
        today[source.shell, default: 0] += fresh.count
        if let newest = fresh.compactMap(\.timestamp).max() {
            lastTimestamps[source.shell] = max(newest, lastTimestamps[source.shell] ?? 0)
            store.set("lastTs:" + source.shell, lastTimestamps[source.shell] ?? newest)
        }
        guard commandLimiter.enabled || hostLimiter.enabled else { return }
        for entry in fresh {
            let analysis = ShellParsing.analyze(entry.command, wantHosts: hostLimiter.enabled)
            if commandLimiter.enabled, let name = analysis.name {
                commandNames?.inc(labels: ["command": commandLimiter.label(name)])
            }
            if hostLimiter.enabled {
                for host in analysis.hosts { networkHosts?.inc(labels: ["remote_host": hostLimiter.label(host)]) }
            }
        }
    }
}
