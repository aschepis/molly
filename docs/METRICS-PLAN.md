# Metrics plan (the contract between collectors and dashboards)

Every metric is prefixed `molly_`. The registry adds `user` and `host` to all
series. Counters end in `_total` and only increase; "today" gauges are
recomputed from the source each run and reset at local midnight. Labels marked
**policy** are governed by a `LabelPolicy` in that collector's config section
(see CLAUDE.md); when the policy is disabled the labeled metric is not emitted
but the unlabeled aggregate always is.

Each collector also appears in the self-metrics
`molly_collector_{runs_total,errors_total,duration_seconds,last_success_timestamp_seconds,enabled}{collector}`.

## Group A: system, focus, processes, docker, meeting

### `system` (interval 15s)
| metric | type | labels | source |
|---|---|---|---|
| `molly_cpu_seconds_total` | counter | `cpu` (core index or `total`), `mode` (user/system/nice/idle) | host_processor_info |
| `molly_cpu_utilization_ratio` | gauge | | 0..1 across all cores since last run |
| `molly_cpu_cores` | gauge | | |
| `molly_load_average` | gauge | `period` (1m/5m/15m) | getloadavg |
| `molly_memory_bytes` | gauge | `state` (free/active/inactive/wired/compressed) | host_statistics64 |
| `molly_memory_total_bytes` | gauge | | sysctl hw.memsize |
| `molly_memory_pressure_level` | gauge | | 1 normal, 2 warn, 4 critical (sysctl kern.memorystatus_vm_pressure_level) |
| `molly_swap_bytes` | gauge | `state` (used/free) | sysctl vm.swapusage |
| `molly_swap_total_bytes` | gauge | | |
| `molly_uptime_seconds` | gauge | | |
| `molly_boot_time_seconds` | gauge | | |
| `molly_processes_count` | gauge | | proc_listpids |
| `molly_thermal_state` | gauge | | ProcessInfo.thermalState 0..3 |
| `molly_disk_total_bytes` / `molly_disk_free_bytes` | gauge | `mount`, `fstype` | statfs, local volumes only |
| `molly_disk_read_bytes_total` / `molly_disk_write_bytes_total` | counter | `device` | IOKit IOBlockStorageDriver |
| `molly_disk_read_ops_total` / `molly_disk_write_ops_total` | counter | `device` | |
| `molly_network_receive_bytes_total` / `molly_network_transmit_bytes_total` | counter | `interface` | getifaddrs if_data, skip lo0 |
| `molly_network_receive_packets_total` / `molly_network_transmit_packets_total` | counter | `interface` | |
| `molly_network_receive_errors_total` / `molly_network_transmit_errors_total` | counter | `interface` | |
| `molly_network_vpn_active` | gauge | | any utun/ipsec interface with an address |
| `molly_network_wifi_info` | gauge (=1) | `ssid` **policy** `wifi` (default disabled) | CoreWLAN; degrade to unlabeled `molly_network_wifi_connected` when ssid unavailable |
| `molly_battery_percent` | gauge | | IOPSCopyPowerSourcesInfo |
| `molly_battery_charging` | gauge | | |
| `molly_battery_on_ac` | gauge | | |
| `molly_battery_time_remaining_seconds` | gauge | | -1 when unknown |
| `molly_battery_cycle_count` / `molly_battery_health_ratio` | gauge | | ioreg AppleSmartBattery (max capacity / design capacity) |
| `molly_displays` | gauge | | NSScreen.screens.count |
| `molly_display_info` | gauge (=1) | `display` (index), `width`, `height`, `scale` | |
| `molly_dark_mode` | gauge | | NSApp effectiveAppearance / defaults |
| `molly_bluetooth_devices_connected` | gauge | | IOBluetooth (count only) |
| `molly_audio_output_volume_ratio` | gauge | | CoreAudio default output |

### `processes` (interval 30s)
| metric | type | labels | notes |
|---|---|---|---|
| `molly_process_cpu_ratio` | gauge | `name` **policy** `names` (default enabled, denylist, maxCardinality 25) | top-N by CPU; libproc proc_pid_rusage deltas |
| `molly_process_resident_memory_bytes` | gauge | `name` **policy** `names` | top-N by RSS |
| `molly_process_count_by_name` | gauge | `name` **policy** `names` | |
| `molly_agent_processes` | gauge | `agent` (claude/codex/cursor/aider/copilot/gemini/...) | config `agents` map of agent -> process name patterns |
| `molly_agent_process_cpu_ratio` | gauge | `agent` | |

