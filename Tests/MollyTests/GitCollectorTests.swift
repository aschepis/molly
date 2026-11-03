import XCTest
@testable import Molly

final class GitParsingTests: XCTestCase {
    func testRepoNameFromRemoteURLs() {
        XCTAssertEqual(GitParsing.repoName(fromRemoteURL: "git@github.com:acme/widgets.git"), "acme/widgets")
        XCTAssertEqual(GitParsing.repoName(fromRemoteURL: "https://github.com/acme/widgets.git\n"), "acme/widgets")
        XCTAssertEqual(GitParsing.repoName(fromRemoteURL: "https://github.com/acme/widgets"), "acme/widgets")
        XCTAssertEqual(GitParsing.repoName(fromRemoteURL: "ssh://git@github.com/acme/widgets.git"), "acme/widgets")
        XCTAssertEqual(GitParsing.repoName(fromRemoteURL: "https://user:tok@gitlab.com/group/sub/widgets.git"), "sub/widgets")
        XCTAssertEqual(GitParsing.repoName(fromRemoteURL: "ssh://git@host:2222/acme/widgets.git"), "acme/widgets")
        XCTAssertNil(GitParsing.repoName(fromRemoteURL: "/Users/me/remotes/widgets.git"))
        XCTAssertNil(GitParsing.repoName(fromRemoteURL: "file:///Users/me/widgets.git"))
        XCTAssertNil(GitParsing.repoName(fromRemoteURL: "https://example.com/widgets.git"))
        XCTAssertNil(GitParsing.repoName(fromRemoteURL: ""))
    }

    func testNumstatSumsAndSkipsBinaryAndHeaders() {
        let output = """
        abc\u{1f}1700000000\u{1f}me@example.com

        10\t2\tSources/a.swift
        -\t-\tlogo.png
        3\t0\tdir/{old => new}/b.swift

        def\u{1f}1700000100\u{1f}you@example.com

        1\t1\tREADME.md
        """
        let totals = GitParsing.parseNumstat(output)
        XCTAssertEqual(totals.added, 14)
        XCTAssertEqual(totals.removed, 3)
        XCTAssertEqual(GitParsing.parseNumstat("").added, 0)
    }

    func testStatusPorcelainV2() {
        let output = """
        # branch.oid 0123456789abcdef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +1 -0
        1 .M N... 100644 100644 100644 aaa bbb Sources/a.swift
        1 M. N... 100644 100644 100644 aaa bbb Sources/b.swift
        2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.swift
        ? notes.txt
        ? scratch/
        ! build/
        """
        let status = GitParsing.parseStatus(output)
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.hasUpstream)
        XCTAssertEqual(status.dirty, 4)
        XCTAssertEqual(status.untracked, 2)
    }

    func testStatusWithoutUpstreamAndDetachedHead() {
        let status = GitParsing.parseStatus("# branch.oid abc\n# branch.head (detached)\n")
        XCTAssertEqual(status.branch, "(detached)")
        XCTAssertFalse(status.hasUpstream)
        XCTAssertEqual(status.dirty + status.untracked, 0)
    }

    func testAheadBehind() throws {
        // left side is upstream-only commits (behind), right side is HEAD-only (ahead)
        let counts = try XCTUnwrap(GitParsing.parseAheadBehind("2\t5\n"))
        XCTAssertEqual(counts.behind, 2)
        XCTAssertEqual(counts.ahead, 5)
        XCTAssertNil(GitParsing.parseAheadBehind(""))
        XCTAssertNil(GitParsing.parseAheadBehind("fatal: no upstream"))
    }

    func testParseCommitsIgnoresNumstatLines() {
        let output = "abc\u{1f}1700000000\u{1f}Me@Example.com\n\n1\t2\tfile\n"
        XCTAssertEqual(GitParsing.parseCommits(output), [GitParsing.Commit(hash: "abc", authorTime: 1_700_000_000, email: "Me@Example.com")])
    }
}

final class GitCollectorTests: TempFolderTestCase {
    private let me = "me@example.com"

