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

Port 3000 on this machine is used by a Rails app (Damocles). The local stack
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
