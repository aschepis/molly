import AppKit
import Foundation

// Argument routing only. Subcommands never start NSApplication.

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "run"
let commandArguments = Array(arguments.dropFirst())

switch command {
case "run":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()

case "once":
    OnceCommand.run(commandArguments)

case "hook":
    HookCommand.run(commandArguments)

case "shell-hook":
    ShellHookCommand.run(commandArguments)

case "mcp":
    MCPCommand.run(commandArguments)
case "insights":
    InsightsCommand.run(commandArguments)

case "doctor":
    DoctorCommand.run(commandArguments)

case "install-agent":
    InstallAgentCommand.run(commandArguments)

case "uninstall-agent":
    UninstallAgentCommand.run(commandArguments)

case "status":
    StatusCommand.run(commandArguments)

case "tune":
    TuneCommand.run(commandArguments)
case "privacy":
    PrivacyCommand.run(commandArguments)

case "settings":
    SettingsCommand.run(commandArguments)

case "export":
    ExportCommand.run(commandArguments)

case "health":
    HealthCommand.run(commandArguments)

case "prune":
    PruneCommand.run(commandArguments)

case "config-path":
    print(Paths.configFile.path)

case "validate":
    ValidateCommand.run(commandArguments)

case "version":
    print("molly \(Version.current)")

case "help", "-h", "--help":
    print(Help.text)

default:
    FileHandle.standardError.write(Data("unknown command '\(command)'\n\n\(Help.text)\n".utf8))
    exit(1)
}
