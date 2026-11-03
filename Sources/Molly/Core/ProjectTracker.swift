import Foundation

enum ProjectSource: String, CaseIterable {
    case git, claude, shell
}

enum ProjectName {
    /// "owner/repo" for anything under .../github.com/owner/repo, otherwise the
    /// last path component. Shared by every collector that reports projects so
    /// the same work never appears under two names.
    static func normalize(path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(of: "github.com"), parts.count > i + 2 {
            return "\(parts[i + 1])/\(parts[i + 2])"
        }
        return parts.last ?? path
    }

    /// Claude Code encodes a cwd as its path with "/" replaced by "-". The
    /// encoding is lossy (real dashes are indistinguishable), so this is only
    /// a fallback for session lines that carry no cwd.
    static func decodeClaudeDirectory(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: "/")
    }
}

/// Collectors report "something happened in project X" here; the `projects`
/// collector publishes the union. The shared instance is process-wide.
final class ProjectTracker {
    static let shared = ProjectTracker()

    private var lastActivity: [ProjectSource: [String: Date]] = [:]
    private let lock = NSLock()

    init() {}

    func report(project: String, source: ProjectSource, at date: Date = Date()) {
        guard !project.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if let existing = lastActivity[source]?[project], existing >= date { return }
        lastActivity[source, default: [:]][project] = date
    }

    func snapshot() -> [ProjectSource: [String: Date]] {
        lock.lock()
        defer { lock.unlock() }
        return lastActivity
    }
}
