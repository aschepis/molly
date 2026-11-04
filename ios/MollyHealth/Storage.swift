import Foundation
import MollyHealthCore
import Security

/// The token needs to be readable while the phone is locked, because background
/// deliveries run then; hence AfterFirstUnlock.
struct KeychainTokenStore: @unchecked Sendable {
    private let service = "com.aschepis.molly.health"
    private let account = "token"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func token() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func save(_ token: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !token.isEmpty else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}

/// Settings and the last upload's outcome, as JSON in UserDefaults.
struct SettingsStore: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let settingsKey = "settings.v1"
    private let stateKey = "syncState.v1"

    func loadSettings() -> AppSettings { load(settingsKey) ?? AppSettings() }
    func save(_ settings: AppSettings) { store(settings, settingsKey) }
    func loadState() -> SyncState { load(stateKey) ?? SyncState() }
    func save(_ state: SyncState) { store(state, stateKey) }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
