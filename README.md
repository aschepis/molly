# Molly - Deep observability of your macOS usage

Molly is a macOS application that observes your usage of your macOS system in minute detail in order to provide you with insights into your habits, productivity, system performance, and more. It collects data on application usage, window focus, system events, memory, cpu, disk I/O, and other relevant metrics to help you understand how you interact with your computer. It specifically does not capture keystrokes or any sensitive personal information, ensuring your privacy while still providing valuable insights.

Molly publishes all collected data to a configurable Prometheus endpoint, allowing you to visualize and analyze your macOS usage data using tools like Grafana. This enables you to create custom dashboards and alerts based on your usage patterns. By default, Molly runs as a background service and uses a local, Docker-based Prometheus instance to store the collected data, but it can also be configured to send data to a remote Prometheus server if desired. In the local Prometheus instances all data is loaded from a local folder mounted as a volume, so you can easily backup or move your data to another machine.

Molly always labels the collected data with the current user and hostname, allowing you to differentiate between multiple users or machines if you are running Molly on more than one system. This makes it easy to analyze usage patterns across different environments.

## Status

Working MVP plus three feature loops. 28 collectors (system vitals, focus and
idle, processes, Docker, meetings, browsers, Messages, Notes, Calendar, Mail,
Screen Time, git, Claude Code, Cursor, Codex, shell, projects, Claude Code
hooks, input, clipboard, hardware, power, builds, tabs, media, window titles) plus an opt-in `health` collector fed by an iPhone Shortcut
(Apple Health: steps, sleep, heart rate, with a Body dashboard)
expose about 1,000 series; nine provisioned Grafana dashboards; 33
Prometheus recording and alert rules; `molly insights`, `molly mcp`,
`molly tune`, `molly privacy`, `molly export`. Every sensitive label
dimension is governed by an allowlist/denylist policy and the most sensitive
ones are off by default. See [docs/METRICS.md](docs/METRICS.md),
[docs/CONFIG.md](docs/CONFIG.md) and [docs/PRIVACY.md](docs/PRIVACY.md).

## Quick start

Requires macOS 13+, Swift 5.10 and Docker Desktop.

```sh
make stack-up                # Prometheus :9090 and Grafana :3030 (admin / admin)
swift run molly              # menu bar app, metrics on 127.0.0.1:9765
open http://localhost:3030   # Dashboards > Molly
make install                 # optional: build and copy Molly.app to /Applications
                             # then tick "Launch at Login" in the menu bar (or: molly install-agent)
```

Grant Full Disk Access to your terminal (or Molly.app) so the Safari, Messages,
Notes and Calendar collectors can read their databases; see
[Getting started](docs/GETTING-STARTED.md).

## Screenshots

_Screenshots of the Overview, Focus and Developer dashboards go here._

## Documentation

- [Getting started](docs/GETTING-STARTED.md): build, permissions, the stack, remote Prometheus
- [Dashboards](docs/DASHBOARDS.md): what each Grafana dashboard shows
- [Architecture](docs/ARCHITECTURE.md): collectors, registry, privacy policies, data flow
- [Metrics](docs/METRICS.md): every metric name, label and unit
- [Configuration](docs/CONFIG.md): every config key, label policies, example configs
- [Hooks](docs/HOOKS.md): live Claude Code events via `molly hook` and `POST /event`
- [Health](docs/HEALTH.md): opt-in Apple Health data from an iPhone Shortcut, a Body dashboard, and `molly health import` for history
- [MCP](docs/MCP.md): `molly mcp`, read-only query tools for Claude Code and other MCP clients
- [Privacy](docs/PRIVACY.md): every sensitive label dimension, its default, and `/privacy` for auditing
- [Insights](docs/INSIGHTS.md): `molly insights` writes a Claude narrative of your day with recommendations
- [Tuning](docs/TUNING.md): `molly tune` recommendations from registry size and collector health
- [Remote](docs/REMOTE.md): scraping from another machine, remote_write, fleets
- [Settings](docs/SETTINGS.md): the Settings window, presets, forget data and the retention knob
- [Signing](docs/SIGNING.md): why `make app` signs with your Developer ID and how that keeps Full Disk Access across rebuilds
- [Roadmap](docs/ROADMAP.md) and [Ideation log](docs/IDEATION-LOG.md): what could come next and what the three loops built
- [Decisions](DECISIONS.md): why things are the way they are
- [Questions](QUESTIONS.md): things only you can answer, with the defaults taken meanwhile

## License

MIT, see [LICENSE](LICENSE).
