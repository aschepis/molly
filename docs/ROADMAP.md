# Roadmap and ideation backlog

The MVP (collectors in `docs/METRICS.md`, the local stack, six
dashboards) is the foundation. This file is the menu of what Molly could
become, grouped by theme and tagged by effort: **S** (hours), **M** (a day or
two), **L** (a week). The ideation loops in `docs/IDEATION-LOG.md` pick from
here and record what was built.

## 1. Agents that look at the data

**Daily insight report (M).** `molly insights [--day YYYY-MM-DD]` queries
Prometheus over HTTP for the day's series (active time, focus by app,
switches, commits, agent tokens/cost, messages, meetings, vitals), builds a
compact JSON digest, and asks Claude (API key, else the `claude` CLI, like
mac-timeline's narrative backend) for a short narrative plus three concrete
recommendations. Output is Markdown written to the data folder and a
`molly_insights_last_generated_timestamp_seconds` gauge. No raw labels that a
policy disabled ever reach the model: the digest is built from the same
filtered metrics.

**Weekly review (S after the above).** Same pipeline over 7 days, with
week-over-week deltas, rendered as a Grafana text panel via a tiny
`/insights/latest` endpoint on Molly.

**Molly as an MCP server (M).** `molly mcp` exposes read-only tools
(`query_metrics(promql, range)`, `day_summary(date)`, `current_context()`)
so any agent can ask "what was I doing at 3pm" or "how much Claude budget did I
burn this week". Mirrors mac-timeline's MCP server but backed by Prometheus.

**Anomaly notes (M).** A rules-based pass (no LLM) that flags unusual days:
switch rate 2x the 30-day median, zero commits on a weekday with 6h active,
memory pressure critical > 10 min, a 4h stretch with no idle gap. Emitted as
`molly_anomaly{kind}` gauges so Grafana can annotate.

**Self-tuning recommendations (L).** An agent that reads `/collectors`,
collector error rates and scrape sizes, and proposes config changes
(disable a noisy label, raise an interval, add a denylist pattern it saw
leaking through `other`). Writes a proposed `config.json` diff, never applies.

## 2. New data sources

**Claude Code hooks → live events (S).** A `molly hook` subcommand reads the
hook JSON on stdin and POSTs it to `http://127.0.0.1:9765/event`. Molly turns
PreToolUse/PostToolUse/Stop/SessionStart into counters with zero log parsing
lag: `molly_claude_hook_events_total{event,tool}`. Documented
`~/.claude/settings.json` snippet.

**Window titles (opt-in, M).** Requires Screen Recording permission. Policy
`titles` with hashing recommended; converts "Chrome 51 min" into "Chrome —
GitHub PR". Highest-leak field, own retention knob.

**Input intensity (opt-in, M).** CGEventTap counting key/click events per
minute, never keycodes. Requires Accessibility. `molly_input_events_total{kind}`.

**Clipboard rhythm (S).** `NSPasteboard.changeCount` polling: copies per hour
and content type, never content.

**Xcode / build activity (M).** DerivedData `.xcactivitylog` arrivals,
`swift build`/`xcodebuild`/`cargo`/`go build` processes from the process
sampler, durations and pass/fail where cheap.

**Connected hardware (S).** External displays, keyboards, headphones, USB
drives via IOKit matching notifications. "Docked at desk" vs "couch".

**Reminders / Things / OmniFocus counts (S each).** Open/completed per day
from their local databases, counts only.

**Mail (done as default-off).** Received/sent/unread.

**Spotify / Music now playing (M).** AppleScript per app, one Automation prompt
each; track labels behind a policy.

**Sleep & boot forensics (S).** `pmset -g log` and `last reboot` parsed at
startup into counters so gaps while Molly was off are explainable.

**Network context (S).** Reachability, interface type, VPN, SSID (done where
permission allows).

**Terminal cwd / project attribution (M).** A one-line zsh `precmd` hook the
app offers to install that writes `cwd` + timestamp to a socket, giving the
`projects` collector a shell signal.

**Browser tabs open (S).** AppleScript count of windows/tabs for Safari and
Chrome; needs one Automation prompt per browser.

## 3. Analysis inside Prometheus/Grafana

**Flow detection (M).** Recording rules classifying 5-minute buckets as
flow / shallow / break from switch rate and active ratio; a state timeline
panel and a "flow hours today" tile.

**Context-switch cost ledger (S).** Switches that return within 2 minutes
count as interruptions; rule `molly:interruptions:increase1h`.

**Agent ROI (S).** Commits and lines per Claude dollar; tokens per commit.

**Annotations (S).** Grafana annotations from Prometheus alerts for commits,
meetings, and session starts.

**Weekly review dashboard (S).** 7-day comparison tiles, best day, worst day.

## 4. Product and operations

**Launch at login via SMAppService (S)** when running from Molly.app.

**Notarized app bundle and `brew install --cask` (M).**

**Remote write (S).** `prometheus.yml` snippet plus docs for Grafana Cloud or
a home server; Molly itself stays pull-only.

**Retention and export (S).** `molly export --range` dumping Prometheus
snapshots; `molly prune`.

**Multi-machine (S).** Already labeled by host; a dashboard variable and a
"fleet" overview.

**Audit view (M).** A `/privacy` endpoint listing every label dimension, its
policy, and the last values that mapped to `other`/`redacted`, so the user
can see exactly what leaves the box.
