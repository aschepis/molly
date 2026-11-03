# CLAUDE.md — Molly development harness

Molly is a macOS menu-bar app that observes how the machine is used (system
vitals, app focus, browsing, messaging, git, AI-agent usage, ...) and exposes
everything as Prometheus metrics on `http://127.0.0.1:9765/metrics`. A local
Docker Prometheus + Grafana stack (`deploy/`) stores and visualizes it.
Read `docs/ARCHITECTURE.md` for the design, `docs/METRICS.md` for the metric
catalog, `DECISIONS.md` for why things are the way they are.

## Stack (fixed)

- Swift 5 language mode, SwiftPM, `// swift-tools-version:5.10`, macOS 13+.
- **Zero external packages.** SQLite via system `import SQLite3`; UI via AppKit
  (`NSStatusItem`); HTTP via `Network.framework`; metrics via our own
  `MetricsRegistry` (text exposition format, ~200 lines).
- One executable, `molly`. Subcommands: `run` (menu-bar daemon + /metrics),
  `once`, `doctor`, `validate`, `config-path`, `version`. Subcommands other
  than `run` must never start `NSApplication`.

## Commands

```sh
swift build                      # debug build
swift test                       # unit tests
swift run molly                  # start the menu-bar daemon
swift run molly once             # run every collector once, print metrics text
swift run molly once --collector focus
swift run molly doctor           # permissions, ports, stack reachability
swift run molly validate         # parse config, list enabled collectors
make stack-up / stack-down       # local Prometheus + Grafana (Docker)
```

Kill a running daemon with `pkill -f 'molly run'` before relaunching.
Concurrent `swift build`s in the same checkout serialize on `.build`; use a
separate worktree per parallel task.

## Layout

```
Sources/Molly/
  main.swift            # arg routing only
  App/                  # AppDelegate (Runtime), StatusItemController (menu bar)
  Core/                 # Config, LabelPolicy (privacy), Metrics, Collector,
                        # CollectorManager, SQLiteSnapshot, StateStore, Shell, CocoaTime, Log
  Collectors/           # one file per collector + CollectorRegistry (wiring)
  Web/                  # HTTPServer, Routes (/metrics, /healthz, /collectors, /config)
  CLI/                  # once, validate, doctor
Tests/MollyTests/
config/molly.example.json   # every key, documented in docs/CONFIG.md
deploy/                     # docker-compose, prometheus.yml, grafana provisioning + dashboards
docs/
```

## Architecture rules

- **Metrics are the only output.** Collectors register gauges/counters on the
  shared `MetricsRegistry` in `start(registry:)` and update them in `collect()`
  (polled every `interval` seconds on the collector's own queue) or from
  AppKit/distributed notification observers (registered in `start`, which runs
  on the main thread). Metric names are `molly_<area>_<thing>_<unit>`; counters
  end in `_total`; label names are snake_case. `user` and `host` are const labels
  added by the registry, never by collectors.
- **A collector must never crash the app.** Catch your own errors; throw
  `CollectorUnavailable` when the source needs a permission or app the user
  lacks (logged once, not per run); any other error is logged each run and
  counted in `molly_collector_errors_total`.
- **Every potentially sensitive label dimension goes through a `LabelPolicy`**
  (domains, app names, bundle ids, repo names, project names, command names,
  window titles, SSIDs, contact-ish anything). Read it with
  `settings.filter("<key>", defaults:)`, call `filter.label(raw)` or
  `filter.labels(counts)` before publishing, and default sensitive dimensions
  to `enabled: false`. Aggregate counts without the label must still be
  published when the label is disabled. Respect `maxCardinality`.
- **Never read another app's SQLite file in place.** `SQLiteSnapshot.open`
  copies the db (+wal/+shm) to a temp folder and opens the copy read-only.
  Keep import cursors in `StateStore` so counters are incremental across
  restarts; never backfill history older than the cursor (or than process start
  on first run) into a counter.
- **Config is JSON** at `~/Library/Application Support/Molly/config.json`
  (`MOLLY_CONFIG` overrides). Each collector reads only its own section via
  `config.collector("<name>")` and `CollectorSettings` getters with defaults.
  Document every key you add in `docs/CONFIG.md` and `config/molly.example.json`.
- Polling intervals, thresholds and paths are named constants or config keys,
  never inline magic numbers.
- New collector = one file in `Collectors/`, one `add(...)` line in
  `CollectorRegistry.makeCollectors`, its name in `knownNames`, a test, a
  `docs/METRICS.md` entry, and a `config/molly.example.json` section.

## Conventions

- Prefer obvious code over clever code. Comments explain *why*, never *what*,
  two lines max; if a line needs a comment to be understood, restructure it.
- No force-unwraps outside tests. No `print` in the daemon; use `Log`.
- Tests: pure logic (parsers, cursor math, label mapping) gets unit tests
  against fixtures or temp SQLite files built in the test. Collectors that
  wrap live macOS APIs get a test that runs `collect()` and checks the metric
  families exist, skipping (`XCTSkip`) when the source is absent on the box.

## Gotchas

- Safari `History.db`, Messages `chat.db`, Notes, and `knowledgeC.db` need Full
  Disk Access for the *host process* (your terminal during development, the
  `molly` binary or `Molly.app` under launchd).
- Chrome-family history files are locked while the browser runs: copy first.
- Messages dates are nanoseconds since 2001; Safari visit_time is seconds since
  2001; Chrome is microseconds since 1601. Use `CocoaTime`.
- Sleep/wake come from `NSWorkspace.shared.notificationCenter`; screen
  lock/unlock from `DistributedNotificationCenter` (`com.apple.screenIsLocked`).
- `swift run` shows the status item without an app bundle because `run` sets
  `.accessory` activation policy and calls `app.run()`.
