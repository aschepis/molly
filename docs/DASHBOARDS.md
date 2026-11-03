# Dashboards

Six dashboards are provisioned into the Grafana folder "Molly" from
`deploy/grafana/dashboards/`. All use the `molly-prometheus` datasource, refresh
every 30 seconds, default to the last 24 hours, and carry `$user` and `$host`
selectors (multi-select, default All) that filter every Molly query.
Panels built on built-in Prometheus series (`up`, `scrape_duration_seconds`)
cannot be filtered by user/host because those series do not carry the labels.

"Today" tiles come from `*_today` gauges where Molly publishes them, and from
counter `increase()` over the day so far (panel time override `now/d`) where it
does not. "Per hour" panels use a rolling one-hour `increase()`.

Panels for optional collectors (docker stats, shell command names, browser
domains, mail, codex, cursor) stay empty until you enable them; the panel
description says which setting.

Run `make check-dashboards` after editing: it fails if a dashboard or rule uses
a metric name that is not in `docs/METRICS.md`.

## Overview (`molly-overview`)

Purpose: the one-screen answer to "how was today".

Panels: active share of today, focused app now, tiles for active hours, focus
switches, commits, Claude tokens, messages sent, browser visits, meeting
minutes and estimated Claude cost; a focused-app state timeline; an
active/idle timeline; CPU and memory trends.

Look for: a long unbroken active bar with many focus switches (fragmented
attention), tiles that are zero when they should not be (a collector lost its
permission), and memory creeping up over the day.

## System (`molly-system`)

Purpose: machine health.

Panels: CPU total, per core and load average; memory by state, memory pressure
and swap; disk space per mount, disk throughput and operations; network
receive, transmit and errors per interface; VPN, Wi-Fi, displays, uptime;
battery charge, power source, thermal state, battery health and cycles; top
processes by CPU and memory; Docker container counts, CPU, memory and inventory.

Look for: pressure turning yellow or red together with swap growth, one core
pinned while the total is low, a mount over 90 percent, and thermal state above
nominal while on battery.

## Focus (`molly-focus`)

Purpose: where attention goes.

Panels: focus time by app over the selected range; the same from the system's
knowledgeC log; focused-app timeline; Molly vs knowledgeC hours; focus
switches per hour; active/idle, locked/asleep/screensaver and meeting
timelines; running apps, windows on screen, idle seconds, app launches.

Look for: the gap between Molly and knowledgeC (time Molly was not running),
switch spikes that precede low-output hours, and meetings stacked back to back.

## Developer (`molly-developer`)

Purpose: code and AI-agent activity.

Panels: commits per repo over time, lines added and removed today, per-repo
table of dirty, untracked, ahead, behind and stashes with last commit; active
projects timeline; Claude sessions, tool calls, tokens by kind and model,
estimated cost, prompts and messages per hour; Cursor events, Codex tokens,
agent processes; shell commands per hour and command names.

Look for: repos that are ahead and never pushed, dirty files left for days,
cost per day trending up, and cache reads versus fresh input tokens.

## Communication (`molly-communication`)

Purpose: messaging, browsing, notifications and schedule.

Panels: messages sent, received, unread and active chats, messages per hour per
service and direction; browser visits per hour per browser, distinct domains,
visits today, and a domain table (needs the `domains` policy); notifications,
notes created and modified; calendar events today, in-event state, next event,
event time today and remaining; mail unread and volume when the mail collector
is enabled.

Look for: unread piling up, notification storms, and days with no calendar
buffer.

## Health (`molly-health`)

Purpose: is Molly itself working.

Panels: Molly up, Prometheus target state, paused, version, uptime, threads;
scrape duration, Molly's memory and CPU; collector runs, errors and duration
per collector; a status table with enabled flag, age of last success, totals.

Look for: a collector whose last-success age is far beyond its interval
(failing or missing permission), error counts that keep rising, and scrape
duration approaching the 15 second scrape interval.
