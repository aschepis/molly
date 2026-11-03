import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: Runtime?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let runtime = try Runtime.start()
            self.runtime = runtime
            statusItem = StatusItemController(runtime: runtime)
        } catch {
            Log.error("cannot start: \(error)")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
    }
}

/// Everything a running Molly owns: config, registry, collectors, server.
/// Rebuilt wholesale on "Reload config" so collectors never see a config change.
final class Runtime {
    let config: Config
    let manager: CollectorManager
    let server: HTTPServer?
    private(set) var lastScrape: Date?

    private init(config: Config, manager: CollectorManager, server: HTTPServer?) {
        self.config = config
        self.manager = manager
        self.server = server
    }

    static func start(serve: Bool = true) throws -> Runtime {
        let config = try Config.load()
        Log.minimumLevel = Log.Level(rawValue: config.logLevel) ?? .info
        let registry = MetricsRegistry(constLabels: config.constLabels)
        let collectors = try CollectorRegistry.makeCollectors(config: config)
        let manager = CollectorManager(registry: registry, collectors: collectors)
        manager.startAll()

        var server: HTTPServer?
        if serve {
            let router = Router()
            Routes.register(on: router, manager: manager, config: config)
            do {
                let s = try HTTPServer(bind: config.server.bind, port: config.server.port, router: router)
                s.onFailure = { error in Log.error("metrics listener failed: \(error)") }
                s.start()
                server = s
                Log.info("serving metrics on http://\(config.server.bind):\(config.server.port)/metrics")
            } catch {
                Log.error("metrics server not started: \(error)")
            }
        }
        let runtime = Runtime(config: config, manager: manager, server: server)
        server?.onRequest = { [weak runtime] request in
            if request.path == "/metrics" { runtime?.lastScrape = Date() }
        }
        Log.info("Molly \(Version.current) started with \(collectors.count) collectors")
        return runtime
    }

    func stop() {
        manager.stopAll()
        server?.stop()
    }
}
