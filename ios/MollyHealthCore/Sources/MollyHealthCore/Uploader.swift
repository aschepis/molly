import Foundation

public struct UploadItem: Equatable, Sendable {
    public let date: String
    public let body: Data

    public init(date: String, body: Data) {
        self.date = date
        self.body = body
    }
}

public enum UploadResult: Equatable, Sendable {
    case sent(PostReply)
    case failed(UploadFailure)
    /// Skipped because a post went out less than the debounce interval ago.
    case debounced
}

/// Every post goes through here, one at a time, so background deliveries and
/// "Send now" cannot interleave.
public actor Uploader {
    public static let debounceInterval: TimeInterval = 5 * 60

    private let session: HTTPSession
    private let now: @Sendable () -> Date
    private let debounce: TimeInterval
    private var lastAttempt: Date?
    private var tail: Task<Void, Never>?

    public init(session: HTTPSession, debounce: TimeInterval = Uploader.debounceInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.debounce = debounce
        self.now = now
    }

    /// Posts the items in order and stops at the first failure that would repeat.
    /// The result lists only the items that were tried (or all of them when debounced).
    public func submit(_ items: [UploadItem], to server: ServerConfig, force: Bool) async -> [(date: String, result: UploadResult)] {
        let previous = tail
        let job = Task { () -> [(date: String, result: UploadResult)] in
            await previous?.value
            return await self.run(items, server: server, force: force)
        }
        tail = Task { _ = await job.value }
        return await job.value
    }

    private func run(_ items: [UploadItem], server: ServerConfig, force: Bool) async -> [(date: String, result: UploadResult)] {
        if !force, let last = lastAttempt, now().timeIntervalSince(last) < debounce {
            return items.map { ($0.date, .debounced) }
        }
        lastAttempt = now()
        let client = PostClient(session: session, server: server)
        var results: [(date: String, result: UploadResult)] = []
        for item in items {
            switch await client.post(body: item.body) {
            case .success(let reply):
                results.append((item.date, .sent(reply)))
            case .failure(let failure):
                results.append((item.date, .failed(failure)))
                if failure.stopsBatch { return results }
            }
        }
        return results
    }
}
