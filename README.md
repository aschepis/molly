# Molly - Deep observability of your macOS usage

Molly is a macOS application that observes your usage of your macOS system in minute detail in order to provide you with insights into your habits, productivity, system performance, and more. It collects data on application usage, window focus, system events, memory, cpu, disk I/O, and other relevant metrics to help you understand how you interact with your computer. It specifically does not capture keystrokes or any sensitive personal information, ensuring your privacy while still providing valuable insights.

Molly publishes all collected data to a configurable Prometheus endpoint, allowing you to visualize and analyze your macOS usage data using tools like Grafana. This enables you to create custom dashboards and alerts based on your usage patterns. By default, Molly runs as a background service and uses a local, Docker-based Prometheus instance to store the collected data, but it can also be configured to send data to a remote Prometheus server if desired. In the local Prometheus instances all data is loaded from a local folder mounted as a volume, so you can easily backup or move your data to another machine.

Molly always labels the collected data with the current user and hostname, allowing you to differentiate between multiple users or machines if you are running Molly on more than one system. This makes it easy to analyze usage patterns across different environments.

## Status

Early development. The Swift skeleton, metrics registry, privacy policies, menu bar app, deployment stack, six Grafana dashboards and launchd integration are in place; all collectors are implemented; see [docs/METRICS.md](docs/METRICS.md) and [docs/CONFIG.md](docs/CONFIG.md).

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
- [MCP](docs/MCP.md): `molly mcp`, read-only query tools for Claude Code and other MCP clients
- [Privacy](docs/PRIVACY.md): every sensitive label dimension, its default, and `/privacy` for auditing
- [Insights](docs/INSIGHTS.md): `molly insights` writes a Claude narrative of your day with recommendations
- [Decisions](DECISIONS.md): why things are the way they are
