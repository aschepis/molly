import Foundation
import MollyHealthCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    struct TotalRow: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    private let env = AppEnvironment.shared

    @Published var settings: AppSettings { didSet { settingsChanged(from: oldValue) } }
    @Published var token: String { didSet { env.keychain.save(token) } }
    @Published private(set) var state: SyncState
    @Published private(set) var totals: [TotalRow] = []
    @Published private(set) var busy = false
    @Published private(set) var backfillProgress: (done: Int, total: Int)?
    @Published private(set) var connectionReport: [String] = []
    @Published private(set) var authorizationError: String?

    let healthAvailable = HealthReader.isAvailable
    var log: LogRing { env.log }

    init() {
        settings = env.settingsStore.loadSettings()
        token = env.keychain.token()
        state = env.settingsStore.loadState()
    }

    var needsOnboarding: Bool { healthAvailable && !settings.hasRequestedAuthorization }

    func requestAuthorization() async {
        do {
            try await env.reader.requestAuthorization()
            settings.hasRequestedAuthorization = true
            authorizationError = nil
            env.log.append("Health authorisation requested")
            await refreshTotals()
        } catch {
            authorizationError = error.localizedDescription
            env.log.append("Health authorisation failed: \(error.localizedDescription)")
        }
    }

    func sendNow() async {
        busy = true
        await env.service.sync(force: true, reason: "send now")
        state = env.settingsStore.loadState()
        busy = false
        await refreshTotals()
    }

    func backfill() async {
        busy = true
        backfillProgress = (0, settings.backfillDays)
        await env.service.backfill { [weak self] done, total in
            Task { @MainActor in self?.backfillProgress = (done, total) }
        }
        backfillProgress = nil
        state = env.settingsStore.loadState()
        busy = false
    }

    func refreshTotals() async {
        let computed = await env.service.todaysTotals()
        totals = MollyHealthType.allCases.compactMap { type in
            guard settings.enabledTypes.contains(type) else { return nil }
            return TotalRow(id: type.rawValue, title: type.spec.title, text: Self.describe(computed[type]))
        }
    }

    func reloadState() {
        state = env.settingsStore.loadState()
    }

    func testConnection() async {
        guard let client = env.makeClient(settings: settings) else {
            connectionReport = ["The server URL is not a valid http(s) URL."]
            return
        }
        connectionReport = ["Testing..."]
        var lines: [String] = []
        switch await client.checkHealthz() {
        case .success: lines.append("healthz: ok")
        case .failure(let failure): lines.append("healthz: \(failure.message)")
        }
        if token.isEmpty {
            lines.append("status: no token set")
        } else {
            lines.append("status: " + (await client.fetchStatus()).message)
        }
        connectionReport = lines
        env.log.append("test connection: " + lines.joined(separator: "; "))
    }

    private func settingsChanged(from old: AppSettings) {
        env.settingsStore.save(settings)
        if old.enabledTypes != settings.enabledTypes, settings.hasRequestedAuthorization {
            env.background.startObservers(enabled: settings.enabledInCatalogOrder)
        }
        if !old.hasRequestedAuthorization, settings.hasRequestedAuthorization {
            env.background.startObservers(enabled: settings.enabledInCatalogOrder)
            env.background.scheduleRefresh()
        }
    }

    private static func describe(_ total: TotalValue?) -> String {
        switch total {
        case .none: return "no data (left out)"
        case .number(let n): return n.formatted(.number.precision(.fractionLength(0...2)))
        case .timestamp(let date): return date.formatted(date: .abbreviated, time: .shortened)
        }
    }
}
