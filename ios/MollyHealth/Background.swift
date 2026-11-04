import BackgroundTasks
import Foundation
import HealthKit
import MollyHealthCore

/// Everything the app shares between SwiftUI, HealthKit callbacks and BGTaskScheduler.
final class AppEnvironment: @unchecked Sendable {
    static let shared = AppEnvironment()

    let log = LogRing()
    let reader = HealthReader()
    let settingsStore = SettingsStore()
    let keychain = KeychainTokenStore()
    let uploader: Uploader
    let service: SyncService
    let background: BackgroundCoordinator

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = PostClient.requestTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        uploader = Uploader(session: session)
        service = SyncService(reader: reader, uploader: uploader, settingsStore: settingsStore, keychain: keychain, log: log)
        background = BackgroundCoordinator(reader: reader, service: service, log: log)
    }

    func makeClient(settings: AppSettings) -> PostClient? {
        guard let base = settings.baseURL else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = PostClient.requestTimeout
        return PostClient(session: URLSession(configuration: configuration), server: ServerConfig(baseURL: base, token: keychain.token()))
    }
}

/// HKObserverQuery with hourly background delivery is the primary trigger; a
/// BGAppRefreshTask covers the case where HealthKit does not wake the app.
final class BackgroundCoordinator: @unchecked Sendable {
    static let refreshIdentifier = "com.aschepis.molly.health.refresh"
    private static let refreshInterval: TimeInterval = 60 * 60

    private let reader: HealthReader
    private let service: SyncService
    private let log: LogRing
    private let lock = NSLock()
    private var observers: [HKObserverQuery] = []

    init(reader: HealthReader, service: SyncService, log: LogRing) {
        self.reader = reader
        self.service = service
        self.log = log
    }

    /// Must run before the app finishes launching.
    func registerRefreshTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { [weak self] task in
            guard let self, let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(refresh)
        }
    }

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(Self.refreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.append("could not schedule background refresh: \(error.localizedDescription)")
        }
    }

    /// Replaces any earlier observers, so toggling a type takes effect without a relaunch.
    func startObservers(enabled: [MollyHealthType]) {
        guard HealthReader.isAvailable else { return }
        lock.lock()
        observers.forEach { reader.store.stop($0) }
        observers = []
        lock.unlock()

        let enabledSet = Set(enabled)
        for type in MollyHealthType.allCases where !enabledSet.contains(type) {
            reader.store.disableBackgroundDelivery(for: reader.sampleType(for: type)) { _, _ in }
        }
        var seen = Set<String>()
        for type in enabled {
            let sampleType = reader.sampleType(for: type)
            guard seen.insert(sampleType.identifier).inserted else { continue }
            observe(sampleType)
        }
        log.append("observing \(seen.count) Health types")
    }

    private func observe(_ sampleType: HKSampleType) {
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completion, error in
            guard let self else {
                completion()
                return
            }
            if let error {
                self.log.append("observer \(sampleType.identifier): \(error.localizedDescription)")
                completion()
                return
            }
            Task {
                await self.service.sync(force: false, reason: "health delivery")
                completion()
            }
        }
        reader.store.execute(query)
        reader.store.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { [log] _, error in
            if let error { log.append("background delivery \(sampleType.identifier): \(error.localizedDescription)") }
        }
        lock.lock()
        observers.append(query)
        lock.unlock()
    }

    private func handle(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            await service.sync(force: false, reason: "background refresh")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