### `focus` (interval 5s + NSWorkspace/DistributedNotificationCenter observers)
| metric | type | labels | notes |
|---|---|---|---|
| `molly_focus_app` | gauge (=1) | `app`, `bundle_id` **policy** `apps` (default enabled, denylist) | reset each change; exactly one series |
| `molly_focus_seconds_total` | counter | `app` **policy** `apps` | accumulated frontmost time; only while user active & screen unlocked |
| `molly_focus_switches_total` | counter | | app activations |
| `molly_focus_session_seconds` | gauge | | time in current frontmost app |
| `molly_idle_seconds` | gauge | | CGEventSource.secondsSinceLastEventType(.combinedSessionState, .null) |
| `molly_user_active` | gauge | | idle < idleThresholdSeconds (default 300) and unlocked and awake |
| `molly_active_seconds_total` / `molly_idle_seconds_total` | counter | | |
| `molly_screen_locked` | gauge | | com.apple.screenIsLocked/Unlocked |
| `molly_screen_lock_events_total` | counter | | |
| `molly_screensaver_active` | gauge | | |
| `molly_system_asleep` | gauge | | willSleep/didWake |
| `molly_sleep_events_total` / `molly_wake_events_total` | counter | | |
| `molly_running_apps` | gauge | | NSWorkspace.runningApplications (regular activation policy) |
| `molly_running_app` | gauge (=1) | `app` **policy** `apps` | |
| `molly_windows_on_screen` | gauge | | CGWindowListCopyWindowInfo count, layer 0; no titles |
| `molly_app_launches_total` / `molly_app_terminations_total` | counter | `app` **policy** `apps` | didLaunch/didTerminate |

### `docker` (interval 60s; unavailable if no docker CLI/daemon)
| metric | type | labels |
|---|---|---|
| `molly_docker_available` | gauge | |
| `molly_docker_containers` | gauge | `state` (running/exited/paused/created) |
| `molly_docker_container_info` | gauge (=1) | `name`, `image` **policy** `containers` (default enabled, denylist) |
| `molly_docker_images` / `molly_docker_volumes` | gauge | |
| `molly_docker_container_cpu_ratio` / `molly_docker_container_memory_bytes` | gauge | `name` **policy** `containers` | only when `stats: true` (default false; `docker stats` is slow) |

### `meeting` (interval 5s)
| metric | type | notes |
|---|---|---|
| `molly_microphone_in_use` | gauge | CoreAudio kAudioDevicePropertyDeviceIsRunningSomewhere on default input |
| `molly_camera_in_use` | gauge | CoreMediaIO kCMIODevicePropertyDeviceIsRunningSomewhere |
| `molly_meeting_active` | gauge | mic or camera in use |
| `molly_meeting_seconds_total` | counter | |
| `molly_meetings_total` | counter | transitions into active |

## Group B: browser, messages, notes, knowledge, calendar, mail

### `browser` (interval 60s)
Browsers auto-detected: safari, chrome, chrome_beta, chrome_canary, brave, arc, edge, vivaldi, firefox, orion. Config `browsers` restricts; `extraProfiles` adds paths.
| metric | type | labels |
|---|---|---|
| `molly_browser_available` | gauge (=1) | `browser` |
| `molly_browser_visits_total` | counter | `browser` |
| `molly_browser_visits_today` | gauge | `browser` |
| `molly_browser_distinct_domains_today` | gauge | `browser` |
| `molly_browser_domain_visits_total` | counter | `browser`, `domain` **policy** `domains` (default disabled, denylist, maxCardinality 50) |
| `molly_browser_domain_visits_today` | gauge | `browser`, `domain` **policy** `domains` |
| `molly_browser_history_rows` | gauge | `browser` |

### `messages` (interval 60s; Full Disk Access)
| metric | type | labels |
|---|---|---|
| `molly_messages_total` | counter | `service` (iMessage/SMS/RCS), `direction` (sent/received) |
| `molly_messages_today` | gauge | `service`, `direction` |
| `molly_messages_with_attachments_total` | counter | `direction` |
| `molly_message_chats_active_today` | gauge | |
| `molly_messages_unread` | gauge | |

### `notes` (interval 120s; Full Disk Access)
| metric | type | labels |
|---|---|---|
| `molly_notes_count` | gauge | |
| `molly_notes_folders` | gauge | |
| `molly_notes_created_total` / `molly_notes_modified_total` | counter | |
| `molly_notes_created_today` / `molly_notes_modified_today` | gauge | |
| `molly_notes_modified_total` | counter | `folder` **policy** `folders` (default disabled) |

### `knowledge` (interval 60s; knowledgeC.db, Full Disk Access)
System-authoritative app usage that keeps counting while Molly is not running.
| metric | type | labels |
|---|---|---|
| `molly_knowledge_app_usage_seconds_total` | counter | `app` (bundle id) **policy** `apps` (default enabled, denylist, maxCardinality 50) |
| `molly_knowledge_app_usage_seconds_today` | gauge | `app` **policy** `apps` |
| `molly_knowledge_notifications_total` | counter | `app` **policy** `apps` |
| `molly_knowledge_notifications_today` | gauge | |
| `molly_knowledge_media_playing_seconds_total` | counter | `app` **policy** `apps` |
| `molly_knowledge_display_on_seconds_total` | counter | |
| `molly_knowledge_bluetooth_connected_seconds_total` | counter | |

### `calendar` (interval 300s; Calendar.sqlitedb with Full Disk Access, EventKit optional)
| metric | type | labels |
|---|---|---|
| `molly_calendar_events_today` | gauge | `calendar` **policy** `calendars` (default disabled) |
| `molly_calendar_event_seconds_today` | gauge | |
| `molly_calendar_event_seconds_remaining_today` | gauge | |
| `molly_calendar_in_event` | gauge | |
| `molly_calendar_next_event_start_seconds` | gauge | seconds until next event, -1 if none |

