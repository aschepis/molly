import Foundation
import MollyHealthCore

/// Reads Health, builds the payloads and hands them to the Uploader. Used by the
/// buttons, the HealthKit observers and the background refresh task alike.
actor SyncService {
    private let reader: HealthReader
    private let uploader: Uploader
    private let settingsStore: SettingsStore
    private let keychain: KeychainTokenStore
    private let log: LogRing
    private var inFlight: Task<Void, Never>?

    init(reader: HealthReader, uploader: Uploader, settingsStore: SettingsStore, keychain: KeychainTokenStore, log: LogRing) {
        self.reader = reader
        self.uploader = uploader
        self.settingsStore = settingsStore
        self.keychain = keychain
        self.log = log
    }

    /// Posts today, and yesterday when the date changed since the last post.
    /// Overlapping calls (several observers firing at once) share one run.
    func sync(force: Bool, reason: String) async {
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { await self.runSync(force: force, reason: reason) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    func todaysTotals() async -> [MollyHealthType: TotalValue] {
        let settings = settingsStore.loadSettings()
        let calendar = Calendar.current
        let readings = await reader.readings(for: Date(), types: settings.enabledInCatalogOrder, calendar: calendar, log: log)
        return DayTotalsBuilder.build(window: DayKey.window(for: Date(), calendar: calendar), readings: readings)
    }

    /// One post per day, oldest first, stopping at the first failure that would repeat.
    func backfill(progress: @escaping @Sendable (Int, Int) -> Void) async {
        let settings = settingsStore.loadSettings()
        guard let server = serverConfig(settings) else { return }
        let calendar = Calendar.current
        let days = BackfillPlanner.days(count: settings.backfillDays, endingOn: Date(), calendar: calendar)
        log.append("backfill: \(days.count) days")
        var summary = Summary()
        for (index, day) in days.enumerated() {
            progress(index, days.count)
            guard let item = await item(for: day, settings: settings, calendar: calendar) else { continue }
            let results = await uploader.submit([item], to: server, force: true)
            summary.add(results, log: log)
            if summary.error != nil { break }
        }
        progress(days.count, days.count)
        finish(summary, todayKey: DayKey.string(for: Date(), calendar: calendar))
    }

    private func runSync(force: Bool, reason: String) async {
        let settings = settingsStore.loadSettings()
        guard let server = serverConfig(settings) else { return }
        let calendar = Calendar.current
        let state = settingsStore.loadState()
        let days = BackfillPlanner.daysToRefresh(today: Date(), lastPostedDay: state.lastPostedDay, calendar: calendar)
        log.append("sync (\(reason)\(force ? ", forced" : "")): \(days.count) day(s)")
        var items: [UploadItem] = []
        for day in days {
            if let item = await item(for: day, settings: settings, calendar: calendar) { items.append(item) }
        }
        guard !items.isEmpty else {
            log.append("nothing to send")
            return
        }
        var summary = Summary()
        summary.add(await uploader.submit(items, to: server, force: force), log: log)
        if summary.attempted {
            finish(summary, todayKey: DayKey.string(for: Date(), calendar: calendar))
        }
    }

    private func serverConfig(_ settings: AppSettings) -> ServerConfig? {
        let token = keychain.token()
        guard let base = settings.baseURL else {
            fail("server URL is not a valid http(s) URL")
            return nil
        }
        guard !token.isEmpty else {
            fail("no token set")
            return nil
        }
        return ServerConfig(baseURL: base, token: token)
    }

    private func fail(_ message: String) {
        log.append("error: \(message)")
        var state = settingsStore.loadState()
        state.lastAttempt = Date()
        state.lastError = message
        settingsStore.save(state)
    }

    private func item(for day: Date, settings: AppSettings, calendar: Calendar) async -> UploadItem? {
        let readings = await reader.readings(for: day, types: settings.enabledInCatalogOrder, calendar: calendar, log: log)
        let totals = DayTotalsBuilder.build(window: DayKey.window(for: day, calendar: calendar), readings: readings)
        let key = DayKey.string(for: day, calendar: calendar)
        guard !totals.isEmpty else {
            log.append("\(key): no totals, skipped")
            return nil
        }
        let payload = HealthPayload.make(device: settings.sanitizedDeviceName, date: key, totals: totals, calendar: calendar)
        do {
            return UploadItem(date: key, body: try payload.encoded())
        } catch {
            log.append("\(key): could not build payload (\(error))")
            return nil
        }
    }

    private func finish(_ summary: Summary, todayKey: String) {
        var state = settingsStore.loadState()
        state.lastAttempt = Date()
        state.lastHTTPStatus = summary.status
        state.lastAccepted = summary.status == nil ? nil : summary.accepted
        state.lastRejected = summary.rejected
        state.lastError = summary.error
        if summary.postedDays.contains(todayKey) { state.lastPostedDay = todayKey }
        settingsStore.save(state)
    }

    /// Totals of one run across its days.
    private struct Summary {
        var attempted = false
        var status: Int?
        var accepted = 0
        var rejected: [String: Int] = [:]
        var error: String?
        var postedDays: Set<String> = []

        mutating func add(_ results: [(date: String, result: UploadResult)], log: LogRing) {
            for (date, result) in results {
                switch result {
                case .debounced:
                    log.append("\(date): debounced, last post under \(Int(Uploader.debounceInterval / 60)) min ago")
                case .sent(let reply):
                    attempted = true
                    status = reply.status
                    accepted += reply.accepted ?? 0
                    for (reason, count) in reply.rejected { rejected[reason, default: 0] += count }
                    postedDays.insert(date)
                    log.append("\(date): HTTP \(reply.status), accepted \(reply.accepted ?? 0), rejected \(reply.rejectedCount)")
                case .failed(let failure):
                    attempted = true
                    status = failure.httpStatus ?? status
                    error = failure.message
                    log.append("\(date): failed, \(failure.message)")
                }
            }
        }
    }
}
