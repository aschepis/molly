import Foundation

/// Browsing activity from each browser's local history database. Only counts
/// and (policy-gated) host names leave this file; URLs and titles are read to
/// derive a host and then dropped.
enum BrowserSchema {
    case safari, chromium, firefox

    var visitsSQL: String {
        switch self {
        case .safari:
            return "SELECT i.url AS url, v.visit_time AS t FROM history_visits v JOIN history_items i ON i.id = v.history_item WHERE v.visit_time > ? AND v.visit_time <= ?"
        case .chromium:
            return "SELECT u.url AS url, v.visit_time AS t FROM visits v JOIN urls u ON u.id = v.url WHERE v.visit_time > ? AND v.visit_time <= ?"
        case .firefox:
            return "SELECT p.url AS url, v.visit_date AS t FROM moz_historyvisits v JOIN moz_places p ON p.id = v.place_id WHERE v.visit_date > ? AND v.visit_date <= ?"
        }
    }

    var rowCountSQL: String {
        switch self {
        case .safari: return "SELECT count(*) FROM history_items"
        case .chromium: return "SELECT count(*) FROM urls"
        case .firefox: return "SELECT count(*) FROM moz_places"
        }
    }

    /// Safari stores real seconds, so a one-microsecond nudge keeps a float
    /// round trip from recounting the visit that set the cursor.
    func native(fromUnix unix: Double) -> SQLiteValue {
        switch self {
        case .safari: return .real(unix - CocoaTime.cocoaOffset + 1e-6)
        case .chromium: return .integer(Int64(((unix + CocoaTime.webKitOffset) * 1e6).rounded()))
        case .firefox: return .integer(Int64((unix * 1e6).rounded()))
        }
    }

    func unix(fromNative value: Double) -> Double {
        switch self {
        case .safari: return value + CocoaTime.cocoaOffset
        case .chromium: return value / 1e6 - CocoaTime.webKitOffset
        case .firefox: return value / 1e6
        }
    }
}

struct BrowserProfile: Equatable {
    let browser: String
    let schema: BrowserSchema
    let path: String

    /// Stable cursor key; the path distinguishes profiles of one browser.
    var cursorKey: String { "cursor.\(browser).\(path)" }
}

struct BrowserVisits {
    var count = 0
    var domains: [String: Int] = [:]
    var newestUnix: Double?
}

enum BrowserQueries {
    static let webSchemes: Set<String> = ["http", "https", "ftp"]

    /// Host of a web URL, lowercased, without scheme, userinfo or port.
    /// "www." and punycode are left alone so labels match what the user typed.
    static func domain(fromURL url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        guard webSchemes.contains(url[..<schemeEnd.lowerBound].lowercased()) else { return nil }
        var authority = url[schemeEnd.upperBound...]
        if let end = authority.firstIndex(where: { "/?#".contains($0) }) {
            authority = authority[..<end]
        }
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        var host = String(authority)
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") { host = String(host[...close]) }
        } else if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        host = host.lowercased()
        return host.isEmpty ? nil : host
    }

    static func visits(db: SQLiteDatabase, schema: BrowserSchema, after: Double, upTo: Double) throws -> BrowserVisits {
        let rows = try db.query(schema.visitsSQL, bindings: [schema.native(fromUnix: after), schema.native(fromUnix: upTo)])
        var result = BrowserVisits()
        for row in rows {
            result.count += 1
            if let t = row["t"].double {
                let unix = schema.unix(fromNative: t)
                result.newestUnix = max(result.newestUnix ?? unix, unix)
            }
            if let url = row["url"].string, let host = domain(fromURL: url) {
                result.domains[host, default: 0] += 1
            }
        }
        return result
    }

    static func historyRows(db: SQLiteDatabase, schema: BrowserSchema) throws -> Int {
        Int(try db.scalar(schema.rowCountSQL).int ?? 0)
    }
}

enum BrowserDetector {
    struct Candidate {
        let browser: String
        let root: String
    }

    static let chromiumFamily: [Candidate] = [
        Candidate(browser: "chrome", root: "~/Library/Application Support/Google/Chrome"),
        Candidate(browser: "chrome_beta", root: "~/Library/Application Support/Google/Chrome Beta"),
        Candidate(browser: "chrome_canary", root: "~/Library/Application Support/Google/Chrome Canary"),
        Candidate(browser: "brave", root: "~/Library/Application Support/BraveSoftware/Brave-Browser"),
        Candidate(browser: "arc", root: "~/Library/Application Support/Arc/User Data"),
        Candidate(browser: "edge", root: "~/Library/Application Support/Microsoft Edge"),
        Candidate(browser: "vivaldi", root: "~/Library/Application Support/Vivaldi"),
    ]

