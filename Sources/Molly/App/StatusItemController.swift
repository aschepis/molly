import AppKit
import ServiceManagement
import UserNotifications

/// The menu bar presence. The icon being visible means Molly is collecting.
final class StatusItemController: NSObject, NSMenuDelegate {
    private var runtime: Runtime
    private let statusItem: NSStatusItem
    private let statusLine = NSMenuItem(title: "Recording", action: nil, keyEquivalent: "")
    private let scrapeLine = NSMenuItem(title: "Not scraped yet", action: nil, keyEquivalent: "")
    private let endpointLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let alertsLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let insightsItem = NSMenuItem(title: "Open Latest Insights", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let statusSubmenu = NSMenu(title: "Status")
    private let isBundled = MenuModel.isBundled(bundleURL: Bundle.main.bundleURL)
    private var settingsModel: SettingsModel?
    private static let snapshotDelay: TimeInterval = 0.6

    init(runtime: Runtime) {
        self.runtime = runtime
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Molly")
            image?.isTemplate = true
            button.image = image
        }
        statusItem.menu = buildMenu()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(settingsRequested(_:)),
            name: SettingsRequest.notificationName, object: nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for line in [statusLine, scrapeLine, endpointLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        alertsLine.action = #selector(openAlerts)
        alertsLine.target = self
        alertsLine.isHidden = true
        menu.addItem(alertsLine)
        let statusParent = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
        statusParent.submenu = statusSubmenu
        menu.addItem(statusParent)
        menu.addItem(.separator())
        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Grafana", #selector(openGrafana), key: "g"))
        menu.addItem(item("Open Prometheus", #selector(openPrometheus)))
        menu.addItem(item("Open /metrics", #selector(openMetrics)))
        menu.addItem(item("Collector Status", #selector(openCollectors)))
        insightsItem.action = #selector(openInsights)
        insightsItem.target = self
        menu.addItem(insightsItem)
        menu.addItem(.separator())
        menu.addItem(item("Run Doctor", #selector(runDoctor), key: "d"))
        menu.addItem(item("Open Data Folder", #selector(openDataFolder)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Reload Config", #selector(reloadConfig), key: "r"))
        // SMAppService only works from an app bundle; `swift run` users get the
        // LaunchAgent path (`molly install-agent`) instead.
        if isBundled {
            launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
            launchAtLoginItem.target = self
        } else {
            launchAtLoginItem.title = "Launch at Login (install Molly.app first)"
            launchAtLoginItem.isEnabled = false
        }
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Molly", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu !== statusSubmenu else { return }
        let statuses = runtime.manager.allStatuses
        let failing = statuses.filter { $0.lastError != nil && $0.lastSuccess == nil }.count
        let state = runtime.manager.isPaused ? "Paused" : "Recording"
        statusLine.title = "\(state) · \(statuses.count) collectors" + (failing > 0 ? " · \(failing) unavailable" : "")
        if let last = runtime.lastScrape {
            scrapeLine.title = "Scraped \(Int(Date().timeIntervalSince(last)))s ago"
        } else {
            scrapeLine.title = "Not scraped yet (is Prometheus running?)"
        }
        endpointLine.title = serverURL("/metrics")
        let firing = AlertsStatus.firingCount
        alertsLine.isHidden = firing == 0
        alertsLine.title = MenuModel.alertsLine(firing: firing)
        pauseItem.title = runtime.manager.isPaused ? "Resume" : "Pause"
        statusItem.button?.appearsDisabled = runtime.manager.isPaused
        insightsItem.isEnabled = MenuModel.hasInsights(folder: Paths.dataFolder.appendingPathComponent("insights"))
        if isBundled {
            launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        statusSubmenu.removeAllItems()
        for line in MenuModel.statusLines(statuses) {
            let entry = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            statusSubmenu.addItem(entry)
        }
    }

    @objc private func togglePause() {
        if runtime.manager.isPaused { runtime.manager.resume() } else { runtime.manager.pause() }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.info("launch at login disabled")
            } else {
                try service.register()
                Log.info("launch at login enabled")
            }
        } catch {
            Log.error("launch at login change failed: \(error)")
        }
    }

    @objc private func runDoctor() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checks = DoctorCommand.allChecks()
            let summary = MenuModel.doctorSummary(checks)
            for check in checks where !check.ok {
                Log.warn("doctor: \(check.name): \(check.detail)")
            }
            Log.info("doctor: \(summary)")
            DispatchQueue.main.async { self?.notify(title: "Molly doctor", body: summary) }
        }
    }

    /// User notifications need a bundle identifier; from `swift run` the log
    /// line is the only output.
    private func notify(title: String, body: String) {
        guard isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: "molly-doctor", content: content, trigger: nil))
        }
    }

    @objc private func openGrafana() { open(runtime.config.links.grafana) }
    @objc private func openAlerts() { open(MenuModel.healthDashboardURL(grafana: runtime.config.links.grafana)) }
    @objc private func openPrometheus() { open(runtime.config.links.prometheus) }
    @objc private func openMetrics() { open(serverURL("/metrics")) }
    @objc private func openCollectors() { open(serverURL("/collectors")) }
    @objc private func openInsights() { open(serverURL("/insights/latest")) }
    @objc private func openDataFolder() {
        try? FileManager.default.createDirectory(at: Paths.dataFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.dataFolder)
    }

    @objc private func reloadConfig() {
        do {
            try reloadRuntime()
        } catch {
            Log.error("reload failed: \(error)")
        }
    }

    /// Tears the runtime down and builds it again from the config on disk.
    /// Shared by the menu item and the Settings window's Apply button.
    private func reloadRuntime() throws {
        runtime.stop()
        runtime = try Runtime.start()
        Log.info("config reloaded")
    }

    @objc private func settingsRequested(_ note: Notification) {
        let request = SettingsRequest(userInfo: note.userInfo)
        if request.close {
            SettingsWindowController.close()
        } else {
            showSettings(tab: request.tab)
            if let path = request.snapshotPath {
                // SwiftUI needs a runloop turn to lay out the newly selected tab.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.snapshotDelay) {
                    SettingsWindowController.snapshot(to: path)
                }
            }
        }
    }

    @objc private func openSettings() { showSettings(tab: nil) }

    private func showSettings(tab: SettingsTab?) {
        do {
            let model = try settingsModel ?? makeSettingsModel()
            settingsModel = model
            // Pick up hand edits made since the window was last open, unless
            // they would clobber something typed but not yet applied.
            if !model.isDirty { try model.reloadFromDisk() }
            SettingsWindowController.show(model: model, tab: tab)
        } catch {
            Log.error("cannot open settings: \(error)")
            notify(title: "Molly settings", body: "\(error)")
        }
    }

    private func makeSettingsModel() throws -> SettingsModel {
        try SettingsModel.load(
            reload: { [weak self] in try self?.reloadRuntime() },
            pauseCollectors: { [weak self] in self?.runtime.manager.pause() },
            collectorStatuses: { [weak self] in self?.runtime.manager.allStatuses ?? [] })
    }

    @objc private func quit() {
        runtime.stop()
        NSApp.terminate(nil)
    }

    private func serverURL(_ path: String) -> String {
        "http://\(runtime.config.server.bind):\(runtime.config.server.port)\(path)"
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
