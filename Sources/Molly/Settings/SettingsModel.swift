import Combine
import Foundation

/// The Settings window's model: a `ConfigDocument` plus typed accessors the
/// tabs bind to. Edits stay in memory until `apply()` saves and reloads.
final class SettingsModel: ObservableObject {
    enum Preset: String, CaseIterable, Identifiable {
        case strict, balanced, developer
        var id: String { rawValue }

        var title: String {
            switch self {
            case .strict: return "Strict"
            case .balanced: return "Balanced"
            case .developer: return "Developer"
            }
        }
    }

    @Published private(set) var document: ConfigDocument
    @Published private(set) var saved: JSONValue
    @Published var selectedTab: SettingsTab = .collectors
    @Published var lastError: String?
    @Published var lastMessage: String?

    let stateFolder: URL
    private let reload: () throws -> Void
    private let pauseCollectors: () -> Void
    private let collectorStatuses: () -> [CollectorManager.Status]

    init(document: ConfigDocument,
         stateFolder: URL = Paths.stateFolder,
         reload: @escaping () throws -> Void,
         pauseCollectors: @escaping () -> Void = {},
         collectorStatuses: @escaping () -> [CollectorManager.Status] = { [] }) {
        self.document = document
        self.saved = document.root
        self.stateFolder = stateFolder
        self.reload = reload
        self.pauseCollectors = pauseCollectors
        self.collectorStatuses = collectorStatuses
    }

    static func load(url: URL = Paths.configFile,
                     stateFolder: URL = Paths.stateFolder,
                     reload: @escaping () throws -> Void,
                     pauseCollectors: @escaping () -> Void = {},
                     collectorStatuses: @escaping () -> [CollectorManager.Status] = { [] }) throws -> SettingsModel {
        SettingsModel(document: try ConfigDocument(url: url), stateFolder: stateFolder, reload: reload,
                      pauseCollectors: pauseCollectors, collectorStatuses: collectorStatuses)
    }

    var isDirty: Bool { document.root != saved }