    static func schema(forBrowser name: String) -> BrowserSchema {
        switch name {
        case "safari", "orion": return .safari
        case "firefox": return .firefox
        default: return .chromium
        }
    }

    /// Existing history files for the allowed browsers plus configured extras.
    static func detect(allowed: Set<String>, extras: [BrowserProfile], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [BrowserProfile] {
        func allows(_ browser: String) -> Bool { allowed.isEmpty || allowed.contains(browser) }
        var found: [BrowserProfile] = []
        func add(_ browser: String, _ schema: BrowserSchema, _ path: String) {
            if fileExists(path) { found.append(BrowserProfile(browser: browser, schema: schema, path: path)) }
        }

        if allows("safari") { add("safari", .safari, Paths.expand("~/Library/Safari/History.db")) }
        for candidate in chromiumFamily where allows(candidate.browser) {
            let root = Paths.expand(candidate.root)
            for directory in subdirectories(of: root, matching: { $0 == "Default" || $0.hasPrefix("Profile ") }) {
                add(candidate.browser, .chromium, "\(root)/\(directory)/History")
            }
        }
        if allows("firefox") {
            let root = Paths.expand("~/Library/Application Support/Firefox/Profiles")
            for directory in subdirectories(of: root, matching: { _ in true }) {
                add("firefox", .firefox, "\(root)/\(directory)/places.sqlite")
            }
        }
        if allows("orion") { add("orion", .safari, Paths.expand("~/Library/Application Support/Orion/Defaults/history")) }

        for extra in extras where allows(extra.browser) && fileExists(extra.path) && !found.contains(extra) {
            found.append(extra)
        }
        return found
    }

    private static func subdirectories(of root: String, matching predicate: (String) -> Bool) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.filter(predicate).sorted()
    }

    static func parseExtras(_ settings: CollectorSettings) -> [BrowserProfile] {
        guard let entries = settings.raw["extraProfiles"]?.arrayValue else { return [] }
        return entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let browser = object["browser"]?.stringValue?.lowercased(),
                  let path = object["path"]?.stringValue, !path.isEmpty else { return nil }
            return BrowserProfile(browser: browser, schema: schema(forBrowser: browser), path: Paths.expand(path))
        }
    }
}

final class BrowserCollector: Collector {
    static let domainsDefaults = LabelPolicy(enabled: false, mode: .denylist, maxCardinality: 50)
    let name = "browser"
    let interval: TimeInterval

    private let allowed: Set<String>
    private let extras: [BrowserProfile]
    private let domainFilter: LabelFilter
    private let store: StateStore
    private let startedAt: Date
    private let now: () -> Date
    private let calendar: Calendar
    private var reportedUnreadable: Set<String> = []

