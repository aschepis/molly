# Privacy

Molly never exports content: no keystrokes, window titles, URLs, message
text, note titles, event titles, email addresses, or command lines. What it
does export are counts and timings, and, where you allow it, *names* as
Prometheus labels: which app, which domain, which repo. Every such name goes
through a `LabelPolicy` (see [CONFIG.md](CONFIG.md#labelpolicy-reference)),
and this page lists every one of them.

## Seeing what leaves the box

- `GET /privacy` on the daemon (default `http://127.0.0.1:9765/privacy`) and
  `molly privacy` (add `--json`) list every dimension below with its effective
  policy and how many values, since Molly started, were passed through,
  folded to `other`, replaced by `redacted`, or hashed. Patterns and raw
  values never appear in that report; patterns are in `/config`.
- `molly_privacy_label_decisions_total{dimension,outcome}` publishes the same
  counts to Prometheus, so a dashboard can show a denylist doing its job.
- `/config` shows the effective configuration with salts redacted.

A dimension with a growing `other` count under an allowlist means values you
have not allowed are being seen; a growing `redacted` count under a denylist
means the patterns are matching. Neither reveals what the values were.

## Every sensitive dimension

Dimension names are `<collector>.<key>`. "Default" is what you get with no
config. Sensitive dimensions default to off; the ones defaulting to on carry
names that are visible in the menu bar or the Dock anyway (apps, repos,
processes) and are easy to turn off.

| dimension | default | raw value | carried by |
|---|---|---|---|
| `browser.domains` | off, denylist, max 50 | hostname of each visited URL (path and query are never read) | `molly_browser_domain_visits_total`, `molly_browser_domain_visits_today` |
| `calendar.calendars` | off, denylist, max 50 | calendar name (never event titles) | `molly_calendar_events_today` |
| `claude_code.projects` | on, denylist, max 30 | project name from the session's working directory (`owner/repo` under github.com, else the folder name) | `molly_claude_messages_total`, `molly_claude_tool_calls_total`, `molly_claude_tool_duration_seconds`, `molly_claude_tool_errors_total`, `molly_claude_turn_latency_seconds`, `molly_claude_tokens_total`, `molly_claude_estimated_cost_usd_total`, `molly_claude_session_duration_seconds_total` |
| `docker.containers` | on, denylist | container names and image names | `molly_docker_container_info`, `molly_docker_container_cpu_ratio`, `molly_docker_container_memory_bytes` |
| `events.projects` | on, denylist, max 30 | project name from the hook payload's `cwd` | `molly_claude_hook_events_total` |
| `focus.apps` | on, denylist | frontmost and running app names and bundle ids | `molly_focus_app`, `molly_focus_seconds_total`, `molly_running_app`, `molly_app_launches_total`, `molly_app_terminations_total` |
| `git.repos` | on, denylist, max 50 | `owner/repo` from the origin remote, else the folder name | every `molly_git_*` series with a `repo` label |
| `git.branches` | on, denylist | current branch name | `molly_git_branch_info` |
| `hardware.devices` | off, denylist, max 20 | USB and audio device names | `molly_usb_device_info`, `molly_audio_default_output_info`, `molly_audio_default_input_info` |
| `knowledge.apps` | on, denylist, max 50 | bundle ids from the system's own app-usage database | `molly_knowledge_app_usage_seconds_total`, `molly_knowledge_app_usage_seconds_today`, `molly_knowledge_notifications_total`, `molly_knowledge_media_playing_seconds_total` |
| `notes.folders` | off, denylist, max 50 | Notes folder names (never note titles or bodies) | `molly_notes_folder_modified_total` |
| `processes.names` | on, denylist, max 25 | process names of the top CPU and memory consumers | `molly_process_cpu_ratio`, `molly_process_resident_memory_bytes`, `molly_process_count_by_name` |
| `projects.projects` | on, denylist, max 30 | project names merged from git and Claude Code activity | `molly_project_active`, `molly_project_last_activity_timestamp_seconds` |
| `shell.commands` | off, allowlist, max 50 | the first word of each shell command (arguments are never read) | `molly_shell_command_names_total` |
| `shell.hosts` | off, denylist, max 50 | hostnames found in curl, ssh, scp and URL arguments | `molly_shell_network_hosts_total` |
| `system.wifi` | off | the Wi-Fi SSID (needs Location Services) | `molly_network_wifi_info` |
| `media.tracks` | off, denylist, hash on, max 100 | current track and artist names from Music or Spotify (collector itself is opt-in) | `molly_media_track_info` |
| `gaming.games` | off, denylist, max 30 | game titles from Steam manifests, CrossOver executables and game apps (Steam account files are never read) | `molly_gaming_seconds_total`, `molly_gaming_launches_total`, `molly_gaming_playtime_minutes`, `molly_gaming_last_played_timestamp_seconds` |
| `titles.titles` | on, denylist, hash on, max 100 | the frontmost window's title, normalised and truncated to 80 characters (collector itself is opt-in and needs Screen Recording) | `molly_focus_window_info`, `molly_focus_window_seconds_total` |
| `sensors.sensors` | on, denylist, max 40 | hardware sensor product names such as `PMU tdie1`; not personal (collector itself is opt-in) | `molly_sensor_temperature_celsius` |

Not policy-governed, by design, because they are fixed small sets or your own
config keys: `processes.agents` names (claude, codex, ...), `builds.tools`
names, browser names, Messages service names, `direction`, `mode`, mount
points and interface names, display geometry, alert names.

## Collectors that are off until you turn them on

| collector | why |
|---|---|
| `input` | needs Accessibility; counts key and click events (never keycodes) |
| `mail` | reads Apple Mail's envelope index for counts |
| `tabs` | asks browsers via AppleScript, which prompts for Automation permission |
| `media` | asks Music and Spotify via AppleScript (Automation prompt); track names stay off and hashed unless you say otherwise |
| `titles` | reads window titles, which needs Screen Recording; titles are hashed by default |
| `health` | accepts Apple Health numbers from an iPhone Shortcut; needs a token and stays local, see "Health data" below |
| `sensors` | reads hardware sensors through private Apple interfaces resolved at runtime; nothing personal, but undocumented APIs |

`/privacy` reports whether each of these is currently on.

## Health data

The `health` collector is the most personal thing Molly can hold: sleep, heart
rate, body mass. It is off by default and built to stay on your machine.

- **Nothing is accepted until you set `collectors.health.token`.** An empty
  token answers 401 to everything.
- **Local only by default.** With `server.bind` on a loopback address the
  endpoint is reachable only from this Mac. Posting from a phone needs a LAN
  bind, and then Molly refuses to start the collector (and answers 403) unless
  you also set `collectors.health.allowRemoteBind` to `true`. Bind to the LAN
  address only, never `0.0.0.0` on a laptop you carry to other networks.
- **`/metrics` is not authenticated.** Once Molly listens on the LAN, anyone on
  that network can read the health gauges. Keep the firewall on and the network
  trusted, or do not enable the collector.
- **Labels carry no personal text.** `type` is a fixed list, `reason` a fixed
  list, and `device` is a lowercased 32 character label capped at 5 values.
  Values are numbers.
- **Insights get buckets, not numbers.** The digest sent to the narrative
  backend contains only sleep (short, ok, long), movement (low, ok, high) and
  resting heart rate (down, flat, up). Nothing finer reaches the model unless
  you set `collectors.health.detailedInsights` to `true`.
- **At rest.** Per-day totals live in `state/health.json` for `maxAgeSeconds`;
  Prometheus keeps the series for its retention. `molly export` redacts the
  token. Forget data in Settings, or delete the series with the admin API, to
  remove history.

## Data at rest

Everything Molly writes lives under `~/Library/Application Support/Molly`
(cursors, logs) and the local stack's data folder (`deploy/data` by default,
`MOLLY_DATA_DIR` to move it). Prometheus keeps every series it has ever seen
for the retention period, so a label you later disable stays in history until
retention expires or you delete the series with the admin API.
