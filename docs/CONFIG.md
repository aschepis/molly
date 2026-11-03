# Configuration reference

Molly reads one JSON file. Every key is optional: a missing file or a missing
key means the default. This page is the commentary for
[`config/molly.example.json`](../config/molly.example.json), which lists every key at its default value.
Metric names and labels are in [METRICS.md](METRICS.md).

## Where the config lives

| item | default | override |
|---|---|---|
| config file | `~/Library/Application Support/Molly/config.json` | `MOLLY_CONFIG=/path/to/config.json` |
| data folder (state cursors, log) | `~/Library/Application Support/Molly` | `MOLLY_HOME=/path/to/folder` |

`MOLLY_CONFIG` wins over `MOLLY_HOME` for the config file. Both expand `~`.
Under launchd the variables must be set in the agent plist, not your shell.

| command | what it does |
|---|---|
| `molly config-path` | prints the config file location |
| `molly validate [path]` | parses the file (default: the config file), constructs every enabled collector, prints `ok: <path>`, the const labels and the enabled collectors. Prints `warning: unknown collector sections: ...` for misspelled section names. Exits 1 with a message on a hard error, such as invalid JSON or a bad policy |
| `molly once [--collector NAME]` | runs collectors once and prints the metrics text; policies still apply |
| `molly doctor` | checks permissions, ports and the local stack |
| `molly settings [tab]` | asks the running daemon to open the Settings window, optionally on `collectors`, `privacy`, `server`, `agents` or `maintenance`. `--close` hides it. Exits 1 when `/healthz` does not answer. Used by `scripts/snap-settings.sh` |

`validate` does not catch a misspelled key inside a collector section.
Unknown keys, and values of the wrong type for a plain key, are ignored and the
default is used. Label policies are stricter: a bad type there is an error.

A running Molly applies config changes only when you choose **Reload Config** in
the menu bar (command-R). Reload rebuilds every collector from the file, so
in-memory cardinality limits reset. Counter cursors on disk are kept. Restarting also works.
`molly run` does not watch the file.

### The /config endpoint

`GET http://127.0.0.1:9765/config` returns the effective configuration as JSON:
`server`, `labels` (the const labels with defaults resolved), `links` and the
`collectors` sections exactly as parsed. Every key named `salt` is replaced with
`"***"`. The endpoint has no authentication, like `/metrics`.

### Letting Molly suggest changes

`molly tune` reads the running daemon's `/stats` and `/collectors`, the
Prometheus scrape stats, and this file, then prints recommendations with the
JSON fragment each one would merge into the config. `molly tune --apply`
writes them after backing the file up next to it. See [TUNING.md](TUNING.md).

## Top-level keys

| key | type | default | meaning |
|---|---|---|---|
| `server.bind` | string | `"127.0.0.1"` | address for `/metrics`, `/healthz`, `/collectors`, `/config`. Non-empty |
| `server.port` | int | `9765` | 1 to 65535. Update `deploy/prometheus/prometheus.yml` if you change it |
| `labels.user` | string or null | `null` | value of the `user` label on every series. `null` means the macOS account name |
| `labels.host` | string or null | `null` | value of the `host` label. `null` means the short hostname |
| `labels.extra` | object of strings | `{}` | more const labels on every series, for example `{"env": "laptop"}`. Names must be valid Prometheus label names. `user` and `host` here are overridden by `labels.user` and `labels.host` |
| `links.grafana` | string | `"http://localhost:3030"` | URL opened by the menu bar item |
| `links.prometheus` | string | `"http://localhost:9090"` | URL opened by the menu bar item |
| `mcp.prometheusURL` | string | `links.prometheus` | Prometheus the `molly mcp` tools query |
| `mcp.mollyURL` | string | `http://<server.bind>:<server.port>` | running Molly the `molly mcp` tools read `/metrics` and `/collectors` from |
| `export.prometheusDataDir` | string | checkout's `deploy/data/prometheus`, else `~/Library/Application Support/Molly/prometheus` | where the Prometheus TSDB lives on disk, so `molly export` can copy snapshots. Set it when you started the stack with `MOLLY_DATA_DIR` (or export that variable) |
| `stack.retention` | string | `"2y"` | Prometheus retention the Settings window applies to the local stack (`PROMETHEUS_RETENTION` in `deploy/.env`). A Prometheus duration: `90d`, `26w`, `2y` |
| `stack.composeDir` | string | the checkout's `deploy/` folder, found like `export.prometheusDataDir` | where `docker-compose.yml` lives, so the retention knob can rewrite `.env` and recreate Prometheus |
| `logLevel` | string | `"info"` | `debug`, `info`, `warn` or `error` |
| `collectors` | object | `{}` | one object per collector, keyed by collector name |

