import Foundation

/// The endpoints Molly serves: /metrics for Prometheus plus a few for humans.
enum Routes {
    static func register(on router: Router, manager: CollectorManager, config: Config) {
        router.get("/") { _ in
            .text("""
            Molly \(Version.current)
            /metrics     Prometheus exposition
            /healthz     liveness
            /event       POST a JSON event (see docs/HOOKS.md)
            /collectors  per-collector status (JSON)
            /config      effective configuration (JSON, secrets redacted)

            """)
        }
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
        router.get("/collectors") { _ in
            let statuses = manager.allStatuses.map { s -> [String: Any] in
                var o: [String: Any] = [
                    "name": s.name, "interval": s.interval, "runs": s.runs, "errors": s.errors,
                    "lastDuration": s.lastDuration, "unavailable": s.unavailable,
                ]
                if let e = s.lastError { o["lastError"] = e }
                if let t = s.lastSuccess { o["lastSuccess"] = t.timeIntervalSince1970 }
                return o
            }
            return .json(["paused": manager.isPaused, "collectors": statuses])
        }
        router.get("/config") { _ in
            var collectors: [String: Any] = [:]
            for (name, section) in config.collectors {
                collectors[name] = redactSalts(section).toFoundation()
            }
            return .json([
                "server": ["bind": config.server.bind, "port": config.server.port],
                "labels": config.constLabels,
                "logLevel": config.logLevel,
                "links": ["grafana": config.links.grafana, "prometheus": config.links.prometheus],
                "collectors": collectors,
            ])
        }
    }

    static func redactSalts(_ value: JSONValue) -> JSONValue {
        guard case .object(let o) = value else { return value }
        var out: [String: JSONValue] = [:]
        for (k, v) in o {
            out[k] = k == "salt" ? .string("***") : redactSalts(v)
        }
        return .object(out)
    }
}
