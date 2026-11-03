import AppKit

/// The menu bar presence. The icon being visible means Molly is collecting.
final class StatusItemController: NSObject, NSMenuDelegate {
    private var runtime: Runtime
    private let statusItem: NSStatusItem
    private let statusLine = NSMenuItem(title: "Recording", action: nil, keyEquivalent: "")
    private let scrapeLine = NSMenuItem(title: "Not scraped yet", action: nil, keyEquivalent: "")
    private let endpointLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")

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
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for line in [statusLine, scrapeLine, endpointLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Grafana", #selector(openGrafana), key: "g"))
        menu.addItem(item("Open Prometheus", #selector(openPrometheus)))
        menu.addItem(item("Open /metrics", #selector(openMetrics)))
        menu.addItem(item("Collector Status", #selector(openCollectors)))
        menu.addItem(.separator())
        menu.addItem(item("Open Data Folder", #selector(openDataFolder)))
        menu.addItem(item("Reload Config", #selector(reloadConfig), key: "r"))
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
        let statuses = runtime.manager.allStatuses
        let failing = statuses.filter { $0.lastError != nil && $0.lastSuccess == nil }.count
        let state = runtime.manager.isPaused ? "Paused" : "Recording"
        statusLine.title = "\(state) · \(statuses.count) collectors" + (failing > 0 ? " · \(failing) unavailable" : "")
        if let last = runtime.lastScrape {
            scrapeLine.title = "Scraped \(Int(Date().timeIntervalSince(last)))s ago"
        } else {
            scrapeLine.title = "Not scraped yet (is Prometheus running?)"
        }
        endpointLine.title = "http://\(runtime.config.server.bind):\(runtime.config.server.port)/metrics"
        pauseItem.title = runtime.manager.isPaused ? "Resume" : "Pause"
        statusItem.button?.appearsDisabled = runtime.manager.isPaused
    }

    @objc private func togglePause() {
        if runtime.manager.isPaused { runtime.manager.resume() } else { runtime.manager.pause() }
    }

    @objc private func openGrafana() { open(runtime.config.links.grafana) }
    @objc private func openPrometheus() { open(runtime.config.links.prometheus) }
    @objc private func openMetrics() { open("http://\(runtime.config.server.bind):\(runtime.config.server.port)/metrics") }
    @objc private func openCollectors() { open("http://\(runtime.config.server.bind):\(runtime.config.server.port)/collectors") }
    @objc private func openDataFolder() {
        try? FileManager.default.createDirectory(at: Paths.dataFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.dataFolder)
    }

    @objc private func reloadConfig() {
        runtime.stop()
        do {
            runtime = try Runtime.start()
            Log.info("config reloaded")
        } catch {
            Log.error("reload failed: \(error)")
        }
    }

    @objc private func quit() {
        runtime.stop()
        NSApp.terminate(nil)
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
