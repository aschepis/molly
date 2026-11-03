# Dashboards

Nine dashboards are provisioned into the Grafana folder "Molly" from
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
a metric name that is not in `docs/METRICS.md`, or a recording rule that
`deploy/prometheus/rules/molly.yml` does not define.

Overview, Focus and Week carry three annotation streams: commits (tagged by
repo, from `molly_git_last_commit_timestamp_seconds` changing), meetings
(while `molly_meeting_active` is 1) and screen locked. Toggle them at the top
of the dashboard.

## Derived series (recording rules)

`deploy/prometheus/rules/molly.yml` computes a few things Molly cannot know
from a single scrape. The dashboards below use them.

| rule | meaning |
|---|---|
| `molly:switch_rate:5m` | app switches per minute, rolling 5 minutes |
| `molly:active_ratio:5m` | share of the last 5 minutes the user was active |
| `molly:flow_state:5m` | 2 flow (active 80%+, at most 1.5 switches/min), 1 shallow (active 50%+), 0 break |
| `molly:flow_minutes:increase1h`, `:increase1d` | minutes classified as flow in the window |
| `molly:interruptions:increase1h` | app switches per hour above a baseline of 10; an approximation of context-switch cost |
| `molly:claude_cost_per_commit:1d`, `molly:claude_tokens_per_commit:1d` | estimated Claude spend and tokens per commit of yours, trailing 24h |
| `molly:claude_tool_calls:rate1h` | tool calls in the last hour |
| `molly:active_hours:1d`, `molly:meeting_hours:1d` | trailing 24h totals |
| `molly:focus_top_app_seconds:1d` | top 5 apps by focus time, trailing 24h |
| `molly:health_sleep_minutes:last_night` | minutes asleep last night, from the health collector |
| `molly:active_unbroken_hours:1d` | hours in the last day with no 5 minute idle gap; stands in for "longest sedentary stretch", which Molly cannot see without per-minute steps |

The flow thresholds are a starting point. Change them in the rules file, run
`curl -X POST localhost:9090/-/reload`, and every panel follows.

## Alerts

The same rules file defines informational alerts (`severity: info`). Nothing
pages; they appear in Health > Alerts (a table of what is firing and a
timeline of when each fired) and as the "Anomalies firing" tile on Overview.
Prometheus exposes them as the built-in `ALERTS` series, which carries no
user/host labels.

| alert | fires when | what it means |
|---|---|---|
| `MollyDown` | the molly target has been down for 5 minutes | the menu bar app is not running or not reachable; `molly status` |
| `LongSessionNoBreak` | `molly_user_active` stayed 1 for 2 hours | no 5 minute idle gap; take a break |
| `NoBreakFourHours` | the same for 4 hours | |
| `NotStandingEnough` | active 90 minutes while neither stand hours nor steps changed, and the phone posted in that window | stand up; only fires with the health collector on |
| `HighMemoryPressure` | pressure level 2 or more for 10 minutes | macOS is compressing memory |
| `MemoryPressureCritical` | pressure level 4 for 5 minutes | expect swapping and stalls |
| `BatteryLow` | under 15% and not on AC | |
| `SwitchRateSpike` | 15 minutes of switching at twice your 7 day median, while active | an unusually fragmented stretch |
| `ActiveDayNoCommits` | 6+ active hours and no commit of yours today, weekday evening (UTC hour 22+) | a day that did not land in git; edit the hour for your timezone |
| `HighClaudeSpend` | estimated Claude spend in 24h above `molly:claude_spend_threshold_usd` (50) | change the threshold in the rules file |
| `MeetingMarathon` | microphone or camera in use for more than 4 hours in 24h | |
| `DiskAlmostFull` | less than 10% free on the data volume for 10 minutes | |
| `CollectorFailing` | more than 5 errors from one collector in 30 minutes (codex excluded) | `molly doctor`; usually a permission |
| `ScrapeLarge` | more than 5000 samples per scrape for 10 minutes | a label policy's `maxCardinality` is too generous; see `/privacy` |

Alerts that need a baseline (`SwitchRateSpike`) stay silent until the stack
has about a week of data.

## Overview (`molly-overview`)

Purpose: the one-screen answer to "how was today".