### `mail` (interval 120s; Apple Mail Envelope Index, Full Disk Access; default disabled)
| metric | type | labels |
|---|---|---|
| `molly_mail_messages_total` | counter | `direction` |
| `molly_mail_messages_today` | gauge | `direction` |
| `molly_mail_unread` | gauge | |

## Group C: git, claude_code, cursor, codex, shell, projects

### `git` (interval 120s; `roots` default ["~/src"], `maxDepth` 4, rescan 30m)
| metric | type | labels |
|---|---|---|
| `molly_git_repos` | gauge | |
| `molly_git_repos_active` | gauge | activity within `activeDays` (default 30) |
| `molly_git_commits_total` | counter | `repo` **policy** `repos` (default enabled, denylist, maxCardinality 50), `author` (`me`/`other`) |
| `molly_git_commits_today` | gauge | `repo` **policy** `repos` |
| `molly_git_lines_added_today` / `molly_git_lines_removed_today` | gauge | `repo` **policy** `repos` |
| `molly_git_dirty_files` / `molly_git_untracked_files` | gauge | `repo` **policy** `repos` |
| `molly_git_ahead` / `molly_git_behind` | gauge | `repo` **policy** `repos` |
| `molly_git_stashes` | gauge | `repo` **policy** `repos` |
| `molly_git_last_commit_timestamp_seconds` | gauge | `repo` **policy** `repos` |
| `molly_git_branch_info` | gauge (=1) | `repo`, `branch` **policy** `branches` (default enabled, denylist) |
Only active repos (per `activeDays`) get labeled series. `repo` label is `owner/name` from the origin remote when available, else the directory name.

### `claude_code` (interval 60s; `~/.claude/projects/**/*.jsonl`, `~/.claude/history.jsonl`)
| metric | type | labels |
|---|---|---|
| `molly_claude_sessions_active` | gauge | files modified within `activeWindowSeconds` (default 300) |
| `molly_claude_sessions_total` | counter | new session files seen |
| `molly_claude_sessions_today` | gauge | |
| `molly_claude_messages_total` | counter | `role` (user/assistant), `project` **policy** `projects` (default enabled, denylist, maxCardinality 30) |
| `molly_claude_tool_calls_total` | counter | `tool`, `project` **policy** `projects` |
| `molly_claude_tokens_total` | counter | `model`, `kind` (input/output/cache_read/cache_creation) |
| `molly_claude_estimated_cost_usd_total` | counter | `model` (price table in config `pricing`, defaults for known models) |
| `molly_claude_subagent_messages_total` | counter | | isSidechain lines |
| `molly_claude_prompts_total` | counter | | history.jsonl entries |
| `molly_claude_session_duration_seconds_total` | counter | `project` **policy** `projects` | wall time between first and last line per session, incremental |

### `cursor` (interval 120s; `~/.cursor/ai-tracking/ai-code-tracking.db`)
| metric | type |
|---|---|
| `molly_cursor_available` | gauge |
| `molly_cursor_ai_code_events_total` | counter (rows newer than cursor in ai_code_hashes) |
| `molly_cursor_scored_commits_total` | counter |
| `molly_cursor_conversations_total` | counter |

### `codex` (interval 120s; `~/.codex/sessions/**/*.jsonl` when present)
Same shape as claude_code where the format allows: `molly_codex_sessions_active`, `molly_codex_sessions_total`, `molly_codex_messages_total{role}`, `molly_codex_tokens_total{model,kind}`.

### `shell` (interval 60s; zsh extended history, bash, fish)
| metric | type | labels |
|---|---|---|
| `molly_shell_commands_total` | counter | `shell` |
| `molly_shell_commands_today` | gauge | `shell` |
| `molly_shell_command_names_total` | counter | `command` (first word, basename) **policy** `commands` (default disabled; allowlist recommended; maxCardinality 50) |
| `molly_shell_network_hosts_total` | counter | `host` **policy** `hosts` (default disabled) | hosts from curl/wget/ssh/scp/http(s) URLs in commands |
Arguments are never stored or exported.

### `projects` (interval 60s; derived)
Union of signals from git (dirty/commit), claude_code (session activity), and
shell (cwd when available). Collectors publish into a shared `ProjectTracker`.
| metric | type | labels |
|---|---|---|
| `molly_project_active` | gauge (=1) | `project` **policy** `projects` (default enabled, denylist) | activity within `activeWindowSeconds` (default 1800) |
| `molly_project_last_activity_timestamp_seconds` | gauge | `project`, `source` (git/claude/shell) |
| `molly_projects_active` | gauge | |

## Self (`process`, already implemented)
`molly_process_resident_memory_bytes`, `molly_process_cpu_seconds_total`, `molly_process_threads`, plus `molly_up`, `molly_paused`, `molly_build_info{version}`, `molly_start_time_seconds`.
