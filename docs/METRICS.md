# Metrics catalog

The authoritative list of every metric Molly can emit. It is the contract
between collectors and dashboards: `scripts/check-dashboards.sh` reads this file
and fails if a dashboard or rule uses a metric that is not listed here.

## Conventions

- Names are `molly_<area>_<thing>_<unit>`. Counters end in `_total` and only increase.
- The registry adds `user`, `host` and any `labels.extra` to every series. They are not listed below.
- `*_today` gauges are recomputed from the source each run and reset at local midnight.
- Counters are incremental. The first run initializes cursors at "now", so counters start at 0 and never backfill history.
- **Policy** marks a label governed by a [LabelPolicy](CONFIG.md#labelpolicy-reference). The policy name is given in each section. When the policy is disabled the labeled series is dropped or collapses to `redacted` (stated per collector). Aggregates without the label are always emitted.
- Label values that pass a policy are lowercased and trimmed.
- "only when ..." means the metric is documented but can be absent from `/metrics`: a policy is off, the source is missing, or a permission is not granted.

Per-group deep dives: [group A](collectors/group-a.md) (system, processes, focus, docker, meeting),
[group B](collectors/group-b.md) (browser, messages, notes, knowledge, calendar, mail),
[group C](collectors/group-c.md) (git, claude_code, cursor, codex, shell, projects).
Config keys are in [CONFIG.md](CONFIG.md).

## Self metrics

Published by the collector manager and the `process` collector (interval 30s).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_up` | gauge | | bool | 1 while Molly runs |
| `molly_paused` | gauge | | bool | 1 while collection is paused from the menu bar |
| `molly_build_info` | gauge | `version` | info | always 1; the Molly version is the label |
| `molly_start_time_seconds` | gauge | | seconds (unix) | when Molly started |
| `molly_self_resident_memory_bytes` | gauge | | bytes | resident memory of the Molly process |
| `molly_self_cpu_seconds_total` | counter | | seconds | cumulative CPU time of the Molly process |
| `molly_self_threads` | gauge | | count | threads in the Molly process |
| `molly_collector_runs_total` | counter | `collector` | runs | collector runs |
| `molly_collector_errors_total` | counter | `collector` | runs | runs that failed (unavailable sources are logged once but also count) |
| `molly_collector_duration_seconds` | gauge | `collector` | seconds | wall time of the last run |
| `molly_collector_last_success_timestamp_seconds` | gauge | `collector` | seconds (unix) | last successful run |
| `molly_collector_enabled` | gauge | `collector` | bool | 1 when the collector started; 0 when it failed to start or was stopped |

## system (interval 15s)

No policies except `wifi`. Details: [group A](collectors/group-a.md#system-interval-15s).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_cpu_seconds_total` | counter | `cpu` (core index or `total`), `mode` (user, system, nice, idle) | seconds | CPU time; `total` sums all cores |
| `molly_cpu_utilization_ratio` | gauge | | ratio 0..1 | busy share of all cores since the previous run; absent on the first run |
| `molly_cpu_cores` | gauge | | count | logical cores |
| `molly_load_average` | gauge | `period` (1m, 5m, 15m) | load | getloadavg |
| `molly_memory_bytes` | gauge | `state` (free, active, inactive, wired, compressed) | bytes | memory by state |
| `molly_memory_total_bytes` | gauge | | bytes | installed memory |
| `molly_memory_pressure_level` | gauge | | level | 1 normal, 2 warning, 4 critical |
| `molly_swap_bytes` | gauge | `state` (used, free) | bytes | swap by state |
| `molly_swap_total_bytes` | gauge | | bytes | total swap |
| `molly_uptime_seconds` | gauge | | seconds | since boot, includes sleep |
| `molly_boot_time_seconds` | gauge | | seconds (unix) | last boot |
| `molly_processes_count` | gauge | | count | running processes |
| `molly_thermal_state` | gauge | | level | 0 nominal, 1 fair, 2 serious, 3 critical |
| `molly_disk_total_bytes` | gauge | `mount`, `fstype` | bytes | volume size, local volumes only |
| `molly_disk_free_bytes` | gauge | `mount`, `fstype` | bytes | space available to users |
| `molly_disk_read_bytes_total` | counter | `device` | bytes | bytes read (BSD name such as `disk0`) |
| `molly_disk_write_bytes_total` | counter | `device` | bytes | bytes written |
| `molly_disk_read_ops_total` | counter | `device` | ops | read operations |
| `molly_disk_write_ops_total` | counter | `device` | ops | write operations |
| `molly_network_receive_bytes_total` | counter | `interface` | bytes | received, skips `lo*` |
| `molly_network_transmit_bytes_total` | counter | `interface` | bytes | sent |
| `molly_network_receive_packets_total` | counter | `interface` | packets | received |
| `molly_network_transmit_packets_total` | counter | `interface` | packets | sent |
| `molly_network_receive_errors_total` | counter | `interface` | errors | receive errors |
| `molly_network_transmit_errors_total` | counter | `interface` | errors | transmit errors |
| `molly_network_vpn_active` | gauge | | bool | a VPN tunnel interface has a routable address |
| `molly_network_wifi_connected` | gauge | | bool | Wi-Fi is associated; published when a Wi-Fi interface exists |
| `molly_network_wifi_info` | gauge | `ssid` **policy** `wifi` | info | always 1. Only when `wifi` is enabled and macOS lets the process read the SSID |
| `molly_battery_percent` | gauge | | percent 0..100 | charge; absent on Macs without a battery |
| `molly_battery_charging` | gauge | | bool | charging |
| `molly_battery_on_ac` | gauge | | bool | on AC power |
| `molly_battery_time_remaining_seconds` | gauge | | seconds | to empty, or to full while charging; -1 unknown |
| `molly_battery_cycle_count` | gauge | | cycles | charge cycles |
| `molly_battery_health_ratio` | gauge | | ratio | max capacity over design capacity |
| `molly_displays` | gauge | | count | active displays |
| `molly_display_info` | gauge | `display`, `width`, `height`, `scale` | info | always 1; one series per display, size in points |
| `molly_dark_mode` | gauge | | bool | system appearance is dark |
| `molly_bluetooth_devices_connected` | gauge | | count | connected paired devices; absent when `bluetooth` is false |
| `molly_audio_output_volume_ratio` | gauge | | ratio 0..1 | default output volume; absent if the device has no volume control |

## processes (interval 30s)

Policy `names` governs the process name. When it is disabled only the agent metrics are published.
Details: [group A](collectors/group-a.md#processes-interval-30s).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_process_cpu_ratio` | gauge | `name` **policy** `names` | cores | top `topN` by CPU, 1.0 is one core; absent on the first run |
| `molly_process_resident_memory_bytes` | gauge | `name` **policy** `names` | bytes | top `topN` by resident memory |
| `molly_process_count_by_name` | gauge | `name` **policy** `names` | count | instances of processes in either top list |
| `molly_agent_processes` | gauge | `agent` | count | running processes per configured agent, 0 when none |
| `molly_agent_process_cpu_ratio` | gauge | `agent` | cores | summed CPU of an agent's processes; absent on the first run |

## focus (interval 5s plus notification observers)

Policy `apps` governs `app` and `bundle_id`. When it is disabled every per-app
series is dropped and the aggregates remain. Details: [group A](collectors/group-a.md#focus-interval-5s-plus-notification-observers).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_focus_app` | gauge | `app`, `bundle_id` **policy** `apps` | info | always 1; exactly one series, the frontmost app |
| `molly_focus_seconds_total` | counter | `app` **policy** `apps` | seconds | frontmost time while the user is active |
| `molly_focus_switches_total` | counter | | switches | frontmost app changes |
| `molly_focus_session_seconds` | gauge | | seconds | time in the current frontmost app |
| `molly_idle_seconds` | gauge | | seconds | since the last keyboard or mouse input |
| `molly_user_active` | gauge | | bool | recently active, unlocked and awake |
| `molly_active_seconds_total` | counter | | seconds | seconds the user was active |
| `molly_idle_seconds_total` | counter | | seconds | awake seconds not active (idle or locked); sleep excluded |
| `molly_screen_locked` | gauge | | bool | screen is locked |
| `molly_screen_lock_events_total` | counter | | events | screen locks |
| `molly_screensaver_active` | gauge | | bool | screensaver is running |
| `molly_system_asleep` | gauge | | bool | asleep; rarely visible because scrapes happen awake |
| `molly_sleep_events_total` | counter | | events | sleeps |
| `molly_wake_events_total` | counter | | events | wakes |
| `molly_running_apps` | gauge | | count | regular (Dock) apps running |
| `molly_running_app` | gauge | `app` **policy** `apps` | count | one series per running app, value is the instance count |
| `molly_windows_on_screen` | gauge | | count | layer-0 windows; titles are never read |
| `molly_app_launches_total` | counter | `app` **policy** `apps` | launches | app launches |
| `molly_app_terminations_total` | counter | `app` **policy** `apps` | terminations | app quits |

## docker (interval 60s)

Policy `containers` governs `name` and `image`. Without a docker CLI or daemon
only `molly_docker_available 0` is published. Details: [group A](collectors/group-a.md#docker-interval-60s).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_docker_available` | gauge | | bool | `docker ps` succeeds |
| `molly_docker_containers` | gauge | `state` | count | containers by state; running, exited, paused, created always present |
| `molly_docker_container_info` | gauge | `name`, `image` **policy** `containers` | info | always 1; one series per container. Only when `containers` is enabled |
| `molly_docker_images` | gauge | | count | distinct local image IDs |
| `molly_docker_volumes` | gauge | | count | local volumes |
| `molly_docker_container_cpu_ratio` | gauge | `name` **policy** `containers` | cores | only when `stats` is true and `containers` is enabled |
| `molly_docker_container_memory_bytes` | gauge | `name` **policy** `containers` | bytes | only when `stats` is true and `containers` is enabled |

## meeting (interval 5s)

No policies. A proxy for being on a call. Details: [group A](collectors/group-a.md#meeting-interval-5s).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_microphone_in_use` | gauge | | bool | some process captures from the default microphone |
| `molly_camera_in_use` | gauge | | bool | some process uses a camera |
| `molly_meeting_active` | gauge | | bool | microphone or camera in use |
| `molly_microphone_in_use_seconds_total` | counter | | seconds | microphone in use |
| `molly_camera_in_use_seconds_total` | counter | | seconds | camera in use |
| `molly_meeting_seconds_total` | counter | | seconds | microphone or camera in use |
| `molly_microphone_activations_total` | counter | | events | idle to in-use transitions |
| `molly_camera_activations_total` | counter | | events | idle to in-use transitions |
| `molly_meetings_total` | counter | | events | neither in use to either in use |

## input (interval 5s, default disabled)

No policies. Needs Accessibility. Counts only, never keycodes or positions.
Details: [group A](collectors/group-a.md#input-interval-5s-default-disabled).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_input_available` | gauge | | bool | the event tap is installed |
| `molly_input_events_total` | counter | `kind` | events | key, click or scroll events |
| `molly_input_keys_per_minute` | gauge | | events | key events in the trailing 60s |
| `molly_input_clicks_per_minute` | gauge | | events | clicks in the trailing 60s |
| `molly_input_scrolls_per_minute` | gauge | | events | scroll events in the trailing 60s |

## clipboard (interval 2s)

No policies. Contents are never read. Details: [group A](collectors/group-a.md#clipboard-interval-2s).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_clipboard_changes_total` | counter | `type` | events | changes by text, image, file, url, other |
| `molly_clipboard_last_change_timestamp_seconds` | gauge | | unix time | last change |
| `molly_clipboard_content_bytes` | gauge | | bytes | size of the last item's primary representation |

## hardware (interval 30s)

Policy `devices` governs `name`. Details: [group A](collectors/group-a.md#hardware-interval-30s).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_usb_devices` | gauge | | count | external USB devices attached |
| `molly_usb_device_info` | gauge | `name` **policy** `devices` | info | 1 per device; only when `devices` is enabled |
| `molly_audio_devices` | gauge | `direction` | count | audio devices with input or output streams |
| `molly_audio_default_output_info` | gauge | `name` **policy** `devices` | info | default output device; only when `devices` is enabled |
| `molly_audio_default_input_info` | gauge | `name` **policy** `devices` | info | default input device; only when `devices` is enabled |
| `molly_external_displays` | gauge | | count | displays that are not built in |
| `molly_docked` | gauge | | bool | external displays >= `dockedMinExternalDisplays` |
| `molly_power_adapter_watts` | gauge | | watts | connected adapter rating, -1 when none |
| `molly_lid_closed` | gauge | | bool | clamshell closed; absent when unreadable |

## browser (interval 60s)

Policy `domains` (default disabled) governs `domain`. Details: [group B](collectors/group-b.md#browser).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_browser_available` | gauge | `browser` | bool | 1 if the history is readable, 0 if detected but unreadable |
| `molly_browser_visits_total` | counter | `browser` | visits | history visits |
| `molly_browser_visits_today` | gauge | `browser` | visits | visits since local midnight |
| `molly_browser_distinct_domains_today` | gauge | `browser` | count | distinct domains today |
| `molly_browser_domain_visits_total` | counter | `browser`, `domain` **policy** `domains` | visits | only when `domains` is enabled |
| `molly_browser_domain_visits_today` | gauge | `browser`, `domain` **policy** `domains` | visits | only when `domains` is enabled |
| `molly_browser_history_rows` | gauge | `browser` | rows | rows in the history URL table |

## messages (interval 60s, Full Disk Access)

No policies; counts only. Details: [group B](collectors/group-b.md#messages).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_messages_total` | counter | `service` (iMessage, SMS, RCS, other), `direction` (sent, received) | messages | messages |
| `molly_messages_today` | gauge | `service`, `direction` | messages | since local midnight |
| `molly_messages_with_attachments_total` | counter | `direction` | messages | messages with attachments |
| `molly_message_chats_active_today` | gauge | | count | chats with activity today |
| `molly_messages_unread` | gauge | | messages | received and unread |

## notes (interval 120s, Full Disk Access)

Policy `folders` (default disabled) governs `folder`. Details: [group B](collectors/group-b.md#notes).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_notes_count` | gauge | | count | notes, excluding Recently Deleted |
| `molly_notes_folders` | gauge | | count | folders |
| `molly_notes_created_total` | counter | | notes | notes created |
| `molly_notes_modified_total` | counter | | notes | notes created or edited |
| `molly_notes_created_today` | gauge | | notes | created today |
| `molly_notes_modified_today` | gauge | | notes | created or edited today |
| `molly_notes_folder_modified_total` | counter | `folder` **policy** `folders` | notes | only when `folders` is enabled |

## knowledge (interval 60s, Full Disk Access)

System-recorded usage from knowledgeC.db that keeps accumulating while Molly is
not running. Policy `apps` governs `app` (a bundle id). When it is disabled the
app series collapse to `app="redacted"`. Details: [group B](collectors/group-b.md#knowledge).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_knowledge_app_usage_seconds_total` | counter | `app` **policy** `apps` | seconds | foreground app usage |
| `molly_knowledge_app_usage_seconds_today` | gauge | `app` **policy** `apps` | seconds | today |
| `molly_knowledge_notifications_total` | counter | `app` **policy** `apps` | notifications | received; `app="unknown"` when none recorded |
| `molly_knowledge_notifications_today` | gauge | | notifications | received today |
| `molly_knowledge_media_playing_seconds_total` | counter | `app` **policy** `apps` | seconds | media playback |
| `molly_knowledge_display_on_seconds_total` | counter | | seconds | display backlit |
| `molly_knowledge_bluetooth_connected_seconds_total` | counter | | seconds | a Bluetooth device connected |

## calendar (interval 300s, Full Disk Access)

Policy `calendars` (default disabled) governs `calendar`; when disabled one
`redacted` series is published. Details: [group B](collectors/group-b.md#calendar).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_calendar_events_today` | gauge | `calendar` **policy** `calendars` | events | events today, all-day included |
| `molly_calendar_event_seconds_today` | gauge | | seconds | timed events, overlaps merged |
| `molly_calendar_event_seconds_remaining_today` | gauge | | seconds | timed event time left today |
| `molly_calendar_in_event` | gauge | | bool | inside a timed event |
| `molly_calendar_next_event_start_seconds` | gauge | | seconds | until the next timed event; -1 if none cached |

## mail (interval 120s, Full Disk Access, default disabled)

No policies. Details: [group B](collectors/group-b.md#mail).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_mail_messages_total` | counter | `direction` (sent, received) | messages | only when `mail` is enabled |
| `molly_mail_messages_today` | gauge | `direction` | messages | only when `mail` is enabled |
| `molly_mail_unread` | gauge | | messages | only when `mail` is enabled |

## git (interval 120s)

Policies `repos` and `branches`. Only active repos (see `activeDays`) get
labeled series. When `repos` is disabled, per-repo gauges collapse into one
`repo="redacted"` series. Details: [group C](collectors/group-c.md#git).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_git_repos` | gauge | | count | repositories found under `roots` |
| `molly_git_repos_active` | gauge | | count | repos with a commit or change within `activeDays` |
| `molly_git_commits_total` | counter | `repo` **policy** `repos`, `author` (me, other) | commits | commits newer than the per-repo cursor |
| `molly_git_commits_today` | gauge | `repo` **policy** `repos` | commits | authored today |
| `molly_git_lines_added_today` | gauge | `repo` **policy** `repos` | lines | added by today's commits |
| `molly_git_lines_removed_today` | gauge | `repo` **policy** `repos` | lines | removed by today's commits |
| `molly_git_dirty_files` | gauge | `repo` **policy** `repos` | files | modified files |
| `molly_git_untracked_files` | gauge | `repo` **policy** `repos` | files | untracked files |
| `molly_git_ahead` | gauge | `repo` **policy** `repos` | commits | ahead of upstream |
| `molly_git_behind` | gauge | `repo` **policy** `repos` | commits | behind upstream |
| `molly_git_stashes` | gauge | `repo` **policy** `repos` | count | stash entries |
| `molly_git_last_commit_timestamp_seconds` | gauge | `repo` **policy** `repos` | seconds (unix) | newest commit |
| `molly_git_branch_info` | gauge | `repo` **policy** `repos`, `branch` **policy** `branches` | info | always 1; only when `branches` is enabled |

## claude_code (interval 60s)

Policy `projects` governs `project` on three metrics. When it is disabled,
`project` is `redacted`. Details: [group C](collectors/group-c.md#claude_code).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_claude_sessions_active` | gauge | | count | session files modified within `activeWindowSeconds` |
| `molly_claude_sessions_total` | counter | | sessions | session files created since Molly started |
| `molly_claude_sessions_today` | gauge | | sessions | created since local midnight |
| `molly_claude_messages_total` | counter | `role` (user, assistant), `project` **policy** `projects` | messages | counted once per message id |
| `molly_claude_tool_calls_total` | counter | `tool`, `project` **policy** `projects` | calls | tool_use blocks, by tool name |
| `molly_claude_tokens_total` | counter | `model`, `kind` (input, output, cache_read, cache_creation) | tokens | token usage |
| `molly_claude_estimated_cost_usd_total` | counter | `model` | USD | estimate from list prices, not a bill; unknown models cost 0 |
| `molly_claude_subagent_messages_total` | counter | | messages | the sidechain subset of messages |
| `molly_claude_prompts_total` | counter | | prompts | lines in history.jsonl; text is never read |
| `molly_claude_session_duration_seconds_total` | counter | `project` **policy** `projects` | seconds | active session time, gaps over `sessionGapSeconds` excluded |

## cursor (interval 120s)

No policies. Details: [group C](collectors/group-c.md#cursor).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_cursor_available` | gauge | | bool | the tracking database could be read |
| `molly_cursor_ai_code_events_total` | counter | | events | rows newer than the cursor in `ai_code_hashes` |
| `molly_cursor_scored_commits_total` | counter | | commits | rows in `scored_commits` |
| `molly_cursor_conversations_total` | counter | | conversations | updates to `conversation_summaries` |

## codex (interval 120s)

No policies. Unavailable when `~/.codex/sessions` is missing. Details: [group C](collectors/group-c.md#codex).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_codex_sessions_active` | gauge | | count | session files modified within `activeWindowSeconds` |
| `molly_codex_sessions_total` | counter | | sessions | session files created since Molly started |
| `molly_codex_messages_total` | counter | `role` | messages | by role |
| `molly_codex_tokens_total` | counter | `model`, `kind` (input, output, cache_read) | tokens | token usage |

## shell (interval 60s)

Policies `commands` and `hosts`, both default disabled. Arguments are never
exported. The label is `remote_host` because `host` is a registry const label.
Details: [group C](collectors/group-c.md#shell).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_shell_commands_total` | counter | `shell` (zsh, bash, fish) | commands | commands run |
| `molly_shell_commands_today` | gauge | `shell` | commands | since local midnight |
| `molly_shell_command_names_total` | counter | `command` **policy** `commands` | commands | first word, basename. Only when `commands` is enabled |
| `molly_shell_network_hosts_total` | counter | `remote_host` **policy** `hosts` | mentions | hosts from URLs and curl, wget, ssh, scp and similar. Only when `hosts` is enabled |

## projects (interval 60s, derived)

Union of activity reported by `git` and `claude_code`. Policy `projects`
governs `project`; when disabled the label is `redacted`. Source `shell` is
not emitted. Details: [group C](collectors/group-c.md#projects).

| metric | type | labels | unit | meaning |
|---|---|---|---|---|
| `molly_project_active` | gauge | `project` **policy** `projects` | info | always 1; activity within `activeWindowSeconds` |
| `molly_project_last_activity_timestamp_seconds` | gauge | `project` **policy** `projects`, `source` (git, claude) | seconds (unix) | latest activity |
| `molly_projects_active` | gauge | | count | active projects, not capped by the policy |
