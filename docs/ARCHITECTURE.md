# Architecture

Molly is one Swift executable (`molly`) with no third-party packages. It
observes the machine, keeps the result as Prometheus metrics in memory, and
serves them over HTTP. Storage and visualization are Prometheus and Grafana in
Docker; Molly itself stores nothing but small cursors.

## Data flow

```
  macOS sources                 Molly process (127.0.0.1:9765)              Docker
  -------------                 ------------------------------              ------
  NSWorkspace, IOKit,   events  +-----------+  update  +------------------+
  sysctl, libproc  ---------->  | Collector |--------> |                  |
                                |  (timer   |          | MetricsRegistry  |  scrape   +------------+
  Browser/Messages/Notes/       |  queue)   |          |  (gauges,        | <-------- | Prometheus | 15s
  knowledgeC SQLite (copied     +-----+-----+          |   counters,      |  /metrics |  TSDB, 2y  |
  first, read-only) -------->         |                |   const labels   |           +-----+------+
                                      v                |   user, host)    |                 |
  git, ~/.claude, shell         +-----------+          +--------+---------+                 | PromQL
  history files -------------->| StateStore |                   |                          v
                                | (cursors)  |                   v                    +----------+
                                +-----------+          HTTPServer  /healthz          | Grafana  |
                                                       /collectors /config           | :3030    |
                                  Menu bar (NSStatusItem) <------- CollectorManager  +----------+
                                  pause, open links, status
```

## Collector model

A collector conforms to `Collector` (`Sources/Molly/Core/Collector.swift`):
`start(registry:)` registers its metrics and any notification observers (on the
main thread), `collect()` runs every `interval` seconds, `stop()` cleans up.
`CollectorManager` gives each collector its own serial utility-QoS queue and a
repeating timer, so a slow source (docker, git) never blocks the others.

Event-driven collectors, such as focus changes, sleep and wake and screen lock,
update metrics straight from observers and also poll briefly for derived values
like idle time.

A collector must not crash the app. Errors are caught per run, logged, and
counted in `molly_collector_errors_total`. `CollectorUnavailable` marks a source
the user must fix (permission, missing app) and is logged once. The manager
publishes `molly_collector_{runs_total,errors_total,duration_seconds,last_success_timestamp_seconds,enabled}`
per collector, plus `molly_up`, `molly_paused` and `molly_build_info`.

Collectors are wired in `CollectorRegistry.makeCollectors` and enabled or
disabled by the `collectors.<name>.enabled` config key.

## Metrics registry

`MetricsRegistry` (`Core/Metrics.swift`) is a hand-written implementation of the
Prometheus text exposition format. Collectors create gauges and counters by
name with fixed label names. The registry adds the constant labels `user`,
`host` and any `labels.extra` to every series; collectors never set them.
Names follow `molly_<area>_<thing>_<unit>`, counters end in `_total`.
`docs/METRICS.md` is the contract between collectors and dashboards.

## Privacy policies

Any label dimension that could identify something (domains, app names, repo
and project names, command names, SSIDs, hosts) passes through a `LabelPolicy`
(`Core/LabelPolicy.swift`), configured per collector:

- `enabled` turns the labeled metric on; sensitive dimensions default off.
- `mode` is allowlist or denylist, with glob `patterns` (a bare `bank.com` also matches subdomains).
- Allowlist misses become `other`, denylist hits become `redacted`, so totals stay correct.
- Optional `hash` with a `salt` replaces values with stable digests.
- `maxCardinality` caps distinct values; the rest fold into `other`.

The aggregate metric without the label is always published. Molly never
captures keystrokes, window titles, message text, URLs or command arguments.

## Cursors and state

History-style sources are read as "rows newer than the cursor" so counters only
increase. `StateStore` keeps one JSON file per collector under
`~/Library/Application Support/Molly/state/`. On first run the cursor starts at
process start, so a fresh install does not pour years of history into a
counter. Where a "today so far" value is cheap to compute, a `*_today` gauge is
published too, because it survives restarts.

Other apps' SQLite databases are never opened in place: `SQLiteSnapshot` copies
the database (plus WAL and SHM) to a temp folder and opens the copy read-only,
which avoids locks and cannot corrupt the source.

## HTTP endpoints

Served by a small `Network.framework` server on `server.bind:server.port`
(default `127.0.0.1:9765`). `server.bind` may be a list; the server then runs one
listener per address, all sharing one router. The first loopback address (else
the first) is the primary: if it cannot bind (for example a stale instance
still holds the port) `molly run` logs the error and exits non-zero so the
launch agent's `KeepAlive` restarts it rather than running blind. Any other
listener that fails to bind (a Tailscale address that does not exist until
Tailscale starts) is logged once and retried every 30 s; its state is the
`molly_server_listening{bind}` gauge and the `server.binds` list in `/stats`.

| path | purpose |
|---|---|
| `/metrics` | Prometheus exposition |
| `/healthz` | liveness, returns `ok` |
| `/collectors` | JSON per-collector status: runs, errors, last duration, last success, last error, unavailable since |
| `/stats` | JSON registry size: series and distinct label values per family, plus the collector status list; read by `molly tune` |
| `/config` | effective configuration as JSON, salts redacted |
| `/privacy` | every label policy, its settings and decision counts (see [PRIVACY.md](PRIVACY.md)) |
| `POST /event` | JSON event intake for `molly hook` and scripts; 204 on success, see [HOOKS.md](HOOKS.md) |
| `POST /health` | Apple Health samples from an iPhone Shortcut; token required, loopback bind unless allowed, see [HEALTH.md](HEALTH.md) |
| `GET /insights/latest`, `/insights/<date>[-week]` | Markdown reports written by `molly insights`, see [INSIGHTS.md](INSIGHTS.md) |
| `/` | index |

## Menu bar

`StatusItemController` shows an `NSStatusItem` with a status line (recording or
paused, collector count, how many are unavailable), time since the last scrape,
the endpoint, Pause/Resume, links to Grafana, Prometheus, `/metrics` and the
collector status, Open Data Folder, Reload Config and Quit. The `run` command
uses the accessory activation policy (no Dock icon); other subcommands never
start `NSApplication`.

## CLI

`run`, `once`, `doctor`, `validate`, `config-path`, `version`, plus
`install-agent`, `uninstall-agent` and `status` for launchd. The launch agent
(`~/Library/LaunchAgents/com.aschepis.molly.plist`) runs `molly run` with
`RunAtLoad` and `KeepAlive`, logging to `~/Library/Application Support/Molly/`.
`install-agent` prefers `/Applications/Molly.app/Contents/MacOS/molly` when it
exists so Full Disk Access granted to the app applies.

## Deployment stack

`deploy/docker-compose.yml` runs Prometheus (scrape every 15s, 2 year
retention, lifecycle endpoint on) and Grafana (port 3030, provisioned
datasource and dashboards). Prometheus scrapes `host.docker.internal:9765`;
Docker Desktop forwards that to the host's loopback, which is why Molly can
stay bound to 127.0.0.1. Recording rules and informational alerts live in
`deploy/prometheus/rules/molly.yml`. Both services keep their data in
`${MOLLY_DATA_DIR:-./data}` so one folder holds all history.

An optional `renderer` service (grafana-image-renderer) sits behind the compose
profile `render` and is not started by default. `make snap-dashboards` starts it
and saves each dashboard as `docs/screenshots/dashboard-<uid>.png`;
`make snap-settings` does the same for the Settings tabs via `molly settings`;
`make snapshots` runs both. PNGs are git-ignored.
