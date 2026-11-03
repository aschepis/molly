import Foundation

/// A macOS privacy permission a collector depends on, with the System
/// Settings pane that grants it.
enum Permission: String, CaseIterable {
    case none
    case fullDiskAccess
    case accessibility
    case screenRecording
    case automation
    case location

    var title: String {
        switch self {
        case .none: return "No permission needed"
        case .fullDiskAccess: return "Full Disk Access"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        case .location: return "Location Services"
        }
    }

    private var pane: String? {
        switch self {
        case .none: return nil
        case .fullDiskAccess: return "Privacy_AllFiles"
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .automation: return "Privacy_Automation"
        case .location: return "Privacy_LocationServices"
        }
    }

    var settingsURL: URL? {
        guard let pane else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

struct CollectorInfo: Identifiable, Equatable {
    let name: String
    let title: String
    let summary: String
    let defaultEnabled: Bool
    let defaultInterval: TimeInterval
    let permission: Permission

    var id: String { name }
    var isOptIn: Bool { !defaultEnabled }
}

/// Human-facing facts about every collector, in registry order. Defaults here
/// must match `CollectorRegistry` and each collector's `interval(default:)`.
enum CollectorCatalog {
    static let all: [CollectorInfo] = [
        CollectorInfo(name: "process", title: "Molly itself", summary: "Memory, CPU and series count of the Molly process.", defaultEnabled: true, defaultInterval: 30, permission: .none),
        CollectorInfo(name: "system", title: "System", summary: "CPU, memory, disk, network, battery, thermal state, Bluetooth and Wi-Fi.", defaultEnabled: true, defaultInterval: 15, permission: .none),
        CollectorInfo(name: "processes", title: "Processes", summary: "Top CPU and memory consumers, plus running AI agent processes.", defaultEnabled: true, defaultInterval: 30, permission: .none),
        CollectorInfo(name: "focus", title: "Focus", summary: "Frontmost app, idle time, screen lock, sleep and wake, app launches.", defaultEnabled: true, defaultInterval: 5, permission: .none),
        CollectorInfo(name: "docker", title: "Docker", summary: "Running containers and, optionally, their CPU and memory.", defaultEnabled: true, defaultInterval: 60, permission: .none),
        CollectorInfo(name: "meeting", title: "Meetings", summary: "Whether the microphone or camera is in use, as a meeting signal.", defaultEnabled: true, defaultInterval: 5, permission: .none),
        CollectorInfo(name: "input", title: "Input intensity", summary: "Key and click counts per interval, never which keys.", defaultEnabled: false, defaultInterval: 5, permission: .accessibility),
        CollectorInfo(name: "clipboard", title: "Clipboard", summary: "How often the clipboard changes and what kind of content, never the content.", defaultEnabled: true, defaultInterval: 2, permission: .none),
        CollectorInfo(name: "hardware", title: "Hardware", summary: "External displays, docked state, USB and audio devices.", defaultEnabled: true, defaultInterval: 30, permission: .none),
        CollectorInfo(name: "browser", title: "Browser history", summary: "Visit counts from Safari, Chrome-family and Firefox history files.", defaultEnabled: true, defaultInterval: 60, permission: .fullDiskAccess),
        CollectorInfo(name: "messages", title: "Messages", summary: "Messages sent and received, counts only.", defaultEnabled: true, defaultInterval: 60, permission: .fullDiskAccess),
        CollectorInfo(name: "notes", title: "Notes", summary: "Notes created and modified, counts only.", defaultEnabled: true, defaultInterval: 120, permission: .fullDiskAccess),
        CollectorInfo(name: "knowledge", title: "Screen Time", summary: "App usage, notifications and display time from the system's own knowledge store.", defaultEnabled: true, defaultInterval: 60, permission: .fullDiskAccess),
        CollectorInfo(name: "calendar", title: "Calendar", summary: "Events today, time in events and the next event start, never titles.", defaultEnabled: true, defaultInterval: 300, permission: .fullDiskAccess),
        CollectorInfo(name: "mail", title: "Mail", summary: "Mail received and sent from Apple Mail's envelope index, counts only.", defaultEnabled: false, defaultInterval: 120, permission: .fullDiskAccess),
        CollectorInfo(name: "git", title: "Git", summary: "Commits, dirty files and branches across your source roots.", defaultEnabled: true, defaultInterval: 120, permission: .none),
        CollectorInfo(name: "claude_code", title: "Claude Code", summary: "Sessions, messages, tool calls, tokens and estimated cost.", defaultEnabled: true, defaultInterval: 60, permission: .none),
        CollectorInfo(name: "cursor", title: "Cursor", summary: "Cursor AI usage from its local tracking database.", defaultEnabled: true, defaultInterval: 120, permission: .none),
        CollectorInfo(name: "codex", title: "Codex", summary: "Codex CLI sessions from its local session logs.", defaultEnabled: true, defaultInterval: 120, permission: .none),
        CollectorInfo(name: "shell", title: "Shell", summary: "Commands run per shell, and optionally command names and hosts.", defaultEnabled: true, defaultInterval: 60, permission: .none),
        CollectorInfo(name: "projects", title: "Projects", summary: "Which projects are active, merged from git, agents and the shell hook.", defaultEnabled: true, defaultInterval: 60, permission: .none),
        CollectorInfo(name: "power", title: "Power", summary: "Sleep, wake and charge events from the system power log.", defaultEnabled: true, defaultInterval: 300, permission: .none),
        CollectorInfo(name: "forensics", title: "Forensics", summary: "Boots, shutdowns and crash, hang and panic reports that explain gaps.", defaultEnabled: true, defaultInterval: 300, permission: .none),
        CollectorInfo(name: "builds", title: "Builds", summary: "Compiler and test runner processes, as build activity.", defaultEnabled: true, defaultInterval: 15, permission: .none),
        CollectorInfo(name: "tabs", title: "Browser tabs", summary: "Open tab and window counts per browser via AppleScript.", defaultEnabled: false, defaultInterval: 60, permission: .automation),
        CollectorInfo(name: "media", title: "Media", summary: "Whether Music or Spotify is playing, optionally the track.", defaultEnabled: false, defaultInterval: 15, permission: .automation),
        CollectorInfo(name: "titles", title: "Window titles", summary: "The frontmost window's title, normalised and capped.", defaultEnabled: false, defaultInterval: 5, permission: .screenRecording),
        CollectorInfo(name: "events", title: "Claude Code hooks", summary: "Live events posted by `molly hook` from Claude Code sessions.", defaultEnabled: true, defaultInterval: 60, permission: .none),
        CollectorInfo(name: "insights", title: "Insights", summary: "Daily and weekly Claude narratives of your metrics.", defaultEnabled: false, defaultInterval: 300, permission: .none),
    ]

    static func info(_ name: String) -> CollectorInfo? {
        all.first { $0.name == name }
    }

    static var optIn: Set<String> {
        Set(all.filter { $0.isOptIn }.map { $0.name })
    }
}
