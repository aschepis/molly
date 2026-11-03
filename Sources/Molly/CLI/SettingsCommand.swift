import Foundation

/// Asks the running daemon to open (or close) its Settings window.
enum SettingsCommand {
    static let usage = "usage: molly settings [\(SettingsTab.allCases.map(\.rawValue).joined(separator: "|"))] | --close  (add --snapshot FILE.png to have the daemon render the window itself)"

    struct UsageError: Error { let message: String }

    static func parse(_ arguments: [String]) -> Result<SettingsRequest, UsageError> {
        var rest = arguments
        var snapshotPath: String?
        if let flag = rest.firstIndex(of: "--snapshot") {
            guard flag + 1 < rest.count else { return .failure(UsageError(message: usage)) }
            snapshotPath = rest[flag + 1]
            rest.removeSubrange(flag...flag + 1)
        }
        if rest == ["--close"] && snapshotPath == nil { return .success(SettingsRequest(close: true)) }
        guard rest.count <= 1 else { return .failure(UsageError(message: usage)) }
        guard let name = rest.first else { return .success(SettingsRequest(snapshotPath: snapshotPath)) }
        guard let tab = SettingsTab.parse(name) else {
            return .failure(UsageError(message: "unknown tab '\(name)'\n\(usage)"))
        }
        return .success(SettingsRequest(tab: tab, snapshotPath: snapshotPath))
    }

    static func run(_ arguments: [String]) {
        let request: SettingsRequest
        switch parse(arguments) {
        case .success(let parsed): request = parsed
        case .failure(let error): fail(error.message)
        }
        let config = (try? Config.load()) ?? Config()
        let host = config.server.bind == "0.0.0.0" ? "127.0.0.1" : config.server.bind
        guard let health = URL(string: "http://\(host):\(config.server.port)/healthz"),
              DoctorCommand.fetch(health).0 == 200 else {
            fail("no Molly daemon answering on \(host):\(config.server.port); start it with `molly run` or open Molly.app")
        }
        DistributedNotificationCenter.default().postNotificationName(
            SettingsRequest.notificationName, object: nil,
            userInfo: request.userInfo, deliverImmediately: true)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}
