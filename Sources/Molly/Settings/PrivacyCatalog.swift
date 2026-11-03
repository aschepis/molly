import Foundation

/// One potentially sensitive label dimension and the facts the Privacy tab
/// shows about it. `defaults` references the collector's own constant so the
/// catalog cannot drift from what the collector applies.
struct PrivacyDimension: Identifiable, Equatable {
    let collector: String
    let key: String
    let title: String
    let rawValue: String
    let defaults: LabelPolicy
    let metrics: [String]
    let permission: Permission

    var id: String { "\(collector).\(key)" }
    var path: [String] { ["collectors", collector, key] }
}

enum PrivacyCatalog {
    static let all: [PrivacyDimension] = [
        PrivacyDimension(collector: "browser", key: "domains", title: "Websites visited",
                         rawValue: "hostname of each visited URL; path and query are never read",
                         defaults: BrowserCollector.domainsDefaults,
                         metrics: ["molly_browser_domain_visits_total", "molly_browser_domain_visits_today"],
                         permission: .fullDiskAccess),
        PrivacyDimension(collector: "calendar", key: "calendars", title: "Calendar names",
                         rawValue: "calendar name, never event titles",
                         defaults: CalendarCollector.calendarsDefaults,
                         metrics: ["molly_calendar_events_today"],
                         permission: .fullDiskAccess),
        PrivacyDimension(collector: "claude_code", key: "projects", title: "Claude Code projects",
                         rawValue: "project name from the session's working directory",
                         defaults: ClaudeCodeCollector.projectsDefaults,
                         metrics: ["molly_claude_messages_total", "molly_claude_tool_calls_total", "molly_claude_session_duration_seconds_total"],
                         permission: .none),
        PrivacyDimension(collector: "docker", key: "containers", title: "Docker containers",
                         rawValue: "container and image names",
                         defaults: DockerCollector.containersDefaults,
                         metrics: ["molly_docker_container_info", "molly_docker_container_cpu_ratio", "molly_docker_container_memory_bytes"],
                         permission: .none),
        PrivacyDimension(collector: "events", key: "projects", title: "Hook event projects",
                         rawValue: "project name from the hook payload's working directory",
                         defaults: EventsCollector.projectsDefaults,
                         metrics: ["molly_claude_hook_events_total"],
                         permission: .none),
        PrivacyDimension(collector: "focus", key: "apps", title: "App names",
                         rawValue: "frontmost and running app names and bundle ids",
                         defaults: FocusCollector.appsDefaults,
                         metrics: ["molly_focus_app", "molly_focus_seconds_total", "molly_running_app", "molly_app_launches_total", "molly_app_terminations_total"],
                         permission: .none),
        PrivacyDimension(collector: "git", key: "repos", title: "Git repositories",
                         rawValue: "owner/repo from the origin remote, else the folder name",
                         defaults: GitCollector.reposDefaults,
                         metrics: ["molly_git_*"],
                         permission: .none),
        PrivacyDimension(collector: "git", key: "branches", title: "Git branches",
                         rawValue: "current branch name",
                         defaults: GitCollector.branchesDefaults,
                         metrics: ["molly_git_branch_info"],
                         permission: .none),
        PrivacyDimension(collector: "hardware", key: "devices", title: "USB and audio devices",
                         rawValue: "device names",
                         defaults: HardwareCollector.devicesDefaults,
                         metrics: ["molly_usb_device_info", "molly_audio_default_output_info", "molly_audio_default_input_info"],
                         permission: .none),
        PrivacyDimension(collector: "knowledge", key: "apps", title: "Screen Time apps",
                         rawValue: "bundle ids from the system's app-usage database",
                         defaults: KnowledgeCollector.appsDefaults,
                         metrics: ["molly_knowledge_app_usage_seconds_total", "molly_knowledge_app_usage_seconds_today", "molly_knowledge_notifications_total", "molly_knowledge_media_playing_seconds_total"],
                         permission: .fullDiskAccess),
        PrivacyDimension(collector: "notes", key: "folders", title: "Notes folders",
                         rawValue: "folder names, never note titles or bodies",
                         defaults: NotesCollector.foldersDefaults,
                         metrics: ["molly_notes_folder_modified_total"],
                         permission: .fullDiskAccess),
        PrivacyDimension(collector: "processes", key: "names", title: "Process names",
                         rawValue: "names of the top CPU and memory consumers",
                         defaults: ProcessesCollector.namesDefaults,
                         metrics: ["molly_process_cpu_ratio", "molly_process_resident_memory_bytes", "molly_process_count_by_name"],
                         permission: .none),
        PrivacyDimension(collector: "projects", key: "projects", title: "Active projects",
                         rawValue: "project names merged from git, agents and the shell hook",
                         defaults: ProjectsCollector.projectsDefaults,
                         metrics: ["molly_project_active", "molly_project_last_activity_timestamp_seconds"],
                         permission: .none),
        PrivacyDimension(collector: "shell", key: "commands", title: "Shell command names",
                         rawValue: "the first word of each command; arguments are never read",
                         defaults: ShellCollector.commandsDefaults,
                         metrics: ["molly_shell_command_names_total"],
                         permission: .none),
        PrivacyDimension(collector: "shell", key: "hosts", title: "Hosts contacted from the shell",
                         rawValue: "hostnames in curl, ssh, scp and URL arguments",
                         defaults: ShellCollector.hostsDefaults,
                         metrics: ["molly_shell_network_hosts_total"],
                         permission: .none),
        PrivacyDimension(collector: "system", key: "wifi", title: "Wi-Fi network name",
                         rawValue: "the SSID",
                         defaults: SystemCollector.wifiDefaults,
                         metrics: ["molly_network_wifi_info"],
                         permission: .location),
        PrivacyDimension(collector: "media", key: "tracks", title: "Music tracks",
                         rawValue: "track and artist from Music or Spotify",
                         defaults: MediaCollector.tracksDefaults,
                         metrics: ["molly_media_track_info"],
                         permission: .automation),
        PrivacyDimension(collector: "titles", key: "titles", title: "Window titles",
                         rawValue: "the frontmost window's title, normalised and truncated",
                         defaults: TitlesCollector.titlesDefaults,
                         metrics: ["molly_focus_window_info", "molly_focus_window_seconds_total"],
                         permission: .screenRecording),
    ]

    static func dimension(_ id: String) -> PrivacyDimension? {
        all.first { $0.id == id }
    }

    static func dimensions(for collector: String) -> [PrivacyDimension] {
        all.filter { $0.collector == collector }
    }
}
