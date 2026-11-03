# Getting started

Molly runs on macOS 13+. The local stack (Prometheus and Grafana) needs Docker Desktop.

## 1. Build

```sh
swift build            # debug build, binary at .build/debug/molly
swift test
swift run molly doctor # checks permissions, ports and stack reachability
```

For an app bundle you can grant permissions to and run at login:

```sh
make app               # dist/Molly.app (release build, ad-hoc signed)
make install           # copies it to /Applications/Molly.app
```

## 2. Grant Full Disk Access

Safari history, Messages, Notes, knowledgeC and the Calendar database are
protected by macOS. Without Full Disk Access those collectors report
"unavailable" and everything else keeps working.

During development the permission belongs to the process that launches Molly,
which is your terminal:

1. System Settings > Privacy & Security > Full Disk Access.
2. Add your terminal app (Terminal, iTerm, Ghostty, ...) and switch it on.
3. Quit and reopen the terminal, then run `swift run molly doctor`.

For the installed app:

1. System Settings > Privacy & Security > Full Disk Access.
2. Click `+`, choose `/Applications/Molly.app`, switch it on.
3. If you rebuild and reinstall, macOS may ask again because the ad-hoc signature changes.

The Calendar collector reads Calendar's database directly and does not use
EventKit, so it needs Full Disk Access rather than a Calendar prompt.
Microphone and camera prompts should not appear; Molly reads only whether the
device is in use, never audio or video. Reading the Wi-Fi SSID (only when the
`wifi` policy is enabled) needs Location Services for the host process.

## 3. Start the stack

```sh
make stack-up          # or: cd deploy && docker compose up -d
```

- Prometheus: <http://localhost:9090>
- Grafana: <http://localhost:3030>, sign in with `admin` / `admin`

Set `GF_SECURITY_ADMIN_PASSWORD` in your environment before the first start to
use a different password. Grafana is on 3030 so it does not collide with
anything already using 3000.

## 4. Start Molly

```sh
swift run molly            # menu bar icon appears, metrics on http://127.0.0.1:9765/metrics
molly status               # agent state, /healthz, and the Prometheus target
```

Prometheus in Docker reaches Molly's loopback-only server through
`host.docker.internal`, so nothing is exposed on your network.

The menu bar menu shows recording state, the last scrape, a Status submenu
with every collector, Pause/Resume, links to Grafana, Prometheus, `/metrics`
and the latest insights report, Run Doctor (logs each failing check and, from
Molly.app, posts a notification with the summary), Reload Config, and Launch
at Login.

### Installing Molly.app and starting at login

```sh
make app                   # dist/Molly.app with the icon from packaging/AppIcon.icns
make install               # copies it to /Applications
make dist                  # dist/Molly-<version>.zip plus a .sha256 next to it
```

Two ways to start Molly at login; pick one:

| | Launch at Login (menu bar) | `molly install-agent` |
|---|---|---|
| Needs | `/Applications/Molly.app` | any `molly` binary, bundle or not |
| Mechanism | `SMAppService`, listed under System Settings > General > Login Items | a LaunchAgent plist in `~/Library/LaunchAgents` with `KeepAlive` |
| Restarts after a crash | no | yes |
| Remove | untick the menu item or the Login Items switch | `molly uninstall-agent` |

From `swift run` or the bare `.build` binary the menu item is disabled and
says "install Molly.app first"; use the LaunchAgent instead. Do not enable
both, or two copies will fight over port 9765.

The app icon is generated, not hand-drawn: `make icon` re-renders
`packaging/AppIcon.icns` from `scripts/render-icon.swift` with the tools that
ship with macOS.

## 5. Look at the dashboards

Open Grafana and go to Dashboards > Molly. Nothing needs importing:
the datasource (`molly-prometheus`) and the six dashboards are provisioned from
`deploy/grafana/`. Edits you make in the UI are not saved back to the files;
change the JSON in `deploy/grafana/dashboards/` instead (Grafana reloads it
within 30 seconds). See [DASHBOARDS.md](DASHBOARDS.md).

Dashboards fill in as data arrives; the first scrape is within 15 seconds but
rate panels need a minute or two of history.

## Your data folder

Everything the stack stores lives in `deploy/data/` by default
(`prometheus/` and `grafana/`). Point it elsewhere with `MOLLY_DATA_DIR`:

```sh
MOLLY_DATA_DIR=~/MollyData docker compose up -d
```

To back up or move your history, run `make stack-down`, copy the folder, and
bring the stack up on the new machine with `MOLLY_DATA_DIR` pointing at the copy.
Retention is two years by default; change it with `PROMETHEUS_RETENTION`
(`PROMETHEUS_RETENTION=90d docker compose up -d`) or prune on demand with
`molly prune --older-than 30d`. Molly's own state (import cursors, config)
lives in `~/Library/Application Support/Molly`.

`molly export` writes a dated tarball (config with secrets redacted, cursors,
insights reports, a `/metrics` snapshot, and a Prometheus TSDB snapshot) to
`~/Library/Application Support/Molly/backups/`; `molly export --restore
<tarball>` prints the manual restore steps. Snapshots and pruning use the
Prometheus admin API, which the compose file enables with
`--web.enable-admin-api`; stacks started before that flag existed need
`make stack-down && make stack-up` once.

## Using a remote Prometheus

Molly binds to `127.0.0.1` by default. To let another machine scrape it, set a
reachable address in `~/Library/Application Support/Molly/config.json`:

```json
{ "server": { "bind": "0.0.0.0", "port": 9765 } }
```

Warning: `/metrics` has no authentication. Bind to a specific interface address
(a VPN or Tailscale IP is ideal) and firewall the port rather than exposing it
to an untrusted network. Metric labels can reveal app names, repo names and
domains unless you tightened the label policies.

Then on the remote Prometheus:

```yaml
scrape_configs:
  - job_name: molly
    honor_labels: true
    scrape_interval: 15s
    static_configs:
      - targets: ["my-mac.tailnet.example:9765"]
```

The `user` and `host` labels Molly adds keep several machines apart, and the
dashboards' `$user` and `$host` selectors pick between them.

To ship the local Prometheus' copy to Grafana Cloud or a home server, or to
watch several machines on one Fleet dashboard, see [REMOTE.md](REMOTE.md).

## Troubleshooting

- `molly status` shows the target `down`: Molly is not running, or Docker cannot reach the host. `docker compose logs prometheus` shows the scrape error.
- A collector shows unavailable in the menu bar: run `molly doctor` and check Full Disk Access for the process that started Molly.
- Port 9765 busy: `pkill -f 'molly run'`, or change `server.port` and the target in `deploy/prometheus/prometheus.yml`.
