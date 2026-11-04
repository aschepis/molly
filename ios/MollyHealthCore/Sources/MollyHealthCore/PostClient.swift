import Foundation

/// The only door to the network, so tests can stand in a fake.
public protocol HTTPSession: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPSession {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public struct ServerConfig: Equatable, Sendable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    func url(_ path: String) -> URL? {
        let root = baseURL.absoluteString
        return URL(string: (root.hasSuffix("/") ? String(root.dropLast()) : root) + path)
    }
}

public struct PostReply: Equatable, Sendable {
    public let status: Int
    public let accepted: Int?
    public let rejected: [String: Int]

    public var rejectedCount: Int { rejected.values.reduce(0, +) }
}

public enum UploadFailure: Error, Equatable, Sendable {
    case notConfigured(String)
    case badRequest
    case unauthorized
    case forbidden
    case payloadTooLarge
    case collectorDisabled
    case server(Int)
    case timeout
    case network(String)

    public var message: String {
        switch self {
        case .notConfigured(let what): return what
        case .badRequest: return "HTTP 400: the Mac could not use the body"
        case .unauthorized: return "HTTP 401: wrong or empty token"
        case .forbidden: return "HTTP 403: the Mac refused (health collector needs allowRemoteBind)"
        case .payloadTooLarge: return "HTTP 413: body over 64 KiB"
        case .collectorDisabled: return "HTTP 503: health collector disabled on the Mac"
        case .server(let status): return "HTTP \(status)"
        case .timeout: return "timed out"
        case .network(let text): return text
        }
    }

    /// Fatal for a whole batch: trying the next day would fail the same way.
    var stopsBatch: Bool {
        switch self {
        case .badRequest, .payloadTooLarge: return false
        default: return true
        }
    }

    public var httpStatus: Int? {
        switch self {
        case .badRequest: return 400
        case .unauthorized: return 401
        case .forbidden: return 403
        case .payloadTooLarge: return 413
        case .collectorDisabled: return 503
        case .server(let status): return status
        default: return nil
        }
    }
}

public enum StatusOutcome: Equatable, Sendable {
    case ok(String)
    case notReported
    case badToken
    case collectorDisabled
    case failed(String)

    public var message: String {
        switch self {
        case .ok(let summary): return summary.isEmpty ? "Status OK" : "Status OK: \(summary)"
        case .notReported: return "server does not report status yet"
        case .badToken: return "bad token"
        case .collectorDisabled: return "health collector disabled on the Mac"
        case .failed(let text): return text
        }
    }
}

public struct PostClient: Sendable {
    public static let requestTimeout: TimeInterval = 15
    private static let statusSummaryLimit = 200

    let session: HTTPSession
    let server: ServerConfig

    public init(session: HTTPSession, server: ServerConfig) {
        self.session = session
        self.server = server
    }

    public func post(body: Data) async -> Result<PostReply, UploadFailure> {
        guard let url = server.url("/health") else { return .failure(.notConfigured("invalid server URL")) }
        var request = authorized(URLRequest(url: url))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.send(request)
            return interpret(status: response.statusCode, data: data)
        } catch {
            return .failure(Self.failure(for: error))
        }
    }

    /// GET /healthz; the Mac answers `ok`.
    public func checkHealthz() async -> Result<Void, UploadFailure> {
        guard let url = server.url("/healthz") else { return .failure(.notConfigured("invalid server URL")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        do {
            let (data, response) = try await session.send(request)
            guard response.statusCode == 200 else { return .failure(.server(response.statusCode)) }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text == "ok" ? .success(()) : .failure(.network("/healthz answered \"\(text.prefix(40))\", expected ok"))
        } catch {
            return .failure(Self.failure(for: error))
        }
    }

    /// GET /health/status with the bearer token.
    public func fetchStatus() async -> StatusOutcome {
        guard let url = server.url("/health/status") else { return .failed("invalid server URL") }
        let request = authorized(URLRequest(url: url))
        do {
            let (data, response) = try await session.send(request)
            switch response.statusCode {
            case 200: return .ok(String(String(decoding: data, as: UTF8.self).prefix(Self.statusSummaryLimit)))
            case 401: return .badToken
            case 404: return .notReported
            case 503: return .collectorDisabled
            default: return .failed("HTTP \(response.statusCode)")
            }
        } catch {
            return .failed(Self.failure(for: error).message)
        }
    }

    private func authorized(_ base: URLRequest) -> URLRequest {
        var request = base
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func interpret(status: Int, data: Data) -> Result<PostReply, UploadFailure> {
        switch status {
        case 200..<300:
            return .success(Self.parseReply(status: status, data: data))
        case 400: return .failure(.badRequest)
        case 401: return .failure(.unauthorized)
        case 403: return .failure(.forbidden)
        case 413: return .failure(.payloadTooLarge)
        case 503: return .failure(.collectorDisabled)
        default: return .failure(.server(status))
        }
    }

    static func parseReply(status: Int, data: Data) -> PostReply {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let accepted = (object?["accepted"] as? NSNumber)?.intValue
        var rejected: [String: Int] = [:]
        for (reason, count) in (object?["rejected"] as? [String: Any]) ?? [:] {
            if let n = (count as? NSNumber)?.intValue { rejected[reason] = n }
        }
        return PostReply(status: status, accepted: accepted, rejected: rejected)
    }

    static func failure(for error: Error) -> UploadFailure {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .network(urlError.localizedDescription)
        }
        return .network(error.localizedDescription)
    }
}