Binding to anything but loopback exposes metrics, which can include app, repo
and domain names, to your network. See [Getting started](GETTING-STARTED.md#using-a-remote-prometheus).

## Keys every collector accepts

| key | type | default | meaning |
|---|---|---|---|
| `enabled` | bool | `true`; `false` for `mail` | turns the collector on or off |
| `interval` | number | per collector, below | seconds between runs. Zero or negative falls back to the default |

Sections are keyed by these names: `process`, `system`, `network`, `processes`, `focus`,
`docker`, `meeting`, `browser`, `messages`, `notes`, `knowledge`, `calendar`,
`reminders`, `mail`, `git`, `claude_code`, `cursor`, `codex`, `shell`, `projects`, `events`, `health`.

## LabelPolicy reference

Any label that could identify something (an app, a domain, a repo, a command, a
network name) is governed by a LabelPolicy. A policy is a JSON object. Every
key is optional; a missing key keeps the collector's default for that policy,
which the collector sections below list.

```json
"domains": {
  "enabled": false,
  "mode": "denylist",
  "patterns": [],
  "hash": false,
  "salt": "",
  "maxCardinality": 50
}
```

| key | type | meaning |
|---|---|---|
| `enabled` | bool | `false` turns the labeled series off. Sensitive dimensions default to `false` |
| `mode` | `"allowlist"` or `"denylist"` | what `patterns` means |
| `patterns` | array of strings | values to match, see below |
| `hash` | bool | replace values that pass with a salted hash |
| `salt` | string | mixed into the hash |
| `maxCardinality` | int, 0 or more | most distinct label values to publish. `0` means unlimited |

### Enabled

When `enabled` is `false` the labeled series is dropped, or collapses into one
series whose label is `redacted`. This is stated per metric in METRICS.md.
The unlabeled aggregate is always published, so totals stay correct.

### Allowlist and denylist

Values are trimmed and lowercased first, then compared to `patterns`.

| mode | value matches a pattern | value matches none |
|---|---|---|
| `denylist` | becomes `redacted` | published as is |
| `allowlist` | published as is | becomes `other` |

- `other` means "not on my list". `redacted` means "on my deny list".
- An empty denylist publishes everything. An empty allowlist turns everything into `other`.
- An empty value becomes `other`.
- Matching happens on the plain value, before hashing.
- Collapsed values still count toward totals, they just share one label value.

### Pattern syntax

Patterns are case-insensitive. Whitespace around them is ignored.

| pattern | matches | does not match |
|---|---|---|
| `example.com` | `example.com`, `www.example.com`, `a.b.example.com` | `myexample.com` |
| `*bank*` | any value containing `bank` | |
| `*.corp.example` | `vpn.corp.example` | `corp.example` |
| `acme/*` | `acme/web`, `acme/api` | `other/acme` |
| `git` | `git`, `foo.git` | `gitk` |

A pattern with no `*` matches the whole value or any dotted suffix of it, so
`example.com` covers every subdomain. A pattern with `*` must match the whole
value, where `*` is any run of characters. There are no other metacharacters.
An empty pattern is an error.

### Hashing and salt

With `hash: true`, a value that passes becomes `h_` plus 12 hex characters of
SHA-256 over `salt + value`. Dashboards can tell values apart without naming
them. Notes:

- Set a random `salt`. Without one, anyone can hash a list of candidate names and compare.
- Hashes are stable only while the salt is unchanged. Changing it starts new series.
- Hashing hides names from casual reading. It is not encryption, and short guessable values can still be recovered with the salt.
- `redacted` and `other` are never hashed.
- `/config` shows the salt as `***`, but the file on disk holds it in plain text.

### maxCardinality

`maxCardinality` limits how many distinct values a policy publishes. The rest
fold into `other`. Collectors apply it in one of two ways:

| style | used by | behavior |
|---|---|---|
| per run | processes, browser, knowledge, notes, calendar | each run keeps the N largest values and folds the rest into `other` |
| most recent N | projects, git gauges | each run keeps the N most recently active projects or repos |
| first N seen | counters in focus, git, claude_code, shell | the first N distinct values since Molly started keep their own series, later ones go to `other` |

Caveat: these caps are per run or per process lifetime. They do not bound the
total number of series in Prometheus over time. A per-run top 50 can show
different domains on different days, and a restart or Reload Config resets the
first-N sets. Prometheus keeps every series it has ever seen for the whole
retention period (two years in the local stack). To bound the series count for
good, use an allowlist with a fixed set of patterns.

## Example files

| file | intent |
|---|---|
| [`config/molly.example.json`](../config/molly.example.json) | every key at its default, every policy written out in full. Copy and trim it. `path` is omitted for `calendar` and `mail` because those are auto-detected |
| [`config/molly.privacy-strict.json`](../config/molly.privacy-strict.json) | aggregates only. Every sensitive policy disabled, and `messages`, `mail`, `knowledge` and `calendar` off. Totals such as CPU, focus seconds and commit counts remain, with no names |
| [`config/molly.developer.json`](../config/molly.developer.json) | domains on with a banking and health denylist and `maxCardinality` 30, shell commands allowlisted to common dev tools, git roots `~/src` and `~/work`, a Claude pricing override example, Wi-Fi off |

Use one with `MOLLY_CONFIG=$PWD/config/molly.developer.json swift run molly validate`,
or copy it to the config path. The privacy-strict file still reads app, repo and
process names in memory to count them; it just never exports them. Agent names
under `processes.agents` are not policy-governed and stay visible.

The developer file's pricing entry is an illustration of the key, not a price quote.

## Collector reference

Policy defaults are written as: enabled, mode, maxCardinality. All policies
default to `hash: false`, `salt: ""` and no patterns.

### process

Molly's own memory, CPU and thread count. Interval 30s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `enabled`, `interval` | | `true`, `30` | |

Permissions: none. Privacy: reads only Molly's own process.

### system

Interval 15s, enabled by default. CPU, memory, disk, Wi-Fi, battery, display and other vitals.

| key | type | default | meaning |
|---|---|---|---|
| `bluetooth` | bool | `true` | set `false` to skip the IOBluetooth query |
| `wifi` | policy | disabled, denylist, 0 | governs the `ssid` label of `molly_network_wifi_info` |

Permissions: none for most sources. The SSID needs Location Services for the host
process; without it only `molly_network_wifi_connected` is published. IOBluetooth
may prompt once for Bluetooth. Privacy: never reads traffic, hostnames, device
names or file contents. Sources that fail are skipped.

### network

Interval 30s, enabled by default. Primary interface and its type, VPN state, per-interface traffic.

| key | type | default | meaning |
|---|---|---|---|
| `probeURL` | string | `""` | http(s) URL to HEAD each run for `molly_network_probe_*`; empty turns the probe off |
| `captiveCheck` | bool | `false` | fetch `http://captive.apple.com/hotspot-detect.html` each run for `molly_network_captive_portal` |

Permissions: none. Privacy: interface names and byte counters only; the
Wi-Fi SSID stays behind `system.wifi`. The probe and captive check are the only
outbound requests and are off by default.

### processes

Interval 30s, enabled by default. Top processes aggregated by name, plus agent counts.

| key | type | default | meaning |
|---|---|---|---|
| `topN` | int | `25` | processes kept per ranking, minimum 1 |
| `names` | policy | enabled, denylist, 25 | process names. When disabled only agent metrics are published |
| `agents` | object | see below | agent name to list of process-name substrings, case-insensitive |

Built-in agents: `claude: ["claude"]`, `codex: ["codex"]`,
`cursor: ["Cursor Helper", "cursor"]`, `aider: ["aider"]`, `copilot: ["copilot"]`,
`gemini: ["gemini"]`, `ollama: ["ollama"]`. An entry replaces the built-in of the
same name, a new name adds an agent, and an empty list removes one.

Permissions: none; only processes you may inspect are seen. Privacy: names and
resource use only. Command lines, arguments, paths and environment are never read.

### focus

Interval 5s plus app, sleep, wake and lock notifications. Enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `idleThresholdSeconds` | number | `300` | idle time after which the user counts as away |
| `maxGapSeconds` | number | `60` | longest interval credited to one state |
| `apps` | policy | enabled, denylist, 0 | app names and bundle ids. When disabled all per-app series are dropped |

Permissions: none. Privacy: app names only. Window titles are never read, and
no keystrokes, clicks or screen content are captured. Idle time is the
system's "seconds since last input" value.

### docker

Interval 60s, enabled by default. Uses the `docker` CLI.

| key | type | default | meaning |
|---|---|---|---|
| `stats` | bool | `false` | run `docker stats --no-stream` for per-container CPU and memory. Slow |
| `path` | string | `""` | docker binary. Empty searches the usual locations |
| `containers` | policy | enabled, denylist, 0 | container names and images. `maxCardinality` is not applied by this collector |

Permissions: access to the docker socket as your user. Without docker, only
`molly_docker_available 0` is published. Privacy: names, images and states
only. Environment, logs, mounts and commands are not read.

### meeting

Interval 5s, enabled by default. No other keys.

Permissions: none. Reading the "running" flag does not need Microphone or Camera
access. Privacy: only whether a device is in use. Audio and video are never captured.

### input

Interval 5s, **disabled by default**. Counts key, click and scroll events
through a listen-only event tap. No other keys.

Permissions: Accessibility (or Input Monitoring) for the molly binary or
Molly.app. Without it the collector reports unavailable and
`molly_input_available` is 0; `molly doctor` checks this when the collector is
enabled. Privacy: counts only. The aggregator has no field that could hold a
keycode, character or pointer position, and a test asserts that.

### clipboard

Interval 2s, enabled by default. No other keys.

Permissions: none. Privacy: the clipboard's change counter, its declared
content types and the byte length of the primary representation are read.
Contents are never read, logged or exported.

### hardware

Interval 30s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `dockedMinExternalDisplays` | int | `1` | external displays needed for `molly_docked` to be 1 |
| `devices` | policy | disabled, denylist, 20 | USB product names and default audio device names |

Permissions: none. Privacy: device counts always; device names only behind
the `devices` policy.

### browser

Interval 60s, enabled by default. Browsing history counts.

| key | type | default | meaning |
|---|---|---|---|
| `browsers` | array of strings | `[]` | restrict to these browsers. Empty means all detected: safari, chrome, chrome_beta, chrome_canary, brave, arc, edge, vivaldi, firefox, orion |
| `extraProfiles` | array of objects | `[]` | `{"browser": "chrome", "path": "/path/to/History"}`. The schema follows the name: `safari` and `orion` use Safari's, `firefox` Firefox's, anything else Chromium's |
| `domains` | policy | **disabled**, denylist, 50 | governs `domain` |

Permissions: Full Disk Access for Safari only. Privacy: histories are copied and
read read-only. Only the host name of http, https and ftp URLs is used. Full
URLs, paths, queries, page titles and search terms are never exported or
logged. Domain labels require opting in.

### messages

Interval 60s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `path` | string | `~/Library/Messages/chat.db` | database location |

Permissions: Full Disk Access. Privacy: aggregate counts only. No text,
contacts, handles or chat names are selected. There is no label policy because
no identifying label exists.

### notes

Interval 120s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `path` | string | `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` | database location |
| `folders` | policy | **disabled**, denylist, 50 | folder names for `molly_notes_folder_modified_total` |

Permissions: Full Disk Access. Privacy: note titles and bodies are never selected.

### knowledge

Interval 60s, enabled by default. System usage records from `knowledgeC.db`.

| key | type | default | meaning |
|---|---|---|---|
| `path` | string | `~/Library/Application Support/Knowledge/knowledgeC.db` | database location |
| `apps` | policy | enabled, denylist, 50 | bundle ids. When disabled they become `redacted` |

Permissions: Full Disk Access. Privacy: bundle ids and durations only. No content.

### calendar

Interval 300s, enabled by default. Reads Calendar's database, not EventKit.

| key | type | default | meaning |
|---|---|---|---|
| `path` | string | auto-detected | override the database location. Omit it to auto-detect |
| `calendars` | policy | **disabled**, denylist, 50 | calendar names. When disabled one `redacted` series is published |

Permissions: Full Disk Access. Privacy: event titles, locations, attendees and
notes are never selected. Only counts and durations are published.

### reminders

Interval 300s, enabled by default. Reads every `Data-*.sqlite` store (one per
account) under the Reminders group container and sums them.

| key | type | default | meaning |
|---|---|---|---|
| `path` | string | auto-detected | read this single store instead of all `Data-*.sqlite` files. Omit it to auto-detect |
| `lists` | policy | **disabled**, denylist, 50 | list names. When disabled one `redacted` series is published per per-list metric |

Permissions: Full Disk Access. Privacy: reminder titles, notes and locations
are never selected. Only counts are published.

### mail

Interval 120s, **disabled by default**. Best effort against Apple Mail's Envelope Index.

| key | type | default | meaning |
|---|---|---|---|
| `enabled` | bool | `false` | opt in |
| `path` | string | auto-detected | override the database location. Omit it to auto-detect |

Permissions: Full Disk Access. Privacy: only mailbox URLs (to tell sent from
received) and counts. Senders, recipients, subjects and bodies are never read.
A schema change in a macOS update makes the collector report unavailable.

### git

Interval 120s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `roots` | array of strings | `["~/src"]` | directories searched for repositories |
| `maxDepth` | int | `4` | levels below a root, minimum 0 |
| `skipDirs` | array of strings | `["node_modules", ".build", "vendor"]` | directory names never entered |
| `rescanSeconds` | number | `1800` | how long the repo list is cached |
| `activeDays` | int | `30` | a repo is active if it changed within this many days, minimum 1. Only active repos get labeled series |
| `authorEmails` | array of strings | `[]` | extra emails counted as `author="me"`, besides global `git config user.email` |
| `repos` | policy | enabled, denylist, 50 | the `repo` label (`owner/name` from `origin`, else the directory name) |
| `branches` | policy | enabled, denylist, 0 | the `branch` label of `molly_git_branch_info` |

Permissions: read access to the roots and `git` on the PATH. Privacy: runs only
read-only git commands without locks. Commit messages, file names, diffs and
author emails are never exported. Emails are compared in memory only.

### claude_code

Interval 60s, enabled by default. Claude Code usage from local transcripts.

| key | type | default | meaning |
|---|---|---|---|
| `projectsDir` | string | `~/.claude/projects` | transcript directory |
| `historyFile` | string | `~/.claude/history.jsonl` | prompt history, lines are counted only |
| `activeWindowSeconds` | number | `300` | a session is active if modified within this window |
| `sessionGapSeconds` | number | `1800` | longest gap counted as session time |
| `pricing` | object | `{}` | price overrides, see below |
| `projects` | policy | enabled, denylist, 30 | the `project` label. When disabled it is `redacted` |

`pricing` maps a model-id substring to USD per million tokens:
`{"claude-sonnet": {"input": 3, "output": 15, "cacheRead": 0.3, "cacheWrite": 3.75}}`.
Overrides are tried before the built-in table, in alphabetical order of the
pattern, and the first substring match wins. A missing field counts as 0.
Cost is an estimate from list prices, not a bill; unknown models cost 0.
Built-in prices are in [group C](collectors/group-c.md#claude_code).

Permissions: read access to `~/.claude`. Privacy: only message type, model,
timestamps, token usage, working directory and tool names are parsed. Prompt
text, responses, tool inputs and results are never read into metrics.

### cursor

Interval 120s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `databasePath` | string | `~/.cursor/ai-tracking/ai-code-tracking.db` | Cursor's attribution database |

Permissions: read access to the file. Privacy: only row counts and newest
timestamps are selected. Code, prompts, file names and hashes are never read.

### codex

Interval 120s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `sessionsDir` | string | `~/.codex/sessions` | session transcript directory |
| `activeWindowSeconds` | number | `300` | active-session window |

Permissions: read access to the directory. Unavailable when it is missing.
Privacy: only line type, role, model and token counts. Message content and the
working directory are ignored. There is no project label.

### shell

Interval 60s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `shells` | array of strings | `["zsh", "bash", "fish"]` | which histories to read |
| `zshHistory` | string | `~/.zsh_history` | |
| `bashHistory` | string | `~/.bash_history` | |
| `fishHistory` | string | `~/.local/share/fish/fish_history` | |
| `commands` | policy | **disabled**, allowlist, 50 | the first word of each command. An allowlist is recommended |
| `hosts` | policy | **disabled**, denylist, 50 | the `remote_host` label, from URLs and curl, wget, ssh, scp and similar |

Permissions: read access to the history files. Privacy: with both policies
disabled only counts are published. Command text is held in memory to extract
a name and host and is never stored, logged or exported. Arguments never
appear in a label.

### projects

Interval 60s, enabled by default. The union of activity that `git` and `claude_code` report.

| key | type | default | meaning |
|---|---|---|---|
| `activeWindowSeconds` | number | `1800` | a project is active if it had activity within this window |
| `retentionSeconds` | number | `86400` | projects idle longer than this are dropped |
| `projects` | policy | enabled, denylist, 30 | the `project` label. Set it here too: each collector reads its own section |

Permissions: none. Privacy: derived data only; nothing is read from disk.

### power

Interval 300s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `backfillSeconds` | number | `86400` | on the first run, events this far before Molly started are counted, so a fresh install explains the last day |

Permissions: none. Runs `pmset -g log` and `sysctl kern.boottime`. Privacy:
only sleep, wake and dark wake lines are read. Wake reasons are mapped to a
fixed set (lid, power button, user activity, scheduled, notification, other);
raw reason text is never exported. Details: [group D](collectors/group-d.md#power).

### forensics

Interval 300s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `backfillSeconds` | number | `86400` | on the first run, shutdowns and reports this far before Molly started are counted; boots are never backfilled |
| `processes` | policy | enabled, denylist, 30 | the `process` label of `molly_crash_reports_by_process_total` |

Permissions: none. Runs `sysctl -n kern.boottime` and `last -y shutdown`, and
lists `~/Library/Logs/DiagnosticReports` and `/Library/Logs/DiagnosticReports`
by filename and modification time. Only the first line of an `.ips` file (its
JSON header) is read, and only for its process name.

### builds

Interval 15s, enabled by default.

| key | type | default | meaning |
|---|---|---|---|
| `tools` | object | see `config/molly.example.json` | tool name to process-name patterns. A config entry replaces that tool's defaults; an empty list turns it off; a new key adds a tool |
| `xcode` | bool | `true` | count Xcode build logs and measure DerivedData |
| `derivedDataPath` | string | `~/Library/Developer/Xcode/DerivedData` | |
| `derivedDataSeconds` | number | `1800` | minimum seconds between `du` runs (floor 60) |

Patterns match the whole process name, case-insensitively; a trailing `*` is a
prefix match. Permissions: none. Privacy: process names are matched in memory;
only tool names from this config are exported. Details: [group D](collectors/group-d.md#builds).

### tabs

Interval 60s, **disabled by default**. Enable it with `"enabled": true`.

| key | type | default | meaning |
|---|---|---|---|
| `browsers` | array of strings | all of `safari`, `chrome`, `brave`, `arc`, `edge`, `vivaldi` | which browsers to ask, when running |

Permissions: Automation, one prompt per browser on first run. Privacy: only
window and tab counts are requested; titles and URLs are never read.
Details: [group D](collectors/group-d.md#tabs).

### gaming

Interval 5s. On by default; if the machine has no Steam, CrossOver or game apps
the collector reports itself unavailable once and does nothing.

| key | type | default | meaning |
|---|---|---|---|
| `steamPath` | string | `~/Library/Application Support/Steam` | the Steam folder; `steamapps/libraryfolders.vdf` adds other library volumes |
| `libraryIntervalSeconds` | number | `300` | how often manifests and Steam playtime are re-read (game apps are rescanned hourly) |
| `extraGameBundleIds` | array of strings | `[]` | apps to treat as games although their Info.plist is not in the games category |
| `extraProcessNames` | array of strings | `[]` | executable names to treat as native games (emulators, itch.io builds) |
| `gpuThreshold` | number | `0.3` | GPU device utilisation (0..1) that, for two samples in a row, counts a Steam or CrossOver game as played while it is not frontmost |
| `maxGapSeconds` | number | `180` | how long a session survives without the game being frontmost or the GPU busy |
| `games` | policy | off, denylist, max 30 | the `game` label on per-game seconds, launches, playtime and last played |

Permissions: none. Privacy: Steam files are read for game names and
`LastPlayed`/`Playtime` only; `loginusers.vdf`, friends, chat and achievements
are never opened. Game names stay off unless you enable the `games` policy
(add `patterns` to hide particular titles). State (`gaming.json`) keeps the last
Steam playtime per app and the open session so restarts neither double count
nor split a session.

### media

Interval 15s, **disabled by default**. Asks Music and Spotify, when they are
running, whether they are playing and what the current track is.

| key | type | default | meaning |
|---|---|---|---|
| `apps` | array of strings | `["music", "spotify"]` | which players to ask, when running |
| `tracks` | policy | off, denylist, hash on, max 100 | the `track` and `artist` labels on `molly_media_track_info`; each value is filtered separately |

Permissions: Automation, one prompt per player on first run (reset with
`tccutil reset AppleEvents`). Privacy: playback state and timing are always
exported; track and artist names only when the `tracks` policy is enabled,
and hashed unless you set `"hash": false`. The current (track, artist) pair is
held in memory to detect changes and never logged.

### titles

Interval 5s, **disabled by default**. The title of the frontmost window.

| key | type | default | meaning |
|---|---|---|---|
| `titles` | policy | on, denylist, hash on, max 100 | the `title` label; `"hash": false` exports plain titles |

The `app` label uses the focus collector's `apps` policy so both agree.
Titles are normalised before filtering: whitespace collapsed, known app
suffixes (" - Google Chrome", " - Visual Studio Code", "— Edited", ...)
removed, truncated to 80 characters. An empty title is `other`.

Permissions: Screen Recording (System Settings > Privacy & Security > Screen
Recording, add the molly binary or Molly.app); without it macOS hides every
title and the collector reports unavailable. `molly doctor` checks this when
`titles` is enabled. Privacy: this is the leakiest dimension Molly has. Hashed
titles still let a dashboard rank "which documents got the most time" without
naming them; keep the default unless you have a denylist you trust.

### events

Interval 60s, enabled by default. Receives `POST /event`, the target of
`molly hook` (Claude Code hooks) and of any script. See [HOOKS.md](HOOKS.md).

| key | type | default | meaning |
|---|---|---|---|
| `activeWindowSeconds` | number | `300` | a hook session counts as active this long after its last event |
| `token` | string | `""` | when set, requests must carry `Authorization: Bearer <token>` |
| `projects` | policy | enabled, denylist, 30 | the `project` label derived from the hook's `cwd` (Claude Code hooks and the shell hook) |

Permissions: none. Privacy: only `hook_event_name`, `tool_name`, `session_id`
and the project name from `cwd` are used; prompts, tool input and transcript
paths are discarded. Label values from payloads are sanitized and capped at 64
characters. The shell hook (`molly shell-hook`) posts source `shell` with the
shell name, the last exit status and `cwd`; the path is reduced to a project
name and never stored. The snippet bakes in `server.bind`, `server.port` and
`token`, so re-run `molly shell-hook install` after changing them.

### health

Interval 60s, **disabled by default**. Receives `POST /health` from an iPhone
Shortcut; see [HEALTH.md](HEALTH.md) for the setup and the payload.

| key | type | default | meaning |
|---|---|---|---|
| `token` | string | `""` | required: `Authorization: Bearer <token>` or a `token` field in the body. An empty token refuses every post (401). Redacted in `/config` |
| `maxAgeSeconds` | number | `604800` | samples that ended longer ago are rejected as `too_old`; also how many days of totals are kept |
| `allowRemoteBind` | bool | `false` | health data stays local: with a non-loopback `server.bind` the collector will not start and the route answers 403 until this is `true` |
| `detailedInsights` | bool | `false` | when false the insights digest gets only coarse buckets (sleep short/ok/long, movement low/ok/high, resting heart rate down/flat/up); when true it also gets the underlying numbers |

Permissions: none. Privacy: see "Health data" in [PRIVACY.md](PRIVACY.md).

### insights

Interval 300s, **disabled by default**. Writes a Claude-generated daily (and
weekly) report from Prometheus data; every report costs API money or
subscription budget. See [INSIGHTS.md](INSIGHTS.md).

| key | type | default | meaning |
|---|---|---|---|
| `dailyAtHour` | number | `21` | local hour (0-23) after which today's report is generated once |
| `weekly` | bool | `true` | also write last week's report on Mondays |
| `model` | string | `claude-sonnet-5-5` | model for the `api` backend |
| `apiKey` | string | `""` | Claude API key; `ANTHROPIC_API_KEY` in the environment wins. Redacted in `/config` |
| `backend` | string | `auto` | `auto` (key, else CLI), `api`, or `cli` |
| `prometheusURL` | string | `links.prometheus` | where to read the history from |

Permissions: none. Privacy: only the policy-filtered digest of aggregate
numbers is sent, and only to the backend you configured.

## Auditing what leaves the box

Every `LabelPolicy` is registered with a privacy audit when its collector
reads it, under the name `<collector>.<key>` (for example `browser.domains`).
Each decision the filter makes is counted: `passed`, `other` (allowlist miss
or cardinality fold), `redacted` (denylist hit or policy off), `hashed`. Raw
values are never stored.

- `GET /privacy` returns the dimensions with their effective policy (mode,
  pattern count, hash, maxCardinality; never the patterns themselves), the
  counts, the labels on every series, and whether each opt-in collector
  (`input`, `mail`, `tabs`) is on.
- `molly privacy` prints the same as a table (`--json` for the raw report). It
  asks the running daemon; with no daemon it builds the collectors from the
  config and shows policies with zero counts.
- `molly_privacy_label_decisions_total{dimension,outcome}` carries the counts
  into Prometheus.

[PRIVACY.md](PRIVACY.md) lists every dimension, its default, the raw value it
governs, and the metrics that carry it.

## Next steps

- [METRICS.md](METRICS.md) lists the metrics each collector publishes.
- [PRIVACY.md](PRIVACY.md) lists every sensitive label dimension.
- [Getting started](GETTING-STARTED.md) covers permissions and the local stack.
- [Collector deep dives](collectors/group-a.md): [B](collectors/group-b.md), [C](collectors/group-c.md), [D](collectors/group-d.md).
