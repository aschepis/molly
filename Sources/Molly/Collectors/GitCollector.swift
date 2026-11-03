import Foundation

/// Pure parsers for git output. Kept separate from the collector so they can
/// be tested against fixture strings.
enum GitParsing {
    struct Status: Equatable {
        var branch: String?
        var hasUpstream = false
        var dirty = 0
        var untracked = 0
    }

    struct Commit: Equatable {
        let hash: String
        let authorTime: Int
        let email: String
    }

    static let fieldSeparator = "\u{1f}"

    /// "owner/name" from an ssh, scp-style or https remote URL; nil for local
    /// paths and anything without an owner segment.
    static func repoName(fromRemoteURL url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: Substring
        if let schemeEnd = trimmed.range(of: "://") {
            if trimmed.hasPrefix("file:") { return nil }
            let rest = trimmed[schemeEnd.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            path = rest[rest.index(after: slash)...]
        } else if let colon = trimmed.firstIndex(of: ":"),
                  !trimmed[..<colon].contains("/") {
            path = trimmed[trimmed.index(after: colon)...]
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts.suffix(2).joined(separator: "/")
    }

    /// Sums `git log --numstat` output. Binary files ("-") and header lines
    /// carrying other fields are ignored.
    static func parseNumstat(_ output: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let a = Int(fields[0]), let r = Int(fields[1]) else { continue }
            added += a
            removed += r
        }
        return (added, removed)
    }

    /// `git status --porcelain=v2 --branch`: changed (1/2) and unmerged (u)
    /// entries are dirty, "?" entries are untracked, "!" (ignored) is skipped.
    static func parseStatus(_ output: String) -> Status {
        var status = Status()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                status.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                status.hasUpstream = true
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                status.dirty += 1
            } else if line.hasPrefix("? ") {
                status.untracked += 1
            }
        }
        return status
    }

    /// Output of `git rev-list --left-right --count @{upstream}...HEAD` is
    /// "<only-upstream>\t<only-head>", i.e. behind then ahead.
    static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int)? {
        let fields = output.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard fields.count == 2, let behind = Int(fields[0]), let ahead = Int(fields[1]) else { return nil }
        return (ahead, behind)
    }

    /// Lines of `--format=%H%x1f%at%x1f%ae`; numstat lines mixed in are skipped.
    static func parseCommits(_ output: String) -> [Commit] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: fieldSeparator)
            guard fields.count == 3, let time = Int(fields[1]) else { return nil }
            return Commit(hash: fields[0], authorTime: time, email: fields[2])
        }
    }
}

