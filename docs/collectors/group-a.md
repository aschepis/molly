# Group A collectors: system, processes, focus, docker, meeting

Metrics below are what the code emits. Every metric also carries the registry's
`user` and `host` const labels. Label values that pass through a policy are
lowercased and trimmed by `LabelFilter`, so `Google Chrome` becomes `google chrome`.

## system (interval 15s)

CPU, memory, disk, network, battery, displays and other machine vitals. A source
that is missing or fails is skipped (logged once at debug) without affecting the rest.

| metric | type | labels | notes |
|---|---|---|---|
| `molly_cpu_seconds_total` | counter | `cpu` (core index or `total`), `mode` (user/system/nice/idle) | host_processor_info deltas at 100 ticks/s. `total` sums all cores, so it grows up to `cores` seconds per second. Counts from Molly's start only. |
| `molly_cpu_utilization_ratio` | gauge | | 0..1 across all cores since the previous run; absent until the second run |
| `molly_cpu_cores` | gauge | | logical cores |
| `molly_load_average` | gauge | `period` (1m/5m/15m) | getloadavg |
| `molly_memory_bytes` | gauge | `state` (free/active/inactive/wired/compressed) | host_statistics64, page size from getpagesize |
| `molly_memory_total_bytes` | gauge | | sysctl hw.memsize |
| `molly_memory_pressure_level` | gauge | | 1 normal, 2 warn, 4 critical |
| `molly_swap_bytes` | gauge | `state` (used/free) | sysctl vm.swapusage |
| `molly_swap_total_bytes` | gauge | | |
| `molly_uptime_seconds` | gauge | | now minus kern.boottime (includes time asleep) |
| `molly_boot_time_seconds` | gauge | | unix time |
| `molly_processes_count` | gauge | | proc_listpids |
| `molly_thermal_state` | gauge | | ProcessInfo.thermalState 0 nominal .. 3 critical |
| `molly_disk_total_bytes` / `molly_disk_free_bytes` | gauge | `mount`, `fstype` | statfs; local volumes with non-zero size only; skips devfs/autofs and `/System/Volumes/*` except `Data`. Free is space available to users. |
| `molly_disk_read_bytes_total` / `molly_disk_write_bytes_total` | counter | `device` | IOBlockStorageDriver Statistics; `device` is the BSD name (disk0) |
| `molly_disk_read_ops_total` / `molly_disk_write_ops_total` | counter | `device` | |
| `molly_network_receive_bytes_total` / `molly_network_transmit_bytes_total` | counter | `interface` | getifaddrs if_data (32-bit, wraparound handled). Skips `lo*` and interfaces that have never carried traffic. |
| `molly_network_receive_packets_total` / `molly_network_transmit_packets_total` | counter | `interface` | |
| `molly_network_receive_errors_total` / `molly_network_transmit_errors_total` | counter | `interface` | |
| `molly_network_vpn_active` | gauge | | 1 when a utun/ipsec/ppp/tun/tap interface has an IPv4 or non-link-local IPv6 address (Tailscale counts) |
| `molly_network_wifi_connected` | gauge | | CoreWLAN; 1 when associated. Always published when a Wi-Fi interface exists. |
| `molly_network_wifi_info` | gauge (=1) | `ssid` **policy** `wifi` | only when the `wifi` policy is enabled AND macOS lets the process read the SSID |
| `molly_battery_percent` | gauge | | IOPSCopyPowerSourcesInfo; absent on Macs without a battery |
| `molly_battery_charging` / `molly_battery_on_ac` | gauge | | |
| `molly_battery_time_remaining_seconds` | gauge | | time to empty, or to full while charging; -1 when unknown (including full on AC) |
| `molly_battery_cycle_count` | gauge | | AppleSmartBattery CycleCount |
| `molly_battery_health_ratio` | gauge | | AppleRawMaxCapacity / DesignCapacity, falling back to MaxCapacity percent |
| `molly_displays` | gauge | | active displays |
| `molly_display_info` | gauge (=1) | `display` (index), `width`, `height`, `scale` | width/height in points, scale rounded (2 on Retina) |
| `molly_dark_mode` | gauge | | UserDefaults AppleInterfaceStyle == Dark |
| `molly_bluetooth_devices_connected` | gauge | | IOBluetooth paired devices that are connected; count only |
| `molly_audio_output_volume_ratio` | gauge | | CoreAudio default output, 0..1; absent when the device has no volume control (some HDMI/USB outputs) |

