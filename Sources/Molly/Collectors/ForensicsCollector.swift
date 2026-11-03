import Foundation

// MARK: - Pure parsers (unit-tested)

enum CrashKind: String, CaseIterable {
    case crash, hang, spin, panic
}

struct CrashReport: Equatable {
    let kind: CrashKind
    let process: String
    let modified: Date
    let path: String
}

struct LastEntry: Equatable {
    let time: Date
}

enum ForensicsParse {
    static let kernelProcess = "kernel"
    static let panicFullPrefix = "panic-full-"
    static let unknownProcess = "unknown"
    /// Memory-pressure kill logs share the .ips extension but are not crashes.
    static let jetsamPrefix = "JetsamEvent"
    /// The .ips header is one JSON line; it never needs more than this.
    static let headerByteLimit = 8192

    private static let weekdays: Set<String> = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let timeFields = 4 // "Sep 11 2026 15:55" after the weekday

    private static func lastFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy HH:mm"
        return formatter
    }

    /// Output of `last -y reboot` or `last -y shutdown`: lines such as
    /// `reboot time    Fri Sep 11 2026 15:55`. Lines without a year (plain `last`),
    /// the blank line and the trailing "wtmp begins" line are skipped. Anything
    /// after the time, such as "still running", is ignored.
    static func lastEntries(_ output: String, command: String) -> [LastEntry] {
        let formatter = lastFormatter()
        var entries: [LastEntry] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.first == Substring(command),
                  let weekday = fields.firstIndex(where: { weekdays.contains(String($0)) }),
                  fields.count >= weekday + 1 + timeFields else { continue }
            let text = fields[(weekday + 1)..<(weekday + 1 + timeFields)].joined(separator: " ")
            if let time = formatter.date(from: text) { entries.append(LastEntry(time: time)) }
        }
        return entries.sorted { $0.time < $1.time }
    }

    /// Kind and process from a report filename; nil for files that are not reports
    /// (analytics, .diag, dotfiles).
    static func classify(filename: String) -> (kind: CrashKind, process: String)? {
        guard !filename.hasPrefix("."), !filename.hasPrefix(jetsamPrefix) else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        let stem = (filename as NSString).deletingPathExtension
        let kind: CrashKind
        switch ext {
        case "ips": kind = filename.hasPrefix(panicFullPrefix) ? .panic : .crash
        case "crash": kind = .crash
        case "hang": kind = .hang
        case "spin": kind = .spin
        case "panic": kind = .panic
        default: return nil
        }
        if kind == .panic { return (kind, kernelProcess) }
        let process = stem.components(separatedBy: "-").first ?? ""
        return (kind, process.isEmpty ? unknownProcess : process)
    }

    /// Process name from an .ips header line, for names that contain a dash.
    static func headerProcess(firstLine: String) -> String? {
        guard let data = firstLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = (object["app_name"] as? String) ?? (object["name"] as? String)
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Reports strictly newer than the cursor, so a report is never counted twice.
    static func fresh(_ reports: [CrashReport], after cursor: Double) -> [CrashReport] {
        reports.filter { $0.modified.timeIntervalSince1970 > cursor }
    }

    static func advanced(cursor: Double, past reports: [CrashReport]) -> Double {
        reports.map { $0.modified.timeIntervalSince1970 }.max().map { max($0, cursor) } ?? cursor
    }
}

// MARK: - Collector