Panels: active share of today, focused app now, tiles for active hours, focus
switches, commits, Claude tokens, messages sent, browser visits, meeting
minutes and estimated Claude cost; a focused-app state timeline; an
active/idle timeline; CPU and memory trends; an Insights row linking to the
latest Claude-written report at `http://127.0.0.1:9765/insights/latest`
(Grafana text panels cannot embed it; see [INSIGHTS.md](INSIGHTS.md)).

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
switches per hour; a Flow row (flow state timeline in 5 minute buckets, flow
minutes today, app switches per minute, interruptions per hour); active/idle,
locked/asleep/screensaver and meeting timelines; running apps, windows on
screen, idle seconds, app launches.

Look for: the gap between Molly and knowledgeC (time Molly was not running),
switch spikes that precede low-output hours, long grey stretches in the flow
timeline during what should have been work, and meetings stacked back to back.

## Developer (`molly-developer`)

Purpose: code and AI-agent activity.

Panels: commits per repo over time, lines added and removed today, per-repo
table of dirty, untracked, ahead, behind and stashes with last commit; active
projects timeline; Claude sessions, tool calls, tokens by kind and model,
estimated cost, prompts and messages per hour; an Agent ROI row (estimated
cost per commit, tokens per commit, tool calls per hour, all trailing 24h);
Cursor events, Codex tokens, agent processes; shell commands per hour and
command names.

Look for: repos that are ahead and never pushed, dirty files left for days,
cost per day trending up, cache reads versus fresh input tokens, and cost per
commit climbing while commits stay flat.

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
per collector; a status table with enabled flag, age of last success, totals;
an Alerts row with every firing alert (and how long it has been active) and a
timeline of alert history (see [Alerts](#alerts)).

Look for: a collector whose last-success age is far beyond its interval
(failing or missing permission), error counts that keep rising, and scrape
duration approaching the 15 second scrape interval.

## Body (`molly-body`)

Purpose: set Apple Health numbers against how you worked. Needs the `health`
collector ([HEALTH.md](HEALTH.md)); every panel is empty until the iPhone
Shortcut has posted. Default range is 14 days.

Panels: today tiles (steps, stand hours, exercise, active energy, resting HR,
HRV, sleep last night, bedtime); sleep vs flow hours and vs app switching;
bedtime; stand hours vs unbroken active hours; steps vs active hours; exercise
vs commits; daylight; resting HR vs meeting hours and HRV vs interruptions
(seven day rolling); a grid of the remaining types; and a pipeline row (age of
the last post, samples accepted and rejected).

Daily series work with live and imported data: each is
`molly_health_yesterday offset -1d or molly_health_today or
last_over_time(molly_health_day[1d] offset -12h)`, so a day shows its final
total once it is over, the running total while it is in progress, and the
`molly health import` value for history with no live data. Where Molly has no
counterpart series the health series stands alone and the panel description
says so: bedtime (no late-night work or gaming rule) and daylight (no
afternoon-focus rule). Work-side series (flow, active hours, commits) are the
trailing 24 hours, so they line up with a calendar day only at its end.

Look for: short nights followed by low flow or fast switching, a resting heart
rate that climbs through a meeting-heavy week, and days with many active hours
and few steps.

## Week (`molly-week`)

Purpose: the seven-day review.

Panels: week-over-week tiles for active hours, flow hours, commits, Claude
cost, messages sent and meeting hours (each with the previous seven days in
grey beside it); day-by-day bars for the same measures (each bar is the
trailing 24 hours, so read the value at midnight for a calendar day); top apps
and top repos this week; the flow state timeline across the week.

Look for: a week whose active hours rose while flow hours fell (busier, less
focused), cost that grew faster than commits, and which day of the week the
meetings land on.

## Fleet (`molly-fleet`)

Purpose: several machines reporting to one Prometheus, compared side by side.
See [REMOTE.md](REMOTE.md) for the scrape and remote_write setups that feed it.

Panels: a hosts table (Molly up, version, active now, focused app, battery,
CPU, memory pressure, collectors failing, uptime) keyed by the `user` and
`host` labels Molly puts on every series; per-host bars for active hours,
commits and Claude cost over the trailing 24 hours; scrape duration per
target; up and user-active timelines per host.

Look for: a host whose Molly is up but whose collectors are failing (usually
Full Disk Access missing on that machine), and a machine that is active but
produces no commits (it is the meeting laptop).