Config keys:

| key | default | meaning |
|---|---|---|
| `enabled` | `true` | |
| `interval` | `15` | seconds between runs |
| `wifi` | `{"enabled": false}` | LabelPolicy for the SSID; off by default |
| `bluetooth` | `true` | set false to skip the IOBluetooth query |

Permissions: none for most sources. The SSID needs Location Services permission
for the host process on recent macOS; without it only `molly_network_wifi_connected`
is published. IOBluetooth may trigger a Bluetooth prompt for the host app the first time.
`molly doctor` reports SSID visibility when the `wifi` policy is enabled.

```json
"system": {
  "enabled": true,
  "interval": 15,
  "bluetooth": true,
  "wifi": { "enabled": false, "mode": "denylist", "patterns": [], "hash": false }
}
```

## processes (interval 30s)

Top processes by CPU and memory, aggregated by process name (a browser's dozens
of helpers become one series), plus per-agent process counts. Only processes the
user may inspect are seen; root daemons are skipped.

| metric | type | labels | notes |
|---|---|---|---|
| `molly_process_cpu_ratio` | gauge | `name` **policy** `names` | top `topN` by CPU; 1.0 is one full core, so values exceed 1 on multi-core use. Absent on the first run (needs a baseline). |
| `molly_process_resident_memory_bytes` | gauge | `name` **policy** `names` | top `topN` by resident memory |
| `molly_process_count_by_name` | gauge | `name` **policy** `names` | instance count for names in either top list |
| `molly_agent_processes` | gauge | `agent` | one series per configured agent, 0 when none running |
| `molly_agent_process_cpu_ratio` | gauge | `agent` | summed CPU ratio; absent on the first run |

When the `names` policy is disabled, only the agent metrics are published.

Config keys:

| key | default | meaning |
|---|---|---|
| `enabled` | `true` | |
| `interval` | `30` | |
| `topN` | `25` | processes kept per ranking |
| `names` | `{"enabled": true, "mode": "denylist", "maxCardinality": 25}` | LabelPolicy for process names |
| `agents` | see below | map of agent name to process-name substrings (case-insensitive) |

Built-in agents: `claude: ["claude"]`, `codex: ["codex"]`, `cursor: ["Cursor Helper", "cursor"]`,
`aider: ["aider"]`, `copilot: ["copilot"]`, `gemini: ["gemini"]`, `ollama: ["ollama"]`.
Entries in `agents` replace the built-in entry of the same name, add new agents, and
an empty list removes one. Matching is on the process name (falling back to the
executable file name), so a tool running as `node` is not matched unless you add `node`.

Permissions: none.

```json
"processes": {
  "enabled": true,
  "interval": 30,
  "topN": 25,
  "names": { "enabled": true, "mode": "denylist", "patterns": ["*password*"], "maxCardinality": 25 },
  "agents": { "claude": ["claude"], "windsurf": ["windsurf"], "gemini": [] }
}
```

## focus (interval 5s plus notification observers)

Event-driven for app activation, launches, terminations, sleep/wake, screen lock and
screensaver; the poll adds idle time and snapshots. Time is attributed with the state
known at the start of each interval, so after idle ends up to one poll interval is
still counted as idle. Intervals longer than `maxGapSeconds` are dropped.

| metric | type | labels | notes |
|---|---|---|---|
| `molly_focus_app` | gauge (=1) | `app`, `bundle_id` **policy** `apps` | exactly one series |
| `molly_focus_seconds_total` | counter | `app` **policy** `apps` | only while active (awake, unlocked, idle below threshold) |
| `molly_focus_switches_total` | counter | | frontmost app changes |
| `molly_focus_session_seconds` | gauge | | time in the current frontmost app |
| `molly_idle_seconds` | gauge | | CGEventSource seconds since any input |
| `molly_user_active` | gauge | | idle < `idleThresholdSeconds`, unlocked, awake |
| `molly_active_seconds_total` | counter | | |
| `molly_idle_seconds_total` | counter | | awake seconds that were not active (idle or locked); asleep time is excluded |
| `molly_screen_locked` | gauge | | |
| `molly_screen_lock_events_total` | counter | | |
| `molly_screensaver_active` | gauge | | |
| `molly_system_asleep` | gauge | | rarely observable: the scrape itself usually happens awake |
| `molly_sleep_events_total` / `molly_wake_events_total` | counter | | |
| `molly_running_apps` | gauge | | regular (Dock) apps |
| `molly_running_app` | gauge | `app` **policy** `apps` | |
| `molly_windows_on_screen` | gauge | | layer-0 windows from CGWindowListCopyWindowInfo; titles are never read |
| `molly_app_launches_total` / `molly_app_terminations_total` | counter | `app` **policy** `apps` | regular apps only |