/// Explains gaps and instability: boots, shutdowns and crash, hang and panic
/// reports. Counters start at `backfillSeconds` before launch (boots start at
/// launch) and are advanced by cursors in the StateStore.
final class ForensicsCollector: Collector {
    static let processesDefaults = LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 30)
    static let userReportsFolder = NSHomeDirectory() + "/Library/Logs/DiagnosticReports"
    static let systemReportsFolder = "/Library/Logs/DiagnosticReports"

    let name = "forensics"
    let interval: TimeInterval

    private static let commandTimeout: TimeInterval = 10
    private static let bootKey = "boot"
    private static let shutdownKey = "shutdown"
    private static let crashKey = "crashCursor"

    private let backfillSeconds: Double
    private let store: StateStore
    private let startedAt: Date
    private let reportFolders: [String]
    private let processFilter: LabelFilter

    private var boots: Counter?
    private var bootTime: Gauge?
    private var uptime: Gauge?
    private var shutdowns: Counter?
    private var crashes: Counter?
    private var crashesByProcess: Counter?
    private var lastCrash: Gauge?

    init(settings: CollectorSettings, stateFolder: URL = Paths.stateFolder, startedAt: Date = Date(),
         reportFolders: [String] = [ForensicsCollector.userReportsFolder, ForensicsCollector.systemReportsFolder]) throws {
        interval = settings.interval(default: 300)
        backfillSeconds = max(0, settings.double("backfillSeconds", default: 86400))
        store = StateStore(collector: "forensics", folder: stateFolder)
        self.startedAt = startedAt
        self.reportFolders = reportFolders
        processFilter = try settings.filter("processes", defaults: ForensicsCollector.processesDefaults)
    }

    func start(registry: MetricsRegistry) throws {
        boots = registry.counter("molly_boots_total", help: "Boots seen since Molly first ran.")
        bootTime = registry.gauge("molly_boot_timestamp_seconds", help: "Unix time of the current boot.")
        uptime = registry.gauge("molly_uptime_seconds", help: "Seconds since the current boot.")
        shutdowns = registry.counter("molly_shutdowns_total", help: "Shutdowns recorded by `last shutdown`.")
        crashes = registry.counter("molly_crash_reports_total", help: "Crash, hang, spin and panic reports.", labels: ["kind"])
        crashesByProcess = registry.counter("molly_crash_reports_by_process_total", help: "Crash reports per process (needs the processes label policy enabled).", labels: ["kind", "process"])
        lastCrash = registry.gauge("molly_last_crash_timestamp_seconds", help: "Modification time of the newest report on disk.")
        boots?.touch()
        shutdowns?.touch()
        for kind in CrashKind.allCases { crashes?.touch(labels: ["kind": kind.rawValue]) }
    }

    func collect() throws {
        let reports = try readReports()
        collectBoot()
        collectShutdowns()
        collectCrashes(reports)
        do { try store.save() } catch { Log.warn("forensics: cannot save state: \(error)") }
    }

    // MARK: boots and shutdowns

    private func collectBoot() {
        guard let boot = currentBoot() else { return }
        let seconds = boot.timeIntervalSince1970
        if PowerParse.isNewBoot(seconds, lastSeen: store.double(Self.bootKey), floor: startedAt.timeIntervalSince1970) { boots?.inc() }
        store.set(Self.bootKey, seconds)
        bootTime?.set(seconds)
        uptime?.set(max(0, Date().timeIntervalSince1970 - seconds))
    }

    private func currentBoot() -> Date? {
        if let result = try? Shell.run("/usr/sbin/sysctl", ["-n", "kern.boottime"], timeout: Self.commandTimeout), result.succeeded,
           let boot = PowerParse.bootTime(sysctl: result.stdout) { return boot }
        return lastOutput("reboot").flatMap { ForensicsParse.lastEntries($0, command: "reboot").last?.time }
    }

    private func collectShutdowns() {
        guard let output = lastOutput("shutdown") else { return }
        let floor = startedAt.timeIntervalSince1970 - backfillSeconds
        let cursor = store.double(Self.shutdownKey) ?? floor
        let fresh = ForensicsParse.lastEntries(output, command: "shutdown").filter { $0.time.timeIntervalSince1970 > cursor }
        shutdowns?.add(Double(fresh.count))
        store.set(Self.shutdownKey, fresh.last?.time.timeIntervalSince1970 ?? cursor)
    }

    private func lastOutput(_ command: String) -> String? {
        guard let result = try? Shell.run("/usr/bin/last", ["-y", command], timeout: Self.commandTimeout), result.succeeded else { return nil }
        return result.stdout
    }

    // MARK: crash reports

    private func collectCrashes(_ reports: [CrashReport]) {
        let floor = startedAt.timeIntervalSince1970 - backfillSeconds
        let cursor = store.double(Self.crashKey) ?? floor
        let fresh = ForensicsParse.fresh(reports, after: cursor)
        for report in fresh { crashes?.inc(labels: ["kind": report.kind.rawValue]) }
        publishByProcess(fresh)
        store.set(Self.crashKey, ForensicsParse.advanced(cursor: cursor, past: fresh))
        if let newest = reports.map({ $0.modified.timeIntervalSince1970 }).max() { lastCrash?.set(newest) }
    }

    private func publishByProcess(_ fresh: [CrashReport]) {
        guard processFilter.enabled else { return }
        for kind in CrashKind.allCases {
            var counts: [String: Double] = [:]
            for report in fresh where report.kind == kind { counts[processName(report), default: 0] += 1 }
            for (process, n) in processFilter.labels(counts) {
                crashesByProcess?.add(n, labels: ["kind": kind.rawValue, "process": process])
            }
        }
    }

    private func processName(_ report: CrashReport) -> String {
        guard report.path.hasSuffix(".ips"), report.kind == .crash,
              let line = Self.firstLine(ofFileAt: report.path),
              let name = ForensicsParse.headerProcess(firstLine: line) else { return report.process }
        return name
    }

    private static func firstLine(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ForensicsParse.headerByteLimit) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    private func readReports() throws -> [CrashReport] {
        var reports: [CrashReport] = []
        for (index, folder) in reportFolders.enumerated() {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder)
            } catch {
                guard index == 0, FileManager.default.fileExists(atPath: folder) else { continue }
                throw CollectorUnavailable(reason: "cannot read \(folder); grant Full Disk Access to the host process")
            }
            for filename in names {
                guard let info = ForensicsParse.classify(filename: filename) else { continue }
                let path = folder + "/" + filename
                guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                reports.append(CrashReport(kind: info.kind, process: info.process, modified: modified, path: path))
            }
        }
        return reports
    }
}
