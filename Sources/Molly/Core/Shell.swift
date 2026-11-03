import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { status == 0 }
}

enum ShellError: Error, CustomStringConvertible {
    case launchFailed(String, String)
    case timedOut(String, TimeInterval)

    var description: String {
        switch self {
        case .launchFailed(let cmd, let why): return "cannot run \(cmd): \(why)"
        case .timedOut(let cmd, let secs): return "\(cmd) timed out after \(Int(secs))s"
        }
    }
}

/// Runs a command with a timeout. Collectors use this for the handful of
/// macOS tools (pmset, lsappinfo, docker, git) that have no sane API.
enum Shell {
    static func run(_ command: String, _ arguments: [String] = [],
                    timeout: TimeInterval = 10, currentDirectory: String? = nil,
                    environment: [String: String]? = nil, input: Data? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.hasPrefix("/") ? command : "/usr/bin/env")
        process.arguments = command.hasPrefix("/") ? arguments : [command] + arguments
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(command, error.localizedDescription)
        }
        if let stdin, let input {
            DispatchQueue.global(qos: .utility).async {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        // Drain pipes on background threads so a chatty command cannot deadlock.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw ShellError.timedOut(command, timeout)
        }
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }

    static func which(_ command: String) -> String? {
        let candidates = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in candidates where FileManager.default.isExecutableFile(atPath: "\(dir)/\(command)") {
            return "\(dir)/\(command)"
        }
        return nil
    }
}
