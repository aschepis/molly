import Foundation

/// Checks the things that silently break collectors: permissions, ports,
/// and whether the local Prometheus/Grafana stack is reachable.
enum DoctorCommand {
    struct Check {
        let name: String
        let ok: Bool
        let detail: String
    }

    static func run(_ arguments: [String]) {
        var checks: [Check] = []
        let config: Config
        do {
            config = try Config.load()
            checks.append(Check(name: "config", ok: true, detail: Paths.configFile.path + (FileManager.default.fileExists(atPath: Paths.configFile.path) ? "" : " (missing, using defaults)")))
        } catch {
            checks.append(Check(name: "config", ok: false, detail: "\(error)"))
            config = Config()
        }
        checks.append(fullDiskAccess())
        checks.append(port(config.server))
        checks.append(reachable("prometheus", config.links.prometheus + "/-/ready"))
        checks.append(reachable("grafana", config.links.grafana + "/api/health"))
        checks.append(Check(name: "docker", ok: Shell.which("docker") != nil, detail: Shell.which("docker") ?? "docker CLI not found; the local stack needs Docker Desktop"))
        checks.append(contentsOf: Doctor.extraChecks(config: config))

        for check in checks {
            print("\(check.ok ? "ok  " : "FAIL") \(check.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(check.detail)")
        }
        exit(checks.allSatisfy { $0.ok } ? 0 : 1)
    }

    /// Messages' chat.db is protected by TCC; reading it proves Full Disk Access.
    static func fullDiskAccess() -> Check {
        let path = Paths.home.appendingPathComponent("Library/Messages/chat.db").path
        guard FileManager.default.fileExists(atPath: path) else {
            return Check(name: "full disk access", ok: true, detail: "cannot verify (no Messages database); grant it if Safari/Messages/Notes collectors report unavailable")
        }
        if FileHandle(forReadingAtPath: path) != nil {
            return Check(name: "full disk access", ok: true, detail: "granted to this process")
        }
        return Check(name: "full disk access", ok: false, detail: "System Settings > Privacy & Security > Full Disk Access: add the molly binary (or Molly.app)")
    }

    static func port(_ server: Config.Server) -> Check {
        let probe = URL(string: "http://\(server.bind):\(server.port)/healthz")!
        let (status, _) = fetch(probe)
        if status == 200 {
            return Check(name: "metrics port", ok: true, detail: "\(server.port): a Molly instance is already serving")
        }
        if status != 0 {
            return Check(name: "metrics port", ok: false, detail: "\(server.port) is in use by something else")
        }
        return Check(name: "metrics port", ok: true, detail: "\(server.port) free")
    }

    static func reachable(_ name: String, _ url: String) -> Check {
        guard let u = URL(string: url) else { return Check(name: name, ok: false, detail: "bad url \(url)") }
        let (status, _) = fetch(u)
        return Check(name: name, ok: status == 200, detail: status == 200 ? "\(url) reachable" : "\(url) not reachable (run `make stack-up`)")
    }

    static func fetch(_ url: URL, timeout: TimeInterval = 2) -> (Int, Data) {
        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var body = Data()
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data ?? Data()
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return (status, body)
    }
}

/// Collectors can contribute checks here (one line per collector file is fine).
enum Doctor {
    static func extraChecks(config: Config) -> [DoctorCommand.Check] {
        []
    }
}
