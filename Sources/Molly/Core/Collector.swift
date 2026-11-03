import Foundation

/// A source of metrics. `start` registers metrics and any event observers;
/// `collect` runs every `interval` seconds on a background queue. Throwing
/// from `collect` is counted and logged but never stops the app.
protocol Collector: AnyObject {
    var name: String { get }
    /// Seconds between `collect` calls. 0 means event-driven only.
    var interval: TimeInterval { get }
    func start(registry: MetricsRegistry) throws
    func collect() throws
    func stop()
}

extension Collector {
    func collect() throws {}
    func stop() {}
}

/// Thrown by collectors whose data source is unavailable in a way the user
/// must fix (a missing permission, an absent app). Logged once, not per run.
struct CollectorUnavailable: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}
