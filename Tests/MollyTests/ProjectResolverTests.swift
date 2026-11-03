import XCTest
@testable import Molly

final class ProjectResolverTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("molly-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { [base] in if let base { try? FileManager.default.removeItem(at: base) } }
    }

    @discardableResult
    private func makeDir(_ relative: String) throws -> String {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func makeRepo(_ relative: String, gitIsFile: Bool = false) throws -> String {
        let path = try makeDir(relative)
        let marker = URL(fileURLWithPath: path).appendingPathComponent(".git")
        if gitIsFile {
            try Data("gitdir: /elsewhere".utf8).write(to: marker)
        } else {
            try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        }
        return path
    }

    func testPlainFolderIsNotAProject() throws {
        let home = try makeDir("home/me")
        let resolver = ProjectResolver()
        XCTAssertNil(resolver.project(forCwd: home))
        XCTAssertNil(resolver.project(forCwd: try makeDir("home/me/src")))
    }

    func testRepoRootAndSubdirectoryAttributeToTheRepo() throws {
        let repo = try makeRepo("home/me/src/widgets")
        let deep = try makeDir("home/me/src/widgets/Sources/Core")
        let resolver = ProjectResolver()
        XCTAssertEqual(resolver.project(forCwd: repo), "widgets")
        XCTAssertEqual(resolver.project(forCwd: deep), "widgets")
    }

    func testGitFileCountsLikeAGitFolder() throws {
        let worktree = try makeRepo("src/widgets-wt", gitIsFile: true)
        XCTAssertEqual(ProjectResolver().project(forCwd: worktree), "widgets-wt")
    }

    func testGithubLayoutKeepsOwnerAndRepoName() throws {
        let repo = try makeRepo("src/github.com/acme/widgets")
        XCTAssertEqual(ProjectResolver().project(forCwd: repo + "/docs"), "acme/widgets")
    }

    func testParentOfRepositoriesIsNotAProject() throws {
        try makeRepo("src/github.com/acme/widgets")
        let owner = try makeDir("src/github.com/acme")
        XCTAssertNil(ProjectResolver().project(forCwd: owner))
    }

    func testRootsNameTheFirstComponentUnderTheRoot() throws {
        let root = try makeDir("work")
        let nested = try makeDir("work/client-a/services/api")
        let resolver = ProjectResolver(roots: [root])
        XCTAssertEqual(resolver.project(forCwd: nested), "client-a")
        XCTAssertEqual(resolver.project(forCwd: root + "/client-b"), "client-b")
        XCTAssertNil(resolver.project(forCwd: root), "the root itself is not a project")
    }

    func testRootsTakePriorityOverARepoInsideThem() throws {
        let root = try makeDir("work")
        try makeRepo("work/client-a/api")
        XCTAssertEqual(ProjectResolver(roots: [root]).project(forCwd: root + "/client-a/api"), "client-a")
    }

    func testRootPrefixMustMatchWholeComponents() throws {
        let root = try makeDir("work")
        let sibling = try makeDir("work-old/thing")
        XCTAssertNil(ProjectResolver(roots: [root]).project(forCwd: sibling))
    }

    func testTrailingSlashesAreIgnored() throws {
        let repo = try makeRepo("src/widgets")
        let root = try makeDir("work")
        XCTAssertEqual(ProjectResolver().project(forCwd: repo + "/"), "widgets")
        XCTAssertEqual(ProjectResolver(roots: [root + "/"]).project(forCwd: root + "/a/b"), "a")
    }

    func testLookupsAreCachedUntilTheyExpire() throws {
        let dir = try makeDir("src/later")
        var clock = Date(timeIntervalSince1970: 1_000)
        let resolver = ProjectResolver(cacheTTL: 60, now: { clock })
        XCTAssertNil(resolver.project(forCwd: dir))

        try FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
        XCTAssertNil(resolver.project(forCwd: dir), "a cached answer is reused")

        clock = clock.addingTimeInterval(61)
        XCTAssertEqual(resolver.project(forCwd: dir), "later")
    }

    func testCacheIsBounded() throws {
        let resolver = ProjectResolver(cacheLimit: 3)
        for i in 0..<10 { _ = resolver.project(forCwd: base.path + "/n\(i)") }
        XCTAssertLessThanOrEqual(resolver.cachedCount, 3)
    }

    func testShellPromptOutsideAProjectDoesNotReachTheTracker() throws {
        let home = try makeDir("home/me")
        let repo = try makeRepo("home/me/src/widgets")
        let tracker = ProjectTracker()
        let resolver = ProjectResolver()
        let when = Date(timeIntervalSince1970: 5_000)
        ProjectAttribution.reportShell(cwd: home, resolver: resolver, tracker: tracker, at: when)
        ProjectAttribution.reportShell(cwd: repo, resolver: resolver, tracker: tracker, at: when)
        XCTAssertEqual(tracker.snapshot()[.shell], ["widgets": when])
    }

    func testProjectsCollectorReadsRootsAndExpandsTilde() throws {
        let settings = CollectorSettings(name: "projects", raw: ["roots": .array([.string("~/work"), .string("/srv/code")])])
        XCTAssertEqual(ProjectResolver.roots(from: settings), [Paths.expand("~/work"), "/srv/code"])
        XCTAssertEqual(ProjectResolver.roots(from: CollectorSettings(name: "projects", raw: [:])), [])
    }
}