    /// The reason the current edits would be rejected, or nil when valid.
    /// `Config.parse` leaves policy objects to the collectors, so they are
    /// checked here too; otherwise a bad one would only surface at reload.
    var validationError: String? {
        do {
            let config = try document.validate()
            for dimension in PrivacyCatalog.all {
                _ = try config.collector(dimension.collector).policy(dimension.key, defaults: dimension.defaults)
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: Raw access

    func get(_ path: [String]) -> JSONValue? { document.get(path: path) }

    func set(_ path: [String], _ value: JSONValue?) {
        document.set(path: path, value)
    }

    // MARK: Collectors

    func collectorEnabled(_ name: String) -> Bool {
        get(["collectors", name, "enabled"])?.boolValue ?? (CollectorCatalog.info(name)?.defaultEnabled ?? true)
    }

    func setCollectorEnabled(_ name: String, _ enabled: Bool) {
        set(["collectors", name, "enabled"], .bool(enabled))
    }

    func collectorInterval(_ name: String) -> Double {
        let value = get(["collectors", name, "interval"])?.doubleValue ?? 0
        return value > 0 ? value : (CollectorCatalog.info(name)?.defaultInterval ?? 60)
    }

    func setCollectorInterval(_ name: String, _ seconds: Double) {
        set(["collectors", name, "interval"], .number(max(1, seconds.rounded())))
    }

    func status(of collector: String) -> CollectorManager.Status? {
        collectorStatuses().first { $0.name == collector }
    }

    // MARK: Label policies

    /// The policy as the collector would see it: file values over defaults,
    /// and the defaults alone when the file's object is malformed.
    func policy(_ dimension: PrivacyDimension) -> LabelPolicy {
        (try? LabelPolicy.from(get(dimension.path), defaults: dimension.defaults)) ?? dimension.defaults
    }

    func setPolicyEnabled(_ dimension: PrivacyDimension, _ enabled: Bool) {
        set(dimension.path + ["enabled"], .bool(enabled))
    }

    func setPolicyMode(_ dimension: PrivacyDimension, _ mode: LabelPolicy.Mode) {
        set(dimension.path + ["mode"], .string(mode.rawValue))
    }

    func setPolicyPatterns(_ dimension: PrivacyDimension, _ patterns: [String]) {
        let cleaned = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set(dimension.path + ["patterns"], .array(cleaned.map { .string($0) }))
    }

    func setPolicyHash(_ dimension: PrivacyDimension, _ hash: Bool) {
        set(dimension.path + ["hash"], .bool(hash))
    }

    func setPolicyMaxCardinality(_ dimension: PrivacyDimension, _ limit: Int) {
        set(dimension.path + ["maxCardinality"], .number(Double(max(0, limit))))
    }

    /// Salts never leave the model; the UI only learns whether one is set.
    func hasSalt(_ dimension: PrivacyDimension) -> Bool {
        !(get(dimension.path + ["salt"])?.stringValue ?? "").isEmpty
    }

    func setSalt(_ dimension: PrivacyDimension, _ salt: String) {
        set(dimension.path + ["salt"], salt.isEmpty ? nil : .string(salt))
    }

    func regenerateSalt(_ dimension: PrivacyDimension) {
        setSalt(dimension, SettingsModel.randomSalt())
    }

    static func randomSalt() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: Server, links, labels, logging

    var serverBind: String {
        get { get(["server", "bind"])?.stringValue ?? Config.Server().bind }
        set { set(["server", "bind"], .string(newValue)) }
    }

    var serverPort: Int {
        get { get(["server", "port"])?.intValue ?? Config.Server().port }
        set { set(["server", "port"], .number(Double(newValue))) }
    }

    var grafanaURL: String {
        get { get(["links", "grafana"])?.stringValue ?? Config.Links().grafana }
        set { set(["links", "grafana"], .string(newValue)) }
    }

    var prometheusURL: String {
        get { get(["links", "prometheus"])?.stringValue ?? Config.Links().prometheus }
        set { set(["links", "prometheus"], .string(newValue)) }
    }

    var logLevel: String {
        get { get(["logLevel"])?.stringValue ?? Config().logLevel }
        set { set(["logLevel"], .string(newValue)) }
    }

    var extraLabels: [String: String] {
        (get(["labels", "extra"])?.objectValue ?? [:]).compactMapValues { $0.stringValue }
    }

    func setExtraLabel(_ name: String, _ value: String?) {
        set(["labels", "extra", name], value.map { .string($0) })
    }

    var eventsToken: String {
        get { get(["collectors", "events", "token"])?.stringValue ?? "" }
        set { set(["collectors", "events", "token"], newValue.isEmpty ? nil : .string(newValue)) }
    }

    // MARK: Insights and MCP

    var insightsEnabled: Bool {
        get { collectorEnabled("insights") }
        set { setCollectorEnabled("insights", newValue) }
    }

    var insightsBackend: String {
        get { get(["collectors", "insights", "backend"])?.stringValue ?? NarrativeBackend.Choice.auto.rawValue }
        set { set(["collectors", "insights", "backend"], .string(newValue)) }
    }

    var insightsModel: String {
        get { get(["collectors", "insights", "model"])?.stringValue ?? ClaudeAPICompleter.defaultModel }
        set { set(["collectors", "insights", "model"], .string(newValue)) }
    }

    var insightsDailyHour: Int {
        get { get(["collectors", "insights", "dailyAtHour"])?.intValue ?? 21 }
        set { set(["collectors", "insights", "dailyAtHour"], .number(Double(min(23, max(0, newValue))))) }
    }

    var insightsWeekly: Bool {
        get { get(["collectors", "insights", "weekly"])?.boolValue ?? true }
        set { set(["collectors", "insights", "weekly"], .bool(newValue)) }
    }

    var hasInsightsAPIKey: Bool {
        !(get(["collectors", "insights", "apiKey"])?.stringValue ?? "").isEmpty
    }

    func setInsightsAPIKey(_ key: String) {
        set(["collectors", "insights", "apiKey"], key.isEmpty ? nil : .string(key))
    }

    var mcpPrometheusURL: String {
        get { get(["mcp", "prometheusURL"])?.stringValue ?? prometheusURL }
        set { set(["mcp", "prometheusURL"], newValue.isEmpty ? nil : .string(newValue)) }
    }

    // MARK: Stack

    var retention: String {
        get { get(["stack", "retention"])?.stringValue ?? Config.Stack.defaultRetention }
        set { set(["stack", "retention"], .string(newValue.trimmingCharacters(in: .whitespaces))) }
    }

    var retentionIsValid: Bool { PrometheusDuration.isValid(retention) }

    var composeDir: String {
        get { get(["stack", "composeDir"])?.stringValue ?? "" }
        set { set(["stack", "composeDir"], newValue.isEmpty ? nil : .string(newValue)) }
    }

    /// The configured compose folder, else the checkout's deploy/ if one is found.
    var effectiveComposeDir: URL? {
        if !composeDir.isEmpty { return URL(fileURLWithPath: Paths.expand(composeDir)) }
        return Maintenance.defaultComposeDir()
    }

    // MARK: Actions

    /// Saves and reloads the runtime. Returns false and sets `lastError`
    /// when the edits are invalid or the write fails.
    @discardableResult
    func apply() -> Bool {
        if let invalid = validationError {
            lastError = invalid
            return false
        }
        do {
            try document.save()
            saved = document.root
            try reload()
            lastError = nil
            lastMessage = "Saved and reloaded"
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    func revert() {
        document.root = saved
        lastError = nil
    }

    /// Re-reads the file, for reopening the window after an external edit.
    func reloadFromDisk() throws {
        document = try ConfigDocument(url: document.url)
        saved = document.root
    }

    /// Copies the preset's collector on/off flags and label policies over the
    /// current tree, leaving paths, intervals and tokens alone.
    func applyPreset(_ preset: Preset) {
        guard let root = try? JSONValue.parse(Data(Presets.json(preset).utf8)),
              let collectors = root.objectValue?["collectors"]?.objectValue else { return }
        for name in CollectorRegistry.knownNames {
            if let enabled = collectors[name]?.objectValue?["enabled"]?.boolValue {
                setCollectorEnabled(name, enabled)
            }
        }
        for dimension in PrivacyCatalog.all {
            guard var policy = collectors[dimension.collector]?.objectValue?[dimension.key]?.objectValue else { continue }
            if (policy["salt"]?.stringValue ?? "").isEmpty {
                policy.removeValue(forKey: "salt")
                if let salt = get(dimension.path + ["salt"]) { policy["salt"] = salt }
            }
            set(dimension.path, .object(policy))
        }
    }

    var stateFiles: [String: URL] { Maintenance.stateFiles(folder: stateFolder) }

    /// Pauses collection first so a running collector cannot rewrite the
    /// cursor between the delete and the reload.
    func forgetData(collector: String) {
        pauseCollectors()
        do {
            let removed = try Maintenance.forget(collector: collector, folder: stateFolder)
            try reload()
            lastMessage = removed.isEmpty ? "\(collector) had no stored data" : "Forgot \(collector) data"
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    func forgetAllData() {
        pauseCollectors()
        do {
            let removed = try Maintenance.forgetAll(folder: stateFolder)
            try reload()
            lastMessage = "Forgot data for \(removed.count) collectors"
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// Saves the stack keys, then writes the stack's `.env` and recreates
    /// Prometheus on `queue`, reporting back on the main queue. The compose
    /// command goes through `run` so tests can stub Docker.
    func applyRetention(run: @escaping Maintenance.Runner = Maintenance.composeRunner,
                        queue: DispatchQueue = .global(qos: .userInitiated),
                        completion: @escaping (Result<String, Error>) -> Void) {
        guard retentionIsValid else {
            lastError = "retention must be a Prometheus duration like 90d or 2y"
            completion(.failure(ConfigError.invalid(lastError ?? "")))
            return
        }
        guard let dir = effectiveComposeDir else {
            lastError = "set the compose folder: no deploy/docker-compose.yml found near Molly"
            completion(.failure(ConfigError.invalid(lastError ?? "")))
            return
        }
        guard apply() else {
            completion(.failure(ConfigError.invalid(lastError ?? "save failed")))
            return
        }
        let retention = self.retention
        queue.async {
            let result = Result { try Maintenance.applyRetention(retention, composeDir: dir, run: run) }
            DispatchQueue.main.async {
                switch result {
                case .success: self.lastMessage = "Prometheus retention set to \(retention)"
                case .failure(let error): self.lastError = "\(error)"
                }
                completion(result)
            }
        }
    }
}
