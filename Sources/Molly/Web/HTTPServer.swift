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
        case 403: return "Forbidden"
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
    private var prefixRoutes: [(method: String, prefix: String, handler: Handler)] = []

    func get(_ path: String, _ handler: @escaping Handler) {
        routes.append(("GET", path, handler))
    }

    func post(_ path: String, _ handler: @escaping Handler) {
        routes.append(("POST", path, handler))
    }

    /// Matches any path under `prefix` (which must end in "/"); exact routes win.
    func get(prefix: String, _ handler: @escaping Handler) {
        prefixRoutes.append(("GET", prefix, handler))
    }

    func route(_ request: HTTPRequest) -> HTTPResponse {
        var matching = routes.filter { $0.path == request.path }
        if matching.isEmpty {
            matching = prefixRoutes
                .filter { request.path.hasPrefix($0.prefix) && request.path.count > $0.prefix.count }
                .map { ($0.method, request.path, $0.handler) }
        }
        for route in matching {
            if route.method == request.method || (route.method == "GET" && request.method == "HEAD") {
                return route.handler(request)
            }
        }
        return matching.isEmpty ? .notFound() : .text("method not allowed\n", status: 405)
    }
}

final class HTTPServer {
    /// Secondary binds (a Tailscale address that appears after login) retry at this pace.
    static let retryIntervalSeconds: TimeInterval = 30

    private final class Endpoint {
        let bind: String
        let isPrimary: Bool
        var listener: NWListener?
        var listening = false
        var failureLogged = false

        init(bind: String, isPrimary: Bool) {
            self.bind = bind
            self.isPrimary = isPrimary
        }
    }

    private let router: Router
    private let port: NWEndpoint.Port
    private let retryInterval: TimeInterval
    private let endpoints: [Endpoint]
    private let listeningGauge: Gauge?
    private let queue = DispatchQueue(label: "molly.http")
    private let stateLock = NSLock()
    private var stopped = false
    var onFailure: ((Error) -> Void)?
    var onRequest: ((HTTPRequest) -> Void)?

    convenience init(bind: String, port: Int, router: Router) throws {
        try self.init(binds: [bind], port: port, router: router)
    }

    init(binds: [String], port: Int, router: Router, registry: MetricsRegistry? = nil,
         retryInterval: TimeInterval = HTTPServer.retryIntervalSeconds) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw ConfigError.invalid("bad port \(port)")
        }
        guard !binds.isEmpty else { throw ConfigError.invalid("no bind addresses") }
        self.router = router
        self.port = nwPort
        self.retryInterval = retryInterval
        let primaryBind = binds.first(where: Config.Server.isLoopback) ?? binds[0]
        endpoints = binds.map { Endpoint(bind: $0, isPrimary: $0 == primaryBind) }
        listeningGauge = registry?.gauge("molly_server_listening",
                                         help: "1 when the HTTP server is bound to this address, 0 while it is retrying",
                                         labels: ["bind"])
        for endpoint in endpoints { listeningGauge?.set(0, labels: ["bind": endpoint.bind]) }
        if let primary = endpoints.first(where: { $0.isPrimary }) {
            primary.listener = try makeListener(bind: primary.bind)
        }
    }

    /// Per-bind state for /stats and /config.
    var status: [[String: Any]] {
        // Route handlers run on `queue`, so this must not hop onto it.
        stateLock.lock()
        defer { stateLock.unlock() }
        return endpoints.map { ["bind": $0.bind, "primary": $0.isPrimary, "listening": $0.listening] }
    }

    func start() {
        queue.async { [self] in
            for endpoint in endpoints { startListening(endpoint) }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            for endpoint in endpoints { endpoint.listener?.cancel() }
        }
    }

    private func makeListener(bind: String) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return listener
    }

    private func startListening(_ endpoint: Endpoint) {
        guard !stopped else { return }
        let listener: NWListener
        do {
            if let existing = endpoint.listener {
                listener = existing
            } else {
                listener = try makeListener(bind: endpoint.bind)
                endpoint.listener = listener
            }
        } catch {
            endpointDown(endpoint, error: error)
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, endpoint.listener === listener else { return }
            switch state {
            case .ready:
                self.endpointUp(endpoint)
            case .failed(let error):
                if endpoint.isPrimary { self.onFailure?(error) } else { self.endpointDown(endpoint, error: error) }
            case .waiting(let error) where !endpoint.isPrimary:
                self.endpointDown(endpoint, error: error)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func setListening(_ endpoint: Endpoint, _ value: Bool) {
        stateLock.lock()
        endpoint.listening = value
        stateLock.unlock()
    }

    private func endpointUp(_ endpoint: Endpoint) {
        setListening(endpoint, true)
        listeningGauge?.set(1, labels: ["bind": endpoint.bind])
        if endpoint.failureLogged {
            Log.info("now listening on http://\(endpoint.bind):\(port)")
        }
        endpoint.failureLogged = false
    }

    private func endpointDown(_ endpoint: Endpoint, error: Error) {
        setListening(endpoint, false)
        listeningGauge?.set(0, labels: ["bind": endpoint.bind])
        endpoint.listener?.cancel()
        endpoint.listener = nil
        if !endpoint.failureLogged {
            Log.warn("cannot listen on \(endpoint.bind):\(port), retrying every \(Int(retryInterval))s: \(error)")
            endpoint.failureLogged = true
        }
        queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
            self?.startListening(endpoint)
        }
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
