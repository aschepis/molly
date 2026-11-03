import Foundation

/// Pure pieces of the launch agent so they can be tested without launchctl.
enum LaunchAgent {
    static let label = "com.aschepis.molly"
    static let installedExecutable = "/Applications/Molly.app/Contents/MacOS/molly"

    static var plistURL: URL {
        Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logDirectory: URL { Paths.dataFolder }

    /// Prefer the installed app so the agent keeps working after `swift build` cleans up,
    /// and so Full Disk Access granted to Molly.app applies.
    static func chooseExecutable(current: String, fileExists: (String) -> Bool) -> String {
        fileExists(installedExecutable) ? installedExecutable : current
    }

    static func plist(executable: String, logDirectory: URL) throws -> Data {
        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logDirectory.appendingPathComponent("molly.out.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("molly.err.log").path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    static var domainTarget: String { "gui/\(getuid())" }
}

enum InstallAgentCommand {
    static func run(_ arguments: [String]) {
        let current = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let executable = LaunchAgent.chooseExecutable(current: current) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        do {
            try FileManager.default.createDirectory(at: LaunchAgent.logDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: LaunchAgent.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try LaunchAgent.plist(executable: executable, logDirectory: LaunchAgent.logDirectory)
            try data.write(to: LaunchAgent.plistURL, options: .atomic)

            // A stale registration makes bootstrap fail with an I/O error.
            _ = try? Shell.run("launchctl", ["bootout", "\(LaunchAgent.domainTarget)/\(LaunchAgent.label)"])
            let result = try Shell.run("launchctl", ["bootstrap", LaunchAgent.domainTarget, LaunchAgent.plistURL.path])
            guard result.succeeded else {
                FileHandle.standardError.write(Data("launchctl bootstrap failed: \(result.stderr)\n".utf8))
                exit(1)
            }
            print("installed \(LaunchAgent.plistURL.path)")
            print("runs: \(executable) run")
            print("logs: \(LaunchAgent.logDirectory.path)")
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}

enum UninstallAgentCommand {
    static func run(_ arguments: [String]) {
        let result = try? Shell.run("launchctl", ["bootout", "\(LaunchAgent.domainTarget)/\(LaunchAgent.label)"])
        if result?.succeeded == true {
            print("stopped \(LaunchAgent.label)")
        } else {
            print("\(LaunchAgent.label) was not loaded")
        }
        if FileManager.default.fileExists(atPath: LaunchAgent.plistURL.path) {
            do {
                try FileManager.default.removeItem(at: LaunchAgent.plistURL)
                print("removed \(LaunchAgent.plistURL.path)")
            } catch {
                FileHandle.standardError.write(Data("cannot remove plist: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}

enum StatusCommand {
    static func run(_ arguments: [String]) {
        let config = (try? Config.load()) ?? Config()

        let loaded = (try? Shell.run("launchctl", ["print", "\(LaunchAgent.domainTarget)/\(LaunchAgent.label)"]))?.succeeded == true
        print("launch agent:  \(loaded ? "loaded" : "not loaded") (\(LaunchAgent.plistURL.path))")

        let probeHost = config.server.bind == "0.0.0.0" ? "127.0.0.1" : config.server.bind
        let health = URL(string: "http://\(probeHost):\(config.server.port)/healthz")
        let healthStatus = health.map { DoctorCommand.fetch($0).0 } ?? 0
        print("molly /healthz: \(healthStatus == 200 ? "ok" : "not answering") (\(probeHost):\(config.server.port))")

        print("prometheus:    \(prometheusSummary(base: config.links.prometheus))")
    }

    static func prometheusSummary(base: String) -> String {
        guard let url = URL(string: base + "/api/v1/targets") else { return "bad url \(base)" }
        let (status, body) = DoctorCommand.fetch(url)
        guard status == 200 else { return "not reachable at \(base) (run `make stack-up`)" }
        return targetSummary(from: body) ?? "reachable, but no \"molly\" target configured"
    }

    /// Describes the scrape job named "molly", or nil when Prometheus does not know it.
    static func targetSummary(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let targets = payload["activeTargets"] as? [[String: Any]] else { return nil }
        let mine = targets.filter { ($0["labels"] as? [String: Any])?["job"] as? String == "molly" }
        guard let target = mine.first else { return nil }
        let health = target["health"] as? String ?? "unknown"
        let lastError = target["lastError"] as? String ?? ""
        return lastError.isEmpty ? "molly target \(health)" : "molly target \(health): \(lastError)"
    }
}