/// Repositories under configured roots: commits, churn, dirtiness, sync state.
/// Only reads via read-only git commands (GIT_OPTIONAL_LOCKS=0).
final class GitCollector: Collector {
    static let reposDefaults = LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 50)
    static let branchesDefaults = LabelPolicy(enabled: true, mode: .denylist)
    let name = "git"
    let interval: TimeInterval

    static let commandTimeout: TimeInterval = 10
    static let defaultSkipDirs = ["node_modules", ".build", "vendor"]

    private let roots: [String]
    private let maxDepth: Int
    private let rescanSeconds: TimeInterval
    private let activeDays: Int
    private let skipDirs: Set<String>
    private let configuredEmails: [String]
    private let repoFilter: LabelFilter
    private let branchFilter: LabelFilter
    private let store: StateStore
    private let tracker: ProjectTracker
    private let startedAt: Date

    private var repoPaths: [String] = []
    private var lastScan: Date = .distantPast
    private var repoNames: [String: String] = [:]
    private var dirtySignatures: [String: String] = [:]
    private var myEmails: Set<String>?
    private let commitLimiter: LabelLimiter

    private var repos: Gauge?
    private var reposActive: Gauge?
    private var commitsTotal: Counter?
    private var commitsToday: Gauge?
    private var linesAdded: Gauge?
    private var linesRemoved: Gauge?
    private var dirtyFiles: Gauge?
    private var untrackedFiles: Gauge?
    private var ahead: Gauge?
    private var behind: Gauge?
    private var stashes: Gauge?
    private var lastCommit: Gauge?
    private var branchInfo: Gauge?

    private struct Observation {
        var path: String
        var name: String
        var branch: String?
        var dirty = 0
        var untracked = 0
        var ahead = 0
        var behind = 0
        var stashes = 0
        var lastCommit = 0
        var commitsToday = 0
        var added = 0
        var removed = 0
    }

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder,
         tracker: ProjectTracker = .shared, startedAt: Date = Date()) throws {
        interval = settings.interval(default: 120)
        roots = settings.strings("roots", default: ["~/src"]).map(Paths.expand)
        maxDepth = max(0, settings.int("maxDepth", default: 4))
        rescanSeconds = settings.double("rescanSeconds", default: 1800)
        activeDays = max(1, settings.int("activeDays", default: 30))
        skipDirs = Set(settings.strings("skipDirs", default: GitCollector.defaultSkipDirs))
        configuredEmails = settings.strings("authorEmails").map { $0.lowercased() }
        repoFilter = try settings.filter("repos", defaults: GitCollector.reposDefaults)
        branchFilter = try settings.filter("branches", defaults: GitCollector.branchesDefaults)
        commitLimiter = LabelLimiter(filter: repoFilter)
        store = StateStore(collector: "git", folder: stateFolder)
        self.tracker = tracker
        self.startedAt = startedAt
    }

    func start(registry: MetricsRegistry) throws {
        let repoLabel = ["repo"]
        repos = registry.gauge("molly_git_repos", help: "Git repositories found under the configured roots.")
        reposActive = registry.gauge("molly_git_repos_active", help: "Repositories with a commit or uncommitted change within activeDays.")
        commitsTotal = registry.counter("molly_git_commits_total", help: "Commits seen since Molly started, by author kind.", labels: ["repo", "author"])
        commitsToday = registry.gauge("molly_git_commits_today", help: "Commits authored today.", labels: repoLabel)
        linesAdded = registry.gauge("molly_git_lines_added_today", help: "Lines added by today's commits.", labels: repoLabel)
        linesRemoved = registry.gauge("molly_git_lines_removed_today", help: "Lines removed by today's commits.", labels: repoLabel)
        dirtyFiles = registry.gauge("molly_git_dirty_files", help: "Files with uncommitted changes.", labels: repoLabel)
        untrackedFiles = registry.gauge("molly_git_untracked_files", help: "Untracked files.", labels: repoLabel)
        ahead = registry.gauge("molly_git_ahead", help: "Commits ahead of the upstream branch.", labels: repoLabel)
        behind = registry.gauge("molly_git_behind", help: "Commits behind the upstream branch.", labels: repoLabel)
        stashes = registry.gauge("molly_git_stashes", help: "Stash entries.", labels: repoLabel)
        lastCommit = registry.gauge("molly_git_last_commit_timestamp_seconds", help: "Unix time of the newest commit on any ref.", labels: repoLabel)
        branchInfo = registry.gauge("molly_git_branch_info", help: "Current branch of each active repository (always 1).", labels: ["repo", "branch"])
    }

    func collect() throws {
        guard let gitPath = Shell.which("git") else {
            throw CollectorUnavailable(reason: "git not found")
        }
        let now = Date()
        if now.timeIntervalSince(lastScan) >= rescanSeconds {
            repoPaths = GitCollector.discoverRepos(roots: roots, maxDepth: maxDepth, skipDirs: skipDirs)
            lastScan = now
            Log.debug("git: discovered \(repoPaths.count) repositories")
        }
        if myEmails == nil { myEmails = Set(configuredEmails + globalEmail(gitPath)) }

        // Reads run in parallel and touch no shared state; results are applied serially.
        let fetched = fetchAll(git: gitPath, now: now)
        var observations: [Observation] = []
        for repo in fetched {
            repoNames[repo.observation.path] = repo.observation.name
            apply(repo)
            observations.append(repo.observation)
        }
        publish(observations, total: repoPaths.count)
        do { try store.save() } catch { Log.warn("git: cannot save state: \(error)") }
    }

    // MARK: - Discovery

    static func discoverRepos(roots: [String], maxDepth: Int, skipDirs: Set<String>) -> [String] {
        var found: [String] = []
        let fm = FileManager.default
        func walk(_ dir: String, depth: Int) {
            if fm.fileExists(atPath: dir + "/.git") {
                found.append(dir)
                return
            }
            guard depth < maxDepth, let children = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for child in children.sorted() where !skipDirs.contains(child) && !child.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                let childPath = dir + "/" + child
                if fm.fileExists(atPath: childPath, isDirectory: &isDirectory), isDirectory.boolValue {
                    walk(childPath, depth: depth + 1)
                }
            }
        }
        for root in roots { walk((root as NSString).standardizingPath, depth: 0) }
        return found
    }

    // MARK: - Per-repo inspection

    private func git(_ gitPath: String, _ arguments: [String], in directory: String?) throws -> String? {
        let result = try Shell.run(gitPath, arguments, timeout: GitCollector.commandTimeout,
                                   currentDirectory: directory, environment: GitEnvironment.readOnly)
        return result.succeeded ? result.stdout : nil
    }

    private func globalEmail(_ gitPath: String) -> [String] {
        guard let out = try? git(gitPath, ["config", "--global", "user.email"], in: nil) else { return [] }
        let email = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return email.isEmpty ? [] : [email]
    }

    private func name(of path: String, git gitPath: String) throws -> String {
        if let cached = repoNames[path] { return cached }
        let remote = try git(gitPath, ["remote", "get-url", "origin"], in: path)
        return remote.flatMap(GitParsing.repoName(fromRemoteURL:)) ?? (path as NSString).lastPathComponent
    }

    private struct Fetched {
        var observation: Observation
        var cursor: Int
        var freshCommits: [GitParsing.Commit]
    }

    private static let maxParallelRepos = 4

    private func fetchAll(git gitPath: String, now: Date) -> [Fetched] {
        let paths = repoPaths
        var results = [Fetched?](repeating: nil, count: paths.count)
        var next = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: min(GitCollector.maxParallelRepos, max(1, paths.count))) { _ in
            while true {
                lock.lock()
                let index = next
                next += 1
                lock.unlock()
                guard index < paths.count else { return }
                let fetched = fetch(paths[index], git: gitPath, now: now)
                lock.lock()
                results[index] = fetched
                lock.unlock()
            }
        }
        return results.compactMap { $0 }
    }

    private func fetch(_ path: String, git gitPath: String, now: Date) -> Fetched? {
        do {
            return try inspect(path, git: gitPath, now: now)
        } catch ShellError.timedOut {
            Log.debug("git: \(path) timed out, skipped")
        } catch {
            Log.debug("git: \(path): \(error)")
        }
        return nil
    }

    private func inspect(_ path: String, git gitPath: String, now: Date) throws -> Fetched? {
        let activeSince = Int(now.timeIntervalSince1970) - activeDays * 86400
        let newest = try git(gitPath, ["log", "-1", "--all", "--format=%at"], in: path)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard let statusText = try git(gitPath, ["status", "--porcelain=v2", "--branch"], in: path) else { return nil }
        let status = GitParsing.parseStatus(statusText)
        let isDirty = status.dirty + status.untracked > 0
        guard newest >= activeSince || isDirty else { return nil }

        var observation = Observation(path: path, name: try name(of: path, git: gitPath))
        observation.branch = status.branch
        observation.dirty = status.dirty
        observation.untracked = status.untracked
        observation.lastCommit = newest
        if let stash = try git(gitPath, ["stash", "list"], in: path) {
            observation.stashes = stash.split(separator: "\n").count
        }
        if status.hasUpstream,
           let counts = try git(gitPath, ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], in: path),
           let parsed = GitParsing.parseAheadBehind(counts) {
            observation.ahead = parsed.ahead
            observation.behind = parsed.behind
        }
        let cursor = store.int(cursorKey(path)) ?? Int(startedAt.timeIntervalSince1970)
        let fresh = try newCommits(path, newest: newest, cursor: cursor, git: gitPath)
        try measureToday(&observation, now: now, git: gitPath)
        return Fetched(observation: observation, cursor: cursor, freshCommits: fresh)
    }

    private func cursorKey(_ path: String) -> String { "cursor:" + path }

    /// Commits by author time strictly after the cursor; `--since` filters on
    /// committer time, which is never earlier, so it cannot hide a candidate.
    private func newCommits(_ path: String, newest: Int, cursor: Int, git gitPath: String) throws -> [GitParsing.Commit] {
        guard newest > cursor else { return [] }
        let output = try git(gitPath, ["log", "--all", "--since=\(cursor + 1)",
                                       "--format=%H%x1f%at%x1f%ae"], in: path) ?? ""
        return GitParsing.parseCommits(output).filter { $0.authorTime > cursor }
    }

    private func apply(_ fetched: Fetched) {
        let observation = fetched.observation
        let repo = commitLimiter.label(observation.name)
        let project = ProjectName.normalize(path: observation.path)
        var counts: [String: Double] = ["me": 0, "other": 0]
        for commit in fetched.freshCommits {
            counts[myEmails?.contains(commit.email.lowercased()) == true ? "me" : "other", default: 0] += 1
        }
        for (author, n) in counts { commitsTotal?.add(n, labels: ["repo": repo, "author": author]) }

        let newestSeen = fetched.freshCommits.map(\.authorTime).max()
        store.set(cursorKey(observation.path), newestSeen ?? fetched.cursor)
        if let newestSeen {
            tracker.report(project: project, source: .git, at: Date(timeIntervalSince1970: Double(newestSeen)))
        }
        reportActivity(observation)
    }

    private func measureToday(_ observation: inout Observation, now: Date, git gitPath: String) throws {
        let midnight = Int(Clock.startOfToday(now: now).timeIntervalSince1970)
        guard observation.lastCommit >= midnight else { return }
        let output = try git(gitPath, ["log", "--all", "--since=\(midnight)", "--numstat",
                                       "--format=%H%x1f%at%x1f%ae"], in: observation.path) ?? ""
        observation.commitsToday = GitParsing.parseCommits(output).filter { $0.authorTime >= midnight }.count
        let churn = GitParsing.parseNumstat(output)
        observation.added = churn.added
        observation.removed = churn.removed
    }

    private func reportActivity(_ observation: Observation) {
        let signature = "\(observation.dirty)/\(observation.untracked)"
        let previous = dirtySignatures.updateValue(signature, forKey: observation.path)
        if let previous, previous != signature {
            tracker.report(project: ProjectName.normalize(path: observation.path), source: .git)
        }
    }

    // MARK: - Publishing

    private func publish(_ all: [Observation], total: Int) {
        repos?.set(total)
        reposActive?.set(all.count)

        var shown = all.sorted { $0.lastCommit > $1.lastCommit }
        if repoFilter.enabled, repoFilter.maxCardinality > 0 { shown = Array(shown.prefix(repoFilter.maxCardinality)) }

        func fill(_ gauge: Gauge?, combine: (Double, Double) -> Double = (+), _ value: (Observation) -> Int) {
            var byLabel: [String: Double] = [:]
            for o in shown {
                let label = repoFilter.label(o.name)
                byLabel[label] = byLabel[label].map { combine($0, Double(value(o))) } ?? Double(value(o))
            }
            gauge?.replaceAll(byLabel, label: "repo")
        }
        fill(commitsToday) { $0.commitsToday }
        fill(linesAdded) { $0.added }
        fill(linesRemoved) { $0.removed }
        fill(dirtyFiles) { $0.dirty }
        fill(untrackedFiles) { $0.untracked }
        fill(ahead) { $0.ahead }
        fill(behind) { $0.behind }
        fill(stashes) { $0.stashes }
        fill(lastCommit, combine: max) { $0.lastCommit }

        branchInfo?.reset()
        guard branchFilter.enabled else { return }
        for o in shown {
            guard let branch = o.branch else { continue }
            branchInfo?.set(1, labels: ["repo": repoFilter.label(o.name), "branch": branchFilter.label(branch)])
        }
    }
}
