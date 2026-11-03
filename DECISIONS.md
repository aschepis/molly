# Decisions

A log of choices made while building Molly that you should know about.
Newest at the bottom. Open questions for you live in `QUESTIONS.md`.

## 2026-11-02 Swift, not Go

I started a Go exporter (canonical Prometheus client, gopsutil, fast tests).
You pointed at mac-timeline and said the menu bar icon matters. Switched to
Swift/SwiftPM with zero dependencies, mirroring mac-timeline's conventions:
native NSWorkspace/DistributedNotificationCenter collectors are event-driven
instead of polled, the status item is trivial, and TCC permissions attach to a
real binary/app bundle. Cost: hand-rolled Prometheus text exposition and
system-metrics code (host_statistics, sysctl, IOKit) instead of libraries.

## 2026-11-02 JSON config, not YAML

Zero-dependency Swift has no YAML parser. JSON via Foundation is robust and
`config/molly.example.json` plus `docs/CONFIG.md` carry the documentation that
YAML comments would have. Collector sections are kept as raw JSON so adding a
collector never touches the shared `Config` type.

## 2026-11-02 Privacy model: per-dimension label policies

Every sensitive label dimension (domains, app names, repo names, command
names, ...) is governed by a `LabelPolicy` with `enabled`, `mode`
(allowlist/denylist), glob `patterns`, optional `hash` + `salt`, and
`maxCardinality`. Sensitive dimensions default to `enabled: false`; the
aggregate metric without the label is always published. Allowlist misses map
to `other`, denylist hits map to `redacted`, so totals stay truthful. Patterns
without a wildcard also match as dotted suffixes (`bank.com` covers
`online.bank.com`).

## 2026-11-02 Grafana on port 3030

Port 3000 on this machine is already taken by another local service. The local stack
uses 3030 for Grafana and 9090 for Prometheus; Molly serves on 9765.

## 2026-11-02 Metrics bind to 127.0.0.1; Prometheus reaches it via host.docker.internal

Default bind is loopback. Docker Desktop routes `host.docker.internal` to the
host's loopback, so the containerized Prometheus can scrape without exposing
the endpoint on the LAN. `server.bind` is configurable for remote scraping.

## 2026-11-02 Counters are incremental from a persisted cursor, no backfill

History-style sources (browser visits, messages, commits) are read as "rows
newer than the cursor". First run starts the cursor at process start so a
fresh install does not dump years of history into a counter. Cursors persist
in `~/Library/Application Support/Molly/state/<collector>.json` so a restart
does not double count or lose the gap. Where a "today so far" number is cheap
to compute from the source, it is also published as a gauge (`*_today`)
because it survives restarts and reads naturally on a dashboard.

## 2026-11-02 Proceeded without the usual "explain then wait" step

Your global CLAUDE.md asks me to describe existing code and wait before
editing. The repo had only a README and the goal was set as an autonomous
session, so I proceeded; this file is the substitute for that conversation.

## 2026-11-03 Self-process metrics renamed to `molly_self_*`

The plan used `molly_process_resident_memory_bytes` both for Molly's own RSS
and for the top-N per-process gauge. The registry refuses one name with two
label sets, so the self metrics became `molly_self_resident_memory_bytes`,
`molly_self_cpu_seconds_total`, `molly_self_threads`.

## 2026-11-03 `remote_host`, not `host`, for shell network hosts

`host` is a const label on every series, so the shell collector's network
host dimension is `remote_host`. It is disabled by default like every
sensitive dimension.

## 2026-11-03 `molly once` never advances cursors

`once` runs beside the daemon for debugging. If it saved cursors it would
consume history deltas the daemon should count, so `StateStore` persistence
is switched off in that command. Counters printed by `once` are therefore
mostly zero; use the `*_today` gauges or the daemon for real numbers.

## 2026-11-03 Four parallel agents built the collectors in git worktrees

Groups: A (system, processes, focus, docker, meeting), B (browser, messages,
notes, knowledge, calendar, mail), C (git, claude_code, cursor, codex, shell,
projects), D (Docker stack, dashboards, packaging, docs). Their per-group
notes are in `docs/collectors/`. Known gaps they reported: Codex session
format is unverified (no Codex on this machine), Orion's history schema is
assumed to match Safari, Brave/Arc were installed but had no History file,
and the shell gives the `projects` collector no signal because shell history
has no working directory.

## 2026-11-03 Ideation loops ran as forks, not fresh subagents

For loop 1 I first used fresh subagents; three of them (on a different
model) refused to edit without your in-person confirmation of the global
"explain then wait" rule and could not be unblocked by me. Those tasks and
all later loop work ran as forks of this session, which carry your original
goal message. Both kinds committed on their own branches in git worktrees
and were merged by hand; conflicts were only ever "both sides appended".

## 2026-11-03 Dashboards are generated, never hand-edited

`scripts/generate-dashboards.py` is the source of truth for all eight
dashboards; `make check-dashboards` verifies every metric name against
`docs/METRICS.md`. Hand edits to the JSON are overwritten on the next run.

## 2026-11-03 Prometheus admin API is enabled on the local stack

`molly export` takes TSDB snapshots and `molly prune` deletes series, both
of which need `--web.enable-admin-api`. The stack binds 9090 on localhost
only; do not publish it beyond the machine with that flag on (REMOTE.md).

## 2026-11-03 Window titles and media tracks hash by default

These are the leakiest labels Molly can hold, so their policies ship with
`hash: true` even once you opt the collector in. Plain text needs an explicit
`"hash": false`.

## 2026-11-03 `messages` on by default, `mail` off

Counts only, never content or contacts. You listed messages sent as a
must-have; Mail stayed off because its schema is inferred and less tested.

## 2026-11-03 Bind failure exits the process so launchd restarts it

A launchd-started Molly that lost the port race to a stale instance used to
keep running with no listener, so `/healthz` answered from the wrong process
and nobody noticed. `run` now treats a listener failure as fatal
(`Runtime.listenerFailure`, injectable for tests); `KeepAlive` brings it back
once the port is free, throttled by launchd's default interval.

## 2026-11-03 Settings window writes sorted JSON and never touches Prometheus

The Settings window edits the config through `ConfigDocument`, which keeps the
file as a `JSONValue` tree so keys it does not know about survive a save.
`JSONValue.object` is an unordered dictionary, so the writer sorts keys: a
stable order makes the timestamped backups (`config.json.bak-*`, ten kept)
diffable, at the cost of losing whatever order a hand-edited file had.
Comments were never possible in JSON, so nothing else is lost.

"Forget data" only deletes a collector's cursor file under `state/`. Deleting
the matching series from Prometheus needs the admin API and a metric-prefix
match that `molly prune` does not have yet; doing it silently would also
surprise anyone keeping long history on purpose. The tab says so and points
to `molly prune`.
