import Foundation

/// Owns the collectors, schedules their `collect` calls, and publishes
/// self-metrics about them. Every collector runs on its own serial queue so a
/// slow one (a big history import) never delays the others.
final class CollectorManager {
    struct Status {
        let name: String
        let interval: TimeInterval
        var runs: Int = 0
        /// Failed runs. A source that is absent (`CollectorUnavailable`) is not an error.
        var errors: Int = 0
        var lastError: String?
        var lastSuccess: Date?
        var lastDuration: TimeInterval = 0
        var unavailable: Bool = false
        /// When the current unavailable streak began; nil while the source works.
        var unavailableSince: Date?
    }

    private struct Entry {
        let collector: Collector
        let queue: DispatchQueue
        var timer: DispatchSourceTimer?
    }

    let registry: MetricsRegistry
    private var entries: [Entry] = []
    private var statuses: [String: Status] = [:]
    private let lock = NSLock()
    private(set) var isPaused = false
    private(set) var isRunning = false

    private let runsTotal: Counter
    private let errorsTotal: Counter
    private let unavailableGauge: Gauge
    private let duration: Gauge
    private let lastSuccess: Gauge
    private let enabled: Gauge
    private let paused: Gauge

    init(registry: MetricsRegistry, collectors: [Collector]) {
        self.registry = registry
        runsTotal = registry.counter("molly_collector_runs_total", help: "Collector runs.", labels: ["collector"])
        errorsTotal = registry.counter("molly_collector_errors_total", help: "Collector runs that failed.", labels: ["collector"])
        unavailableGauge = registry.gauge("molly_collector_unavailable", help: "1 while the collector's source is absent or lacks a permission; not an error.", labels: ["collector"])
        duration = registry.gauge("molly_collector_duration_seconds", help: "Wall time of the last collector run.", labels: ["collector"])
        lastSuccess = registry.gauge("molly_collector_last_success_timestamp_seconds", help: "Unix time of the last successful run.", labels: ["collector"])
        enabled = registry.gauge("molly_collector_enabled", help: "1 when the collector is started.", labels: ["collector"])
        paused = registry.gauge("molly_paused", help: "1 while collection is paused from the menu bar.")
        paused.set(0)
        registry.gauge("molly_up", help: "1 while Molly is running.").set(1)
        registry.gauge("molly_build_info", help: "Build metadata.", labels: ["version"]).set(1, labels: ["version": Version.current])
        registry.gauge("molly_start_time_seconds", help: "Unix time Molly started.").set(Date().timeIntervalSince1970)
        PrivacyAudit.shared.attach(registry: registry)

        for collector in collectors {
            entries.append(Entry(collector: collector,
                                 queue: DispatchQueue(label: "molly.collector.\(collector.name)", qos: .utility)))
            statuses[collector.name] = Status(name: collector.name, interval: collector.interval)
            unavailableGauge.set(0, labels: ["collector": collector.name])
        }
    }

    var collectors: [Collector] { entries.map { $0.collector } }

    func collector<T: Collector>(as type: T.Type) -> T? {
        entries.lazy.compactMap { $0.collector as? T }.first
    }

    var allStatuses: [Status] {
        lock.lock()
        defer { lock.unlock() }
        return statuses.values.sorted { $0.name < $1.name }
    }

    /// Starts every collector. Must be called on the main thread because
    /// collectors may register AppKit observers.
    func startAll() {
        guard !isRunning else { return }
        isRunning = true
        for index in entries.indices {
            let collector = entries[index].collector
            do {
                try collector.start(registry: registry)
                enabled.set(1, labels: ["collector": collector.name])
                runsTotal.touch(labels: ["collector": collector.name])
                errorsTotal.touch(labels: ["collector": collector.name])
            } catch {
                enabled.set(0, labels: ["collector": collector.name])
                record(collector.name, error: error, duration: 0)
                Log.error("collector \(collector.name) failed to start: \(error)")
                continue
            }
            guard collector.interval > 0 else { continue }
            let timer = DispatchSource.makeTimerSource(queue: entries[index].queue)
            timer.schedule(deadline: .now() + 1, repeating: collector.interval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.run(collector) }
            timer.resume()
            entries[index].timer = timer
        }
        Log.info("started \(entries.count) collectors")
    }

    func stopAll() {
        guard isRunning else { return }
        isRunning = false
        for index in entries.indices {
            entries[index].timer?.cancel()
            entries[index].timer = nil
            entries[index].collector.stop()
            enabled.set(0, labels: ["collector": entries[index].collector.name])
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        paused.set(1)
        for entry in entries { entry.timer?.suspend() }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        paused.set(0)
        for entry in entries { entry.timer?.resume() }
    }

    /// Runs every collector once, synchronously, in registration order.
    /// Used by `molly once` and tests.
    func collectAll() -> [String: Error] {
        var failures: [String: Error] = [:]
        for entry in entries {
            if let error = run(entry.collector) { failures[entry.collector.name] = error }
        }
        return failures
    }

    @discardableResult
    private func run(_ collector: Collector) -> Error? {
        let started = Date()
        do {
            try collector.collect()
            let elapsed = Date().timeIntervalSince(started)
            record(collector.name, error: nil, duration: elapsed)
            return nil
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            record(collector.name, error: error, duration: elapsed)
            return error
        }
    }

    private func record(_ name: String, error: Error?, duration elapsed: TimeInterval) {
        let labels = ["collector": name]
        runsTotal.inc(labels: labels)
        duration.set(elapsed, labels: labels)
        lock.lock()
        var status = statuses[name] ?? Status(name: name, interval: 0)
        status.runs += 1
        status.lastDuration = elapsed
        if let error {
            status.lastError = String(describing: error)
            let wasUnavailable = status.unavailable
            status.unavailable = error is CollectorUnavailable
            if !status.unavailable { status.errors += 1 }
            if status.unavailable {
                status.unavailableSince = status.unavailableSince ?? Date()
            } else {
                status.unavailableSince = nil
            }
            statuses[name] = status
            lock.unlock()
            unavailableGauge.set(status.unavailable ? 1 : 0, labels: labels)
            if !status.unavailable { errorsTotal.inc(labels: labels) }
            // An unavailable source is a one-time note, not a log flood.
            if !(error is CollectorUnavailable) || !wasUnavailable {
                Log.warn("collector \(name): \(error)")
            }
        } else {
            status.lastSuccess = Date()
            status.unavailable = false
            status.unavailableSince = nil
            statuses[name] = status
            lock.unlock()
            unavailableGauge.set(0, labels: labels)
            lastSuccess.set(Date().timeIntervalSince1970, labels: labels)
        }
    }
}

enum Version {
    static let current = "0.1.0"
}