    @discardableResult
    private func run(_ arguments: [String], in directory: URL, date: Date? = nil, author: String? = nil) throws -> String {
        var env = ProcessInfo.processInfo.environment
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            env["GIT_AUTHOR_DATE"] = stamp
            env["GIT_COMMITTER_DATE"] = stamp
        }
        let email = author ?? me
        env["GIT_AUTHOR_NAME"] = "Tester"
        env["GIT_AUTHOR_EMAIL"] = email
        env["GIT_COMMITTER_NAME"] = "Tester"
        env["GIT_COMMITTER_EMAIL"] = email
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        let result = try Shell.run("/usr/bin/git", arguments, currentDirectory: directory.path, environment: env)
        XCTAssertTrue(result.succeeded, "git \(arguments): \(result.stderr)")
        return result.stdout
    }

    private func makeRepo(in root: URL, named name: String = "widgets") throws -> URL {
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"], in: repo)
        try "seed\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "seed"], in: repo, date: Date().addingTimeInterval(-3 * 86400))
        return repo
    }

    private func makeCollector(root: URL, state: URL, extra: [String: JSONValue] = [:], tracker: ProjectTracker = ProjectTracker()) throws -> (GitCollector, MetricsRegistry) {
        var raw: [String: JSONValue] = ["roots": strings([root.path]), "authorEmails": strings([me])]
        raw.merge(extra) { $1 }
        let collector = try GitCollector(settings: settings("git", raw), stateFolder: state, tracker: tracker,
                                         startedAt: Date().addingTimeInterval(-30))
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        return (collector, registry)
    }

    func testDiscoveryHonoursDepthAndSkipList() throws {
        let root = makeTempFolder()
        let fm = FileManager.default
        for path in ["a/b/c/.git", "x/node_modules/pkg/.git", "deep/1/2/3/4/.git", "top/.git"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let found = GitCollector.discoverRepos(roots: [root.path], maxDepth: 4, skipDirs: ["node_modules"])
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found[0].hasSuffix("/a/b/c"))
        XCTAssertTrue(found[1].hasSuffix("/top"))
    }

    func testCommitsAreCountedIncrementallyAndAcrossRestart() throws {
        let root = makeTempFolder()
        let state = makeTempFolder()
        let repo = try makeRepo(in: root)
        try run(["remote", "add", "origin", "git@github.com:acme/widgets.git"], in: repo)

        var (collector, registry) = try makeCollector(root: root, state: state)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_git_repos"), 1)
        XCTAssertEqual(value(registry, "molly_git_repos_active"), 1)
        XCTAssertEqual(value(registry, "molly_git_commits_total", ["repo": "acme/widgets", "author": "me"]), 0)
        XCTAssertEqual(value(registry, "molly_git_branch_info", ["repo": "acme/widgets", "branch": "main"]), 1)

        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "mine"], in: repo, date: Date())
        try run(["commit", "-q", "--allow-empty", "-m", "theirs"], in: repo, date: Date(), author: "other@example.com")
        try "untracked\n".write(to: repo.appendingPathComponent("u.txt"), atomically: true, encoding: .utf8)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_git_commits_total", ["repo": "acme/widgets", "author": "me"]), 1)
        XCTAssertEqual(value(registry, "molly_git_commits_total", ["repo": "acme/widgets", "author": "other"]), 1)
        XCTAssertEqual(value(registry, "molly_git_commits_today", ["repo": "acme/widgets"]), 2)
        XCTAssertEqual(value(registry, "molly_git_lines_added_today", ["repo": "acme/widgets"]), 2)
        XCTAssertEqual(value(registry, "molly_git_untracked_files", ["repo": "acme/widgets"]), 1)

        try collector.collect()
        XCTAssertEqual(value(registry, "molly_git_commits_total", ["repo": "acme/widgets", "author": "me"]), 1, "no double counting")

        // A fresh collector with the same state folder resumes from the saved cursor.
        try run(["commit", "-q", "--allow-empty", "-m", "later"], in: repo, date: Date().addingTimeInterval(5))
        (collector, registry) = try makeCollector(root: root, state: state)
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_git_commits_total", ["repo": "acme/widgets", "author": "me"]), 1)
    }

    func testRepoPolicyDisabledRedactsLabelButKeepsAggregates() throws {
        let root = makeTempFolder()
        _ = try makeRepo(in: root)
        let (collector, registry) = try makeCollector(root: root, state: makeTempFolder(),
                                                      extra: ["repos": .object(["enabled": .bool(false)])])
        try collector.collect()
        XCTAssertEqual(value(registry, "molly_git_repos_active"), 1)
        XCTAssertNotNil(value(registry, "molly_git_dirty_files", ["repo": "redacted"]))
        XCTAssertFalse(registry.render().contains("widgets"))
    }

    func testNewCommitReportsProjectActivity() throws {
        let root = makeTempFolder()
        let repo = try makeRepo(in: root)
        let tracker = ProjectTracker()
        let (collector, _) = try makeCollector(root: root, state: makeTempFolder(), tracker: tracker)
        try collector.collect()
        XCTAssertNil(tracker.snapshot()[.git])
        try run(["commit", "-q", "--allow-empty", "-m", "x"], in: repo, date: Date())
        try collector.collect()
        XCTAssertNotNil(tracker.snapshot()[.git]?["widgets"])
    }
}
