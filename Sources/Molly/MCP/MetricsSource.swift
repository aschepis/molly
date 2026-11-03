import Foundation

/// What the MCP tools need from the outside world. Tests inject fixtures;
/// production wraps PrometheusClient plus Molly's own HTTP endpoints.
protocol MetricsQuerying {
    func query(_ promql: String, at: Date?) throws -> [PrometheusClient.Sample]
    func queryRange(_ promql: String, from: Date, to: Date, step: TimeInterval) throws -> [PrometheusClient.Series]
    /// GET a path on the running Molly (for example "/metrics"); throws when it is not running.
    func fetchMolly(_ path: String) throws -> String
}

struct LiveMetricsSource: MetricsQuerying {
    let prometheus: PrometheusClient
    let mollyURL: URL

    enum SourceError: Error, CustomStringConvertible {
        case mollyUnreachable(String)
        var description: String {
            switch self {
            case .mollyUnreachable(let m): return "molly unreachable: \(m)"
            }
        }
    }

    init(config: Config) throws {
        prometheus = try PrometheusClient(baseURL: config.mcpPrometheusURL)
        guard let url = URL(string: config.mcpMollyURL) else {
            throw SourceError.mollyUnreachable("bad url \(config.mcpMollyURL)")
        }
        mollyURL = url
    }

    func query(_ promql: String, at: Date?) throws -> [PrometheusClient.Sample] {
        try prometheus.query(promql, at: at)
    }

    func queryRange(_ promql: String, from: Date, to: Date, step: TimeInterval) throws -> [PrometheusClient.Series] {
        try prometheus.queryRange(promql, from: from, to: to, step: step)
    }

    func fetchMolly(_ path: String) throws -> String {
        let (status, data) = DoctorCommand.fetch(mollyURL.appendingPathComponent(path), timeout: 3)
        guard status == 200 else {
            let why = status == 0 ? "no response" : "HTTP \(status)"
            throw SourceError.mollyUnreachable("\(mollyURL.absoluteString)\(path) returned \(why)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