    private var available: Gauge?
    private var visitsTotal: Counter?
    private var visitsToday: Gauge?
    private var distinctDomainsToday: Gauge?
    private var domainVisitsTotal: Counter?
    private var domainVisitsToday: Gauge?
    private var historyRows: Gauge?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) throws {
        interval = settings.interval(default: 60)
        allowed = Set(settings.strings("browsers").map { $0.lowercased() })
        extras = BrowserDetector.parseExtras(settings)
        domainFilter = try settings.filter("domains", defaults: BrowserCollector.domainsDefaults)
        store = StateStore(collector: "browser", folder: stateFolder)
        self.now = now
        self.calendar = calendar
        startedAt = now()
    }

    func start(registry: MetricsRegistry) throws {
        available = registry.gauge("molly_browser_available", help: "1 when the browser's history database was readable on the last run, 0 when detected but unreadable.", labels: ["browser"])
        visitsTotal = registry.counter("molly_browser_visits_total", help: "Page visits recorded in browser history since Molly started watching.", labels: ["browser"])
        visitsToday = registry.gauge("molly_browser_visits_today", help: "Page visits recorded since local midnight.", labels: ["browser"])
        distinctDomainsToday = registry.gauge("molly_browser_distinct_domains_today", help: "Distinct hosts visited since local midnight.", labels: ["browser"])
        domainVisitsTotal = registry.counter("molly_browser_domain_visits_total", help: "Page visits per host (needs the domains label policy enabled).", labels: ["browser", "domain"])
        domainVisitsToday = registry.gauge("molly_browser_domain_visits_today", help: "Page visits per host since local midnight (needs the domains label policy enabled).", labels: ["browser", "domain"])
        historyRows = registry.gauge("molly_browser_history_rows", help: "Rows in the browser's URL table, a rough history size.", labels: ["browser"])
    }

    func collect() throws {
        let profiles = BrowserDetector.detect(allowed: allowed, extras: extras)
        guard !profiles.isEmpty else {
            throw CollectorUnavailable(reason: "no browser history databases found")
        }
        let current = now()
        let dayStart = calendar.startOfDay(for: current).timeIntervalSince1970
        let nowUnix = current.timeIntervalSince1970

        var readable = 0
        var todayCount: [String: Int] = [:]
        var todayDomains: [String: [String: Int]] = [:]
        var rows: [String: Int] = [:]

        for profile in profiles {
            do {
                let db = try SQLiteSnapshot.open(path: profile.path)
                try ingest(profile: profile, db: db, dayStart: dayStart, nowUnix: nowUnix,
                           todayCount: &todayCount, todayDomains: &todayDomains, rows: &rows)
                readable += 1
            } catch {
                reportOnce(profile, error)
            }
        }

        for browser in Set(profiles.map { $0.browser }) {
            available?.set(rows[browser] != nil ? 1 : 0, labels: ["browser": browser])
        }
        publishToday(todayCount: todayCount, todayDomains: todayDomains, rows: rows)
        do { try store.save() } catch { Log.warn("browser: cannot save cursors: \(error)") }
        if readable == 0 {
            throw CollectorUnavailable(reason: "no browser history database is readable (Safari needs Full Disk Access)")
        }
    }

    private func ingest(profile: BrowserProfile, db: SQLiteDatabase, dayStart: Double, nowUnix: Double,
                        todayCount: inout [String: Int], todayDomains: inout [String: [String: Int]], rows: inout [String: Int]) throws {
        let browser = profile.browser
        let labels = ["browser": browser]

        let cursor = store.double(profile.cursorKey) ?? startedAt.timeIntervalSince1970
        let fresh = try BrowserQueries.visits(db: db, schema: profile.schema, after: cursor, upTo: nowUnix)
        let today = try BrowserQueries.visits(db: db, schema: profile.schema, after: dayStart, upTo: nowUnix)
        let rowCount = try BrowserQueries.historyRows(db: db, schema: profile.schema)

        visitsTotal?.add(Double(fresh.count), labels: labels)
        if domainFilter.enabled {
            for (domain, n) in domainFilter.labels(fresh.domains.mapValues(Double.init)) {
                domainVisitsTotal?.add(n, labels: ["browser": browser, "domain": domain])
            }
        }
        store.set(profile.cursorKey, max(cursor, fresh.newestUnix ?? cursor))

        todayCount[browser, default: 0] += today.count
        for (domain, n) in today.domains { todayDomains[browser, default: [:]][domain, default: 0] += n }
        rows[browser, default: 0] += rowCount
    }

    private func publishToday(todayCount: [String: Int], todayDomains: [String: [String: Int]], rows: [String: Int]) {
        domainVisitsToday?.reset()
        for (browser, count) in todayCount {
            let labels = ["browser": browser]
            visitsToday?.set(count, labels: labels)
            distinctDomainsToday?.set(todayDomains[browser]?.count ?? 0, labels: labels)
            if domainFilter.enabled {
                for (domain, n) in domainFilter.labels((todayDomains[browser] ?? [:]).mapValues(Double.init)) {
                    domainVisitsToday?.set(n, labels: ["browser": browser, "domain": domain])
                }
            }
        }
        for (browser, n) in rows { historyRows?.set(n, labels: ["browser": browser]) }
    }

    private func reportOnce(_ profile: BrowserProfile, _ error: Error) {
        guard reportedUnreadable.insert(profile.cursorKey).inserted else { return }
        Log.warn("browser: \(profile.browser) history unreadable: \(error)")
    }
}

extension Doctor {
    static func browserChecks(config: Config) -> [DoctorCommand.Check] {
        let settings = config.collector("browser")
        let allowed = Set(settings.strings("browsers").map { $0.lowercased() })
        let profiles = BrowserDetector.detect(allowed: allowed, extras: BrowserDetector.parseExtras(settings))
        let counts = Dictionary(grouping: profiles, by: { $0.browser }).mapValues { $0.count }
        let summary = counts.keys.sorted().map { "\($0)(\(counts[$0] ?? 0))" }.joined(separator: " ")
        var checks = [DoctorCommand.Check(name: "browsers", ok: !profiles.isEmpty, detail: profiles.isEmpty ? "no browser history found" : summary)]
        if let safari = profiles.first(where: { $0.browser == "safari" }) {
            let readable = FileHandle(forReadingAtPath: safari.path) != nil
            checks.append(DoctorCommand.Check(name: "safari history", ok: readable, detail: readable ? "readable" : "Full Disk Access needed"))
        }
        return checks
    }
}
