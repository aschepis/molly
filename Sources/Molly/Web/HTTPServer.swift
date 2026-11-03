import Foundation
import Network

// Minimal HTTP/1.1 server for /metrics. One request per connection, then close.

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data = Data()
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func text(_ string: String, status: Int = 200,
                     contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: Data(string.utf8))
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        else {
            return HTTPResponse(status: 500, headers: ["Content-Type": "application/json"],
                                body: Data(#"{"error":"encoding failed"}"#.utf8))
        }
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func notFound() -> HTTPResponse { text("not found\n", status: 404) }

    func serialized() -> Data {
        var merged = headers
        merged["Content-Length"] = String(body.count)
        merged["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        for (name, value) in merged.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}

enum HTTPRequestParser {
    enum Result {
        case incomplete
        case invalid
        case tooLarge
        case request(HTTPRequest)
    }

    /// Bodies beyond this are refused with 413; /event payloads are tiny.
    static let maxBodyBytes = 64 * 1024

    static func parse(_ buffer: Data) -> Result {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0 else { return .invalid }
        guard contentLength <= maxBodyBytes else { return .tooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
        let (path, query) = parseTarget(String(parts[1]))
        return .request(HTTPRequest(method: String(parts[0]).uppercased(), path: path, query: query,
                                    headers: headers, body: body))
    }

    static func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(pieces[0])
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count == 2 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        return (rawPath.removingPercentEncoding ?? rawPath, query)
    }
}

/// Exact-path router; first match wins.
final class Router {
    typealias Handler = (HTTPRequest) -> HTTPResponse
    private var routes: [(method: String, path: String, handler: Handler)] = []

    func get(_ path: String, _ handler: @escaping Handler) {
        routes.append(("GET", path, handler))
    }

    func post(_ path: String, _ handler: @escaping Handler) {
        routes.append(("POST", path, handler))
    }

    func route(_ request: HTTPRequest) -> HTTPResponse {
        let matching = routes.filter { $0.path == request.path }
        for route in matching {
            if route.method == request.method || (route.method == "GET" && request.method == "HEAD") {
                return route.handler(request)
            }
        }
        return matching.isEmpty ? .notFound() : .text("method not allowed\n", status: 405)
    }
}

final class HTTPServer {
    private let listener: NWListener
    private let router: Router
    private let queue = DispatchQueue(label: "molly.http")
    var onFailure: ((Error) -> Void)?
    var onRequest: ((HTTPRequest) -> Void)?

    init(bind: String, port: Int, router: Router) throws {
        self.router = router
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ConfigError.invalid("bad port \(port)")
        }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: nwPort)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onFailure?(error) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 2 * HTTPRequestParser.maxBodyBytes) { data, _, isComplete, error in
                if let data { buffer.append(data) }
                if error != nil {
                    connection.cancel()
                    return
                }
                switch HTTPRequestParser.parse(buffer) {
                case .incomplete:
                    if isComplete { connection.cancel() } else { receive() }
                case .invalid:
                    self.send(.text("bad request\n", status: 400), on: connection)
                case .tooLarge:
                    self.send(.text("payload too large\n", status: 413), on: connection)
                case .request(let request):
                    self.onRequest?(request)
                    self.send(self.router.route(request), on: connection)
                }
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
