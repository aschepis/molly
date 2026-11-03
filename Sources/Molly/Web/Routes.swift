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
            /stats       registry size per family plus collector status (JSON)
            /config      effective configuration (JSON, secrets redacted)
            /privacy     every sensitive label dimension, its policy, and decision counts (JSON)
            /insights/latest        newest daily insights report (Markdown)
            /insights/<YYYY-MM-DD>  that day's report; add -week for a week

            """)
        }
        let insights = InsightsStore()
        router.get("/insights/latest") { _ in
            guard let latest = insights.latest() else {
                return .text("no insights yet: run `molly insights` or enable the insights collector\n", status: 404)
            }
            return .text(latest.text, contentType: "text/markdown; charset=utf-8")
        }
        router.get(prefix: "/insights/") { request in
            var name = String(request.path.dropFirst("/insights/".count))
            let kind: InsightsDigest.Kind = name.hasSuffix("-week") ? .week : .day
            if kind == .week { name = String(name.dropLast("-week".count)) }
            guard DigestBuilder.parseDate(name) != nil, let text = insights.read(kind: kind, date: name) else {
                return .notFound()
            }
            return .text(text, contentType: "text/markdown; charset=utf-8")
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
                "server": ["bind": config.server.bind, "port": config.server.port],
                "labels": config.constLabels,
                "logLevel": config.logLevel,
                "links": ["grafana": config.links.grafana, "prometheus": config.links.prometheus],
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
            out[k] = (k == "salt" || k == "apiKey") && v != .string("") ? .string("***") : redactSalts(v)
        }
        return .object(out)
    }
}
