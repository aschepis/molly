import Foundation

/// The endpoints Molly serves: /metrics for Prometheus plus a few for humans.
enum Routes {
    static func register(on router: Router, manager: CollectorManager, config: Config, server: HTTPServer? = nil,
                         insights: InsightsStore = InsightsStore()) {
        router.get("/") { _ in
            .text("""
            Molly \(Version.current)
            /metrics     Prometheus exposition
            /healthz     liveness
            /event       POST a JSON event (see docs/HOOKS.md)
            /health      POST Apple Health samples from an iPhone Shortcut (see docs/HEALTH.md)
            /health/status  GET what Molly has stored for health (JSON, Bearer token)
            /collectors  per-collector status (JSON)
            /stats       registry size per family plus collector status (JSON)
            /config      effective configuration (JSON, secrets redacted)
            /privacy     every sensitive label dimension, its policy, and decision counts (JSON)
            /insights/latest        newest daily insights report
            /insights/<YYYY-MM-DD>  that day's report; add -week for a week
                                    format: suffix .html .md .json .yaml (.yml), else Accept header, else HTML

            """)
        }
        router.get(prefix: "/insights/") { request in InsightsRoute.handle(request, store: insights) }
        router.get("/metrics") { _ in
            .text(manager.registry.render(), contentType: "text/plain; version=0.0.4; charset=utf-8")
        }
        router.get("/healthz") { _ in .text("ok\n") }
        router.post("/event") { request in
            guard let events = manager.collector(as: EventsCollector.self) else {
                return .text("events collector disabled\n", status: 503)
            }
            switch events.handle(body: request.body, authorization: request.headers["authorization"]) {
            case .accepted: return HTTPResponse(status: 204, headers: [:], body: Data())
            case .unauthorized: return .text("unauthorized\n", status: 401)
            case .badRequest(let why): return .text("bad request: \(why)\n", status: 400)
            }
        }
        router.post("/health") { request in
            guard let health = manager.collector(as: HealthCollector.self) else {
                return .text("health collector disabled\n", status: 503)
            }
            switch health.handle(body: request.body, authorization: request.headers["authorization"]) {
            case .accepted(let accepted, let rejected):
                return .json(["accepted": accepted, "rejected": rejected])
            case .unauthorized: return .text("unauthorized\n", status: 401)
            case .forbidden: return .text("health data stays local: see docs/HEALTH.md\n", status: 403)
            case .badRequest(let why): return .text("bad request: \(why)\n", status: 400)
            }
        }
        router.get("/health/status") { request in
            guard let health = manager.collector(as: HealthCollector.self) else {
                return .text("health collector disabled\n", status: 503)
            }
            switch health.status(authorization: request.headers["authorization"]) {
            case .ok(let status): return .json(status)
            case .unauthorized: return .text("unauthorized\n", status: 401)
            case .forbidden: return .text("health data stays local: see docs/HEALTH.md\n", status: 403)
            }
        }
        router.get("/collectors") { _ in
            .json(["paused": manager.isPaused, "collectors": collectorsJSON(manager)])
        }
        router.get("/stats") { _ in
            let families = manager.registry.stats().map { f -> [String: Any] in
                ["name": f.name, "type": f.type.rawValue, "series": f.series, "labels": f.labelCardinality]
            }
            return .json([
                "families": families,
                "seriesTotal": families.reduce(0) { $0 + ($1["series"] as? Int ?? 0) },
                "collectors": collectorsJSON(manager),
                "server": ["port": config.server.port, "binds": server?.status ?? []],
            ])
        }
        router.get("/privacy") { _ in
            .json(PrivacyAudit.shared.report(
                constLabels: config.constLabels,
                collectorsOn: manager.collectors.map { $0.name },
                disabledByDefault: CollectorRegistry.disabledByDefault))
        }
        router.get("/config") { _ in
            var collectors: [String: Any] = [:]
            for (name, section) in config.collectors {
                collectors[name] = redactSalts(section).toFoundation()
            }
            return .json([
                "server": ["bind": config.server.bind, "binds": config.server.binds, "port": config.server.port],
                "labels": config.constLabels,
                "logLevel": config.logLevel,
                "links": ["grafana": config.links.grafana, "prometheus": config.links.prometheus],
                "stack": ["retention": config.stack.retention, "composeDir": config.stack.composeDir ?? ""],
                "collectors": collectors,
            ])
        }
    }

    static func collectorsJSON(_ manager: CollectorManager) -> [[String: Any]] {
        manager.allStatuses.map { s -> [String: Any] in
            var o: [String: Any] = [
                "name": s.name, "interval": s.interval, "runs": s.runs, "errors": s.errors,
                "lastDuration": s.lastDuration, "unavailable": s.unavailable,
            ]
            if let e = s.lastError { o["lastError"] = e }
            if let t = s.lastSuccess { o["lastSuccess"] = t.timeIntervalSince1970 }
            if let t = s.unavailableSince { o["unavailableSince"] = t.timeIntervalSince1970 }
            return o
        }
    }

    static func redactSalts(_ value: JSONValue) -> JSONValue {
        guard case .object(let o) = value else { return value }
        var out: [String: JSONValue] = [:]
        for (k, v) in o {
            out[k] = (k == "salt" || k == "apiKey" || k == "token") && v != .string("") ? .string("***") : redactSalts(v)
        }
        return .object(out)
    }
}