With the `apps` policy disabled, all per-app series are dropped and the aggregates remain.
Counters cannot be folded afterwards, so `maxCardinality` on `apps` caps how many
distinct app labels counters may mint (later apps go to `other`); 0 means unlimited.

Config keys:

| key | default | meaning |
|---|---|---|
| `enabled` | `true` | |
| `interval` | `5` | |
| `apps` | `{"enabled": true, "mode": "denylist"}` | LabelPolicy for app names and bundle ids |
| `idleThresholdSeconds` | `300` | idle time after which the user counts as away |
| `maxGapSeconds` | `60` | longest interval that is credited |

Permissions: none. Window counting does not need Screen Recording because no titles are read.

```json
"focus": {
  "enabled": true,
  "interval": 5,
  "idleThresholdSeconds": 300,
  "apps": { "enabled": true, "mode": "denylist", "patterns": ["*bank*"], "maxCardinality": 0 }
}
```

## docker (interval 60s)

Shells out to the `docker` CLI (found in `/usr/local/bin`, `/opt/homebrew/bin`, ...,
or the `path` key). With no CLI or a stopped daemon it publishes
`molly_docker_available 0`, clears the other series, and reports the collector as unavailable.

| metric | type | labels | notes |
|---|---|---|---|
| `molly_docker_available` | gauge | | 1 when `docker ps` succeeds |
| `molly_docker_containers` | gauge | `state` | running/exited/paused/created always present; other states appear when seen |
| `molly_docker_container_info` | gauge (=1) | `name`, `image` **policy** `containers` | one series per container; both values go through the policy |
| `molly_docker_images` | gauge | | distinct image IDs |
| `molly_docker_volumes` | gauge | | |
| `molly_docker_container_cpu_ratio` | gauge | `name` **policy** `containers` | only with `stats: true` |
| `molly_docker_container_memory_bytes` | gauge | `name` **policy** `containers` | only with `stats: true` |

Config keys:

| key | default | meaning |
|---|---|---|
| `enabled` | `true` | |
| `interval` | `60` | |
| `stats` | `false` | run `docker stats --no-stream` (slow, a few seconds) |
| `path` | `""` | explicit docker binary; empty searches the usual locations |
| `containers` | `{"enabled": true, "mode": "denylist"}` | LabelPolicy for container names and images |

Permissions: access to the docker socket as the current user.

```json
"docker": {
  "enabled": true,
  "interval": 60,
  "stats": false,
  "containers": { "enabled": true, "mode": "denylist", "patterns": ["*-secret-*"] }
}
```

## meeting (interval 5s)

Whether the default microphone or any camera is in use by some process. This is a
proxy for being on a call: dictation or a voice memo also trips it.

| metric | type | notes |
|---|---|---|
| `molly_microphone_in_use` | gauge | CoreAudio DeviceIsRunningSomewhere on the default input |
| `molly_camera_in_use` | gauge | CoreMediaIO DeviceIsRunningSomewhere on any device |
| `molly_meeting_active` | gauge | mic or camera in use |
| `molly_microphone_in_use_seconds_total` | counter | |
| `molly_camera_in_use_seconds_total` | counter | |
| `molly_meeting_seconds_total` | counter | seconds with mic or camera in use |
| `molly_microphone_activations_total` / `molly_camera_activations_total` | counter | idle to in-use transitions |
| `molly_meetings_total` | counter | transitions from neither in use to either in use |

Config keys: `enabled` (`true`), `interval` (`5`).

Permissions: none; reading the running flags does not need Microphone or Camera access.

```json
"meeting": { "enabled": true, "interval": 5 }
```
