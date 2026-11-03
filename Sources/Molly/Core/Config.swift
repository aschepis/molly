import Foundation

enum ConfigError: Error, CustomStringConvertible {
    case invalid(String)
    case unreadable(String)

    var description: String {
        switch self {
        case .invalid(let why): return "invalid config: \(why)"
        case .unreadable(let why): return "cannot read config: \(why)"
        }
    }
}

/// The effective configuration. Missing file or missing keys mean defaults.
/// Collector sections are kept raw (see `CollectorSettings`) so adding a
/// collector never requires touching this file.
struct Config {
    struct Server: Equatable {
        var bind = "127.0.0.1"
        var port = 9765
    }

    struct Labels: Equatable {
        var user: String?
        var host: String?
        var extra: [String: String] = [:]
    }

    struct Links: Equatable {
        var grafana = "http://localhost:3030"
        var prometheus = "http://localhost:9090"
    }

    var server = Server()
    var labels = Labels()
    var links = Links()
    var logLevel = "info"
    var collectors: [String: JSONValue] = [:]

    static let defaultUser = NSUserName()
    static let defaultHost: String = {
        var name = ProcessInfo.processInfo.hostName
        if let dot = name.firstIndex(of: ".") { name = String(name[..<dot]) }
        return name
    }()

    /// Labels attached to every metric: user and host always, plus extras.
    var constLabels: [String: String] {
        var all = labels.extra
        all["user"] = labels.user ?? Config.defaultUser
        all["host"] = labels.host ?? Config.defaultHost
        return all
    }

    func collector(_ name: String) -> CollectorSettings {
        CollectorSettings(name: name, raw: collectors[name]?.objectValue ?? [:])
    }

    static func load(from url: URL = Paths.configFile) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable("\(url.path): \(error.localizedDescription)")
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Config {
        let json: JSONValue
        do {
            json = try JSONValue.parse(data)
        } catch {
            throw ConfigError.invalid("not valid JSON: \(error.localizedDescription)")
        }
        guard let root = json.objectValue else { throw ConfigError.invalid("top level must be an object") }
        var config = Config()

        if let server = root["server"] {
            guard let o = server.objectValue else { throw ConfigError.invalid("server must be an object") }
            if let v = o["bind"] {
                guard let s = v.stringValue, !s.isEmpty else { throw ConfigError.invalid("server.bind must be a string") }
                config.server.bind = s
            }
            if let v = o["port"] {
                guard let n = v.intValue, (1...65535).contains(n) else { throw ConfigError.invalid("server.port must be 1-65535") }
                config.server.port = n
            }
        }
        if let labels = root["labels"] {
            guard let o = labels.objectValue else { throw ConfigError.invalid("labels must be an object") }
            config.labels.user = o["user"]?.stringValue
            config.labels.host = o["host"]?.stringValue
            if let extra = o["extra"] {
                guard let eo = extra.objectValue else { throw ConfigError.invalid("labels.extra must be an object") }
                for (k, v) in eo {
                    guard Metrics.isValidLabelName(k) else { throw ConfigError.invalid("labels.extra: bad label name \(k)") }
                    guard let s = v.stringValue else { throw ConfigError.invalid("labels.extra.\(k) must be a string") }
                    config.labels.extra[k] = s
                }
            }
        }
        if let links = root["links"] {
            guard let o = links.objectValue else { throw ConfigError.invalid("links must be an object") }
            if let s = o["grafana"]?.stringValue { config.links.grafana = s }
            if let s = o["prometheus"]?.stringValue { config.links.prometheus = s }
        }
        if let level = root["logLevel"] {
            guard let s = level.stringValue, Log.Level(rawValue: s) != nil else {
                throw ConfigError.invalid("logLevel must be debug|info|warn|error")
            }
            config.logLevel = s
        }
        if let collectors = root["collectors"] {
            guard let o = collectors.objectValue else { throw ConfigError.invalid("collectors must be an object") }
            for (name, section) in o {
                guard section.objectValue != nil else { throw ConfigError.invalid("collectors.\(name) must be an object") }
            }
            config.collectors = o
        }
        return config
    }
}

/// Typed access to one collector's config section. Every getter takes a
/// default so collectors work with an empty or missing section.
struct CollectorSettings {
    let name: String
    let raw: [String: JSONValue]

    var isEmpty: Bool { raw.isEmpty }

    /// Collectors are on unless the section says otherwise. Sensitive
    /// collectors pass `default: false` and require an explicit opt-in.
    func enabled(default value: Bool = true) -> Bool { bool("enabled", default: value) }

    func interval(default value: TimeInterval) -> TimeInterval {
        let v = double("interval", default: value)
        return v > 0 ? v : value
    }

    func bool(_ key: String, default value: Bool) -> Bool {
        raw[key]?.boolValue ?? value
    }

    func int(_ key: String, default value: Int) -> Int {
        raw[key]?.intValue ?? value
    }

    func double(_ key: String, default value: Double) -> Double {
        raw[key]?.doubleValue ?? value
    }

    func string(_ key: String, default value: String) -> String {
        raw[key]?.stringValue ?? value
    }

    func strings(_ key: String, default value: [String] = []) -> [String] {
        guard let array = raw[key]?.arrayValue else { return value }
        return array.compactMap { $0.stringValue }
    }

    /// Reads a label policy sub-object; a missing key yields `defaults`.
    func policy(_ key: String, defaults: LabelPolicy = LabelPolicy()) throws -> LabelPolicy {
        do {
            return try LabelPolicy.from(raw[key], defaults: defaults)
        } catch ConfigError.invalid(let why) {
            throw ConfigError.invalid("collectors.\(name).\(key): \(why)")
        }
    }

    func filter(_ key: String, defaults: LabelPolicy = LabelPolicy()) throws -> LabelFilter {
        try policy(key, defaults: defaults).compile()
    }

    func section(_ key: String) -> CollectorSettings {
        CollectorSettings(name: "\(name).\(key)", raw: raw[key]?.objectValue ?? [:])
    }
}
