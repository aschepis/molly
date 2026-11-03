import Foundation

/// Minimal client for the Prometheus HTTP API, used by features that read
/// Molly's own history back (insights, MCP tools, tuning). Synchronous: these
/// run from CLI commands or background queues, never on the main thread.
struct PrometheusClient {
    struct Sample {
        let labels: [String: String]
        let timestamp: Date
        let value: Double
    }

    struct Series {
        let labels: [String: String]
        let points: [(Date, Double)]
    }

    enum ClientError: Error, CustomStringConvertible {
        case unreachable(String)
        case badResponse(String)
        case queryFailed(String)

        var description: String {
            switch self {
            case .unreachable(let m): return "prometheus unreachable: \(m)"
            case .badResponse(let m): return "prometheus bad response: \(m)"
            case .queryFailed(let m): return "prometheus query failed: \(m)"
            }
        }
    }

    let baseURL: URL
    var timeout: TimeInterval = 15

    init(baseURL: String) throws {
        guard let url = URL(string: baseURL), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil else {
            throw ClientError.unreachable("bad url \(baseURL)")
        }
        self.baseURL = url
    }

    /// Instant query. `at` defaults to now.
    func query(_ promql: String, at: Date? = nil) throws -> [Sample] {
        var items = [URLQueryItem(name: "query", value: promql)]
        if let at { items.append(URLQueryItem(name: "time", value: String(at.timeIntervalSince1970))) }
        let data = try get("/api/v1/query", items)
        let results = try resultArray(data, expectedType: "vector")
        return results.compactMap { r -> Sample? in
            guard let metric = r["metric"] as? [String: String],
                  let value = r["value"] as? [Any], value.count == 2,
                  let ts = (value[0] as? NSNumber)?.doubleValue,
                  let v = Double("\(value[1])") else { return nil }
            return Sample(labels: metric, timestamp: Date(timeIntervalSince1970: ts), value: v)
        }
    }

    /// Range query with a fixed step.
    func queryRange(_ promql: String, from: Date, to: Date, step: TimeInterval) throws -> [Series] {
        let items = [
            URLQueryItem(name: "query", value: promql),
            URLQueryItem(name: "start", value: String(from.timeIntervalSince1970)),
            URLQueryItem(name: "end", value: String(to.timeIntervalSince1970)),
            URLQueryItem(name: "step", value: String(step)),
        ]
        let data = try get("/api/v1/query_range", items)
        let results = try resultArray(data, expectedType: "matrix")
        return results.compactMap { r -> Series? in
            guard let metric = r["metric"] as? [String: String],
                  let values = r["values"] as? [[Any]] else { return nil }
            let points = values.compactMap { pair -> (Date, Double)? in
                guard pair.count == 2, let ts = (pair[0] as? NSNumber)?.doubleValue,
                      let v = Double("\(pair[1])") else { return nil }
                return (Date(timeIntervalSince1970: ts), v)
            }
            return Series(labels: metric, points: points)
        }
    }

    /// First scalar of an instant query, or nil when the result is empty.
    func scalar(_ promql: String, at: Date? = nil) throws -> Double? {
        try query(promql, at: at).first?.value
    }

    func isReady() -> Bool {
        (try? get("/-/ready", [])) != nil
    }

    private func get(_ path: String, _ items: [URLQueryItem]) throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !items.isEmpty { components.queryItems = items }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        URLSession.shared.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = result.2 { throw ClientError.unreachable(error.localizedDescription) }
        guard let http = result.1 as? HTTPURLResponse, let data = result.0 else {
            throw ClientError.badResponse("no response")
        }
        guard http.statusCode == 200 else {
            throw ClientError.queryFailed("HTTP \(http.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return data
    }

    private func resultArray(_ data: Data, expectedType: String) throws -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badResponse("not JSON")
        }
        guard root["status"] as? String == "success", let payload = root["data"] as? [String: Any] else {
            throw ClientError.queryFailed((root["error"] as? String) ?? "unknown error")
        }
        guard payload["resultType"] as? String == expectedType, let results = payload["result"] as? [[String: Any]] else {
            throw ClientError.badResponse("expected \(expectedType)")
        }
        return results
    }
}
