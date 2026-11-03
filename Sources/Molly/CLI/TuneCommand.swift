import ApplicationServices
import AppKit
import Foundation

/// `molly tune [--json] [--apply]`: rules-based recommendations from the live
/// registry, collector health, Prometheus scrape stats and the config.
enum TuneCommand {
    static func run(_ arguments: [String]) {
        let asJSON = arguments.contains("--json")
        let apply = arguments.contains("--apply")
        do {
            let config = try Config.load()
            Log.minimumLevel = .warn
            let input = try gather(config: config)
            let recs = Tuner.recommend(input: input)
            if asJSON {
                print(String(decoding: try JSONMerge.prettyData(TuneReport.json(recs)), as: UTF8.self))
            } else {
                print(TuneReport.text(recs), terminator: "")
            }
            if apply {
                let changed = try applyPatches(recs, to: Paths.configFile)
                if changed.isEmpty {
                    print("Nothing to apply.")
                } else {
                    print("Applied to \(Paths.configFile.path):")
                    for path in changed { print("  \(path)") }
                    print("Reload Config from the menu bar (or restart) to pick it up.")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Deep-merges every patch into the config file after writing a backup.
    /// Returns the dotted paths that changed.
    static func applyPatches(_ recs: [Recommendation], to file: URL) throws -> [String] {
        let patch = TuneReport.combinedPatch(recs)
        guard patch != .object([:]) else { return [] }
        let before: JSONValue
        if FileManager.default.fileExists(atPath: file.path) {
            before = try JSONValue.parse(try Data(contentsOf: file))
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = file.deletingLastPathComponent().appendingPathComponent("\(file.lastPathComponent).bak-\(stamp)")
            try FileManager.default.copyItem(at: file, to: backup)
        } else {
            before = .object([:])
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let after = JSONMerge.merge(before, patch)
        _ = try Config.parse(try JSONMerge.prettyData(after))
        try JSONMerge.prettyData(after).write(to: file, options: .atomic)
        return JSONMerge.changedPaths(before, after)
    }

    // MARK: gathering

    struct StatsUnavailable: Error, CustomStringConvertible {
        let base: String
        var description: String { "no /stats on \(base); is the daemon running?" }
    }

    // The in-process fallback flips StateStore persistence off for the whole
    // process, so callers inside the daemon must opt out of it.
    static func gather(config: Config, inProcessFallback: Bool = true) throws -> TuneInput {
        let base = "http://\(config.server.bind):\(config.server.port)"
        var families: [FamilyStats] = []
        var statuses: [TuneInput.CollectorStatus] = []
        if let stats = fetchJSON(base + "/stats") {
            families = parseFamilies(stats["families"] as? [[String: Any]] ?? [])
            statuses = parseCollectors(stats["collectors"] as? [[String: Any]] ?? [])
        } else if !inProcessFallback {
            throw StatsUnavailable(base: base)
        } else {
            FileHandle.standardError.write(Data("note: no /stats on \(base); running collectors once in-process\n".utf8))
            let (f, s) = try inProcessStats(config: config)
            families = f
            statuses = s
            if let live = fetchJSON(base + "/collectors") {
                statuses = parseCollectors(live["collectors"] as? [[String: Any]] ?? [])
            }
        }

        var input = TuneInput(families: families, collectors: statuses, config: config)
        if let prometheus = try? PrometheusClient(baseURL: config.links.prometheus), prometheus.isReady() {
            input.scrapeDuration = try? prometheus.scalar("scrape_duration_seconds{job=\"molly\"}")
            input.scrapeSamples = try? prometheus.scalar("scrape_samples_scraped{job=\"molly\"}")
        }
        if let privacy = fetchJSON(base + "/privacy") {
            input.privacy = parsePrivacy(privacy)
        }
        input.environment = environment()
        return input
    }

    static func environment() -> TuneInput.Environment {
        var env = TuneInput.Environment()
        let fm = FileManager.default
        env.codexSessionsExist = fm.fileExists(atPath: Paths.home.appendingPathComponent(".codex/sessions").path)
        let mail = Paths.home.appendingPathComponent("Library/Mail")
        if let versions = try? fm.contentsOfDirectory(atPath: mail.path) {
            env.mailIndexExists = versions.contains { fm.fileExists(atPath: mail.appendingPathComponent("\($0)/MailData/Envelope Index").path) }
        }
        env.accessibilityTrusted = AXIsProcessTrusted()
        let browsers: Set<String> = ["com.apple.safari", "com.google.chrome", "com.brave.browser", "company.thebrowser.browser",
                                     "com.microsoft.edgemac", "com.vivaldi.vivaldi"]
        env.browsersRunning = NSWorkspace.shared.runningApplications.contains {
            browsers.contains(($0.bundleIdentifier ?? "").lowercased())
        }
        return env
    }

    /// Fallback for a daemon without /stats: run every collector once with
    /// persistence off, exactly like `molly once`, and read the registry.
    static func inProcessStats(config: Config) throws -> ([FamilyStats], [TuneInput.CollectorStatus]) {
        StateStore.persistenceEnabled = false
        let registry = MetricsRegistry(constLabels: config.constLabels)
        let collectors = try CollectorRegistry.makeCollectors(config: config)
        let manager = CollectorManager(registry: registry, collectors: collectors)
        manager.startAll()
        _ = manager.collectAll()
        let statuses = manager.allStatuses.map {
            TuneInput.CollectorStatus(name: $0.name, interval: $0.interval, runs: $0.runs, errors: $0.errors,
                                      lastError: $0.lastError, lastDuration: $0.lastDuration,
                                      unavailable: $0.unavailable, unavailableSince: $0.unavailableSince)
        }
        let families = registry.stats()
        manager.stopAll()
        return (families, statuses)
    }

    static func fetchJSON(_ url: String) -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        let (status, data) = DoctorCommand.fetch(u, timeout: 3)
        guard status == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parseFamilies(_ raw: [[String: Any]]) -> [FamilyStats] {
        raw.compactMap { f in
            guard let name = f["name"] as? String, let series = f["series"] as? Int else { return nil }
            let type = MetricType(rawValue: f["type"] as? String ?? "gauge") ?? .gauge
            let labels = (f["labels"] as? [String: Int]) ?? [:]
            return FamilyStats(name: name, type: type, series: series, labelCardinality: labels)
        }
    }

    static func parseCollectors(_ raw: [[String: Any]]) -> [TuneInput.CollectorStatus] {
        raw.compactMap { c in
            guard let name = c["name"] as? String else { return nil }
            let since = (c["unavailableSince"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return TuneInput.CollectorStatus(
                name: name,
                interval: (c["interval"] as? Double) ?? 0,
                runs: (c["runs"] as? Int) ?? 0,
                errors: (c["errors"] as? Int) ?? 0,
                lastError: c["lastError"] as? String,
                lastDuration: (c["lastDuration"] as? Double) ?? 0,
                unavailable: (c["unavailable"] as? Bool) ?? false,
                unavailableSince: since)
        }
    }

    /// Accepts the `/privacy` shape `{"dimensions": [{collector, policy, other, redacted}]}`;
    /// anything else yields no counts.
    static func parsePrivacy(_ raw: [String: Any]) -> [TuneInput.PrivacyCount] {
        ((raw["dimensions"] as? [[String: Any]]) ?? []).compactMap { d in
            guard let collector = d["collector"] as? String, let policy = d["policy"] as? String else { return nil }
            return TuneInput.PrivacyCount(collector: collector, policy: policy,
                                          other: (d["other"] as? Int) ?? 0, redacted: (d["redacted"] as? Int) ?? 0)
        }
    }
}
