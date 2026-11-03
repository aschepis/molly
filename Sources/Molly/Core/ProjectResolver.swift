import Foundation

/// Decides whether a shell working directory is a project. A home folder or a
/// folder of repositories is not: only a git repository (found by walking up
/// to the nearest `.git`) or a folder under a configured root counts.
final class ProjectResolver {
    static let shared = ProjectResolver()

    static let defaultCacheTTL: TimeInterval = 300
    static let defaultCacheLimit = 512

    private struct Entry {
        let project: String?
        let expires: Date
    }

    private var roots: [String]
    private let cacheTTL: TimeInterval
    private let cacheLimit: Int
    private let now: () -> Date
    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    init(roots: [String] = [], cacheTTL: TimeInterval = ProjectResolver.defaultCacheTTL,
         cacheLimit: Int = ProjectResolver.defaultCacheLimit, now: @escaping () -> Date = Date.init) {
        self.roots = roots.map(ProjectResolver.trimmed)
        self.cacheTTL = cacheTTL
        self.cacheLimit = cacheLimit
        self.now = now
    }

    /// `collectors.projects.roots`, with `~` and `$HOME` expanded.
    static func roots(from settings: CollectorSettings) -> [String] {
        settings.strings("roots").map { Paths.expand($0) }
    }

    func setRoots(_ newRoots: [String]) {
        lock.lock()
        defer { lock.unlock() }
        roots = newRoots.map(ProjectResolver.trimmed)
        cache.removeAll()
    }

    var cachedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// The project name for a working directory, or nil when it is not one.
    func project(forCwd cwd: String) -> String? {
        let path = ProjectResolver.trimmed(cwd)
        guard !path.isEmpty else { return nil }
        let current = now()
        lock.lock()
        if let entry = cache[path], entry.expires > current {
            lock.unlock()
            return entry.project
        }
        let activeRoots = roots
        lock.unlock()

        let resolved = ProjectResolver.resolve(path, roots: activeRoots)

        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[path] = Entry(project: resolved, expires: current.addingTimeInterval(cacheTTL))
        lock.unlock()
        return resolved
    }

    private static func trimmed(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func resolve(_ path: String, roots: [String]) -> String? {
        for root in roots where path.hasPrefix(root + "/") {
            let first = path.dropFirst(root.count + 1).split(separator: "/").first
            return first.map(String.init)
        }
        guard let repo = nearestRepository(from: path) else { return nil }
        return ProjectName.normalize(path: repo)
    }

    private static func nearestRepository(from path: String) -> String? {
        var current = path
        while current.count > 1 {
            if FileManager.default.fileExists(atPath: current + "/.git") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}

enum ProjectAttribution {
    /// Reports a shell working directory only when it belongs to a project.
    static func reportShell(cwd: String, resolver: ProjectResolver = .shared,
                            tracker: ProjectTracker = .shared, at date: Date = Date()) {
        guard let project = resolver.project(forCwd: cwd) else { return }
        tracker.report(project: project, source: .shell, at: date)
    }
}
