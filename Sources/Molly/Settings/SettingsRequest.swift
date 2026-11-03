import Foundation

enum SettingsTab: String, CaseIterable {
    case collectors, privacy, server, agents, maintenance

    static func parse(_ name: String) -> SettingsTab? {
        SettingsTab(rawValue: name.lowercased())
    }
}

/// What `molly settings` sends the daemon over DistributedNotificationCenter.
struct SettingsRequest: Equatable {
    static let notificationName = Notification.Name("com.aschepis.molly.openSettings")

    var tab: SettingsTab?
    var close: Bool
    var snapshotPath: String?

    var userInfo: [String: String] {
        var info: [String: String] = [:]
        if let tab { info["tab"] = tab.rawValue }
        if close { info["close"] = "1" }
        if let snapshotPath { info["snapshot"] = snapshotPath }
        return info
    }

    init(tab: SettingsTab? = nil, close: Bool = false, snapshotPath: String? = nil) {
        self.tab = tab
        self.close = close
        self.snapshotPath = snapshotPath
    }

    init(userInfo: [AnyHashable: Any]?) {
        let info = userInfo ?? [:]
        tab = (info["tab"] as? String).flatMap(SettingsTab.parse)
        close = (info["close"] as? String) == "1"
        snapshotPath = info["snapshot"] as? String
    }
}
