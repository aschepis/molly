import Foundation

enum Help {
    static let text = """
    molly — deep observability of your macOS usage, exposed to Prometheus

    usage: molly [command]

      run            start the menu bar app and the /metrics endpoint (default)
      once           run every collector once and print the metrics text
                     (--collector NAME to run only one; never advances saved cursors)
      hook           read a Claude Code hook payload on stdin and post it to /event
                     (hook snippet | hook install | hook uninstall manage ~/.claude/settings.json)
      shell-hook     prompt hook that reports your shell's working directory to /event
                     (shell-hook snippet | install | uninstall, --shell zsh|bash|fish)
      mcp            stdio MCP server with read-only query tools over Prometheus
                     (claude mcp add molly -- <absolute path to molly> mcp)
      insights       write a Claude-generated report for a day or week from Prometheus data
                     (--day YYYY-MM-DD | --week | --force | --digest-only | --backend api|cli)
      doctor         check permissions, ports, and the local Prometheus/Grafana stack
      validate       parse the config file and report problems
      install-agent  start Molly at login (writes ~/Library/LaunchAgents/com.aschepis.molly.plist)
      uninstall-agent  stop Molly and remove the launch agent
      status         launch agent state, /healthz, and the Prometheus target
      tune           recommend config changes from registry size, collector health and scrape stats
                     (--json for machine output; --apply merges the patches into config.json with a backup)
      privacy        every sensitive label dimension, its policy, and decision counts (--json)
      export         back up config, state, insights, /metrics and a Prometheus TSDB snapshot to a tarball
                     (--out DIR | --include-secrets | --restore TARBALL prints the manual restore steps)
      prune          delete Molly samples older than a cutoff from Prometheus
                     (--older-than 30d|12h|2w, --dry-run; needs the admin API)
      config-path    print the config file location
      version        print the version

    environment:
      MOLLY_CONFIG   path to config.json (default ~/Library/Application Support/Molly/config.json)
      MOLLY_HOME     data folder (default ~/Library/Application Support/Molly)
    """
}

enum OnceCommand {
    static func run(_ arguments: [String]) {
        var only: String?
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            if arg == "--collector", let name = iterator.next() { only = name }
        }
        do {
            let config = try Config.load()
            Log.minimumLevel = Log.Level(rawValue: config.logLevel) ?? .info
            StateStore.persistenceEnabled = false
            let registry = MetricsRegistry(constLabels: config.constLabels)
            var collectors = try CollectorRegistry.makeCollectors(config: config)
            if let only {
                collectors = collectors.filter { $0.name == only }
                guard !collectors.isEmpty else {
                    FileHandle.standardError.write(Data("no enabled collector named \(only)\n".utf8))
                    exit(2)
                }
            }
            let manager = CollectorManager(registry: registry, collectors: collectors)
            manager.startAll()
            let failures = manager.collectAll()
            let text = registry.render()
            manager.stopAll()
            print(text, terminator: "")
            for (name, error) in failures.sorted(by: { $0.key < $1.key }) {
                FileHandle.standardError.write(Data("collector \(name) failed: \(error)\n".utf8))
            }
            exit(failures.isEmpty ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}

enum ValidateCommand {
    static func run(_ arguments: [String]) {
        let path = arguments.first.map { URL(fileURLWithPath: $0) } ?? Paths.configFile
        do {
            let config = try Config.load(from: path)
            let collectors = try CollectorRegistry.makeCollectors(config: config)
            print("ok: \(path.path)")
            print("labels: \(config.constLabels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            print("enabled collectors: \(collectors.map { $0.name }.sorted().joined(separator: ", "))")
            let unknown = Set(config.collectors.keys).subtracting(CollectorRegistry.knownNames)
            if !unknown.isEmpty {
                print("warning: unknown collector sections: \(unknown.sorted().joined(separator: ", "))")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
