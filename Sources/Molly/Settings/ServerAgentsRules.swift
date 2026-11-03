import Foundation

/// Pure rules behind the Server tab, kept free of SwiftUI for testing.
enum ServerRules {
    static let logLevels = ["debug", "info", "warn", "error"]
    static let reservedLabels: Set<String> = ["user", "host"]
    static let portRange = 1024...65535

    /// Why a label name cannot be used as an extra const label, or nil when it can.
    static func labelNameError(_ name: String) -> String? {
        if name.isEmpty { return "label name is empty" }
        if reservedLabels.contains(name) { return "\(name) is set by Molly; choose another name" }
        if name.range(of: "^[a-zA-Z_][a-zA-Z0-9_]*$", options: .regularExpression) == nil {
            return "label names use letters, digits and _ and cannot start with a digit"
        }
        return nil
    }

    static func isLoopback(_ bind: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(bind)
    }

    /// Mirrors Tuner.tokenOnOpenBind for the still-unsaved values in the window.
    static func openBindWarning(bind: String, token: String) -> String? {
        guard !isLoopback(bind), token.isEmpty else { return nil }
        return "\(bind) is reachable from the network and POST /event has no token; set one under Hooks or bind to 127.0.0.1"
    }

    static func metricsURL(bind: String, port: Int) -> String {
        "http://\(bind):\(port)/metrics"
    }

    static func insightsURL(bind: String, port: Int) -> String {
        "http://\(bind):\(port)/insights/latest"
    }

    static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// Pure rules behind the Agents tab.
enum AgentsRules {
    static let backends = ["auto", "api", "cli"]

    static func mcpAddCommand(binary: String) -> String {
        "claude mcp add molly -- \"\(binary)\" mcp"
    }

    /// The leaf paths of a config patch, so each one can be staged in the
    /// window instead of merged straight into the file. Arrays are leaves
    /// because JSONMerge replaces them whole.
    static func leaves(_ patch: JSONValue, prefix: [String] = []) -> [(path: [String], value: JSONValue)] {
        guard case .object(let object) = patch, !object.isEmpty else {
            return prefix.isEmpty ? [] : [(prefix, patch)]
        }
        return object.keys.sorted().flatMap { key in
            leaves(object[key] ?? .null, prefix: prefix + [key])
        }
    }

    /// Stages every leaf of the combined patch; returns the dotted paths touched.
    @discardableResult
    static func stage(_ recommendations: [Recommendation], into model: SettingsModel) -> [String] {
        let changes = leaves(TuneReport.combinedPatch(recommendations))
        for change in changes { model.set(change.path, change.value) }
        return changes.map { $0.path.joined(separator: ".") }
    }
}

/// Runs the insights and tune pipelines from the window against the saved
/// config, like their CLI commands do. Call off the main thread.
enum AgentActions {
    static func runInsights(kind: InsightsDigest.Kind = .day, force: Bool = false) throws -> InsightsGenerator.Result {
        let config = try Config.load()
        let settings = InsightsSettings(settings: config.collector("insights"), links: config.links)
        let client = try PrometheusClient(baseURL: settings.prometheusURL)
        guard client.isReady() else {
            throw CollectorUnavailable(reason: "Prometheus at \(settings.prometheusURL) is not ready (run `make stack-up`)")
        }
        let generator = InsightsGenerator(
            client: client, store: InsightsStore(),
            user: config.constLabels["user"] ?? Config.defaultUser,
            host: config.constLabels["host"] ?? Config.defaultHost,
            makeCompleter: { try NarrativeBackend.make(choice: settings.backend, apiKey: settings.apiKey, model: settings.model) })
        return try generator.generate(kind: kind, date: Date(), force: force)
    }

    static func runTune() throws -> [Recommendation] {
        let config = try Config.load()
        return Tuner.recommend(input: try TuneCommand.gather(config: config))
    }
}
