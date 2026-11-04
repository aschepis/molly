# Insights: a narrative for your day

`molly insights` turns one day (or week) of Molly's Prometheus history into a
short report: a narrative, three recommendations tied to numbers, and one
pattern to watch. Claude writes the prose; Molly builds the numbers.

## How it works

1. **Digest.** Molly queries Prometheus for the window (local midnight to
   midnight, or to now for today; Monday to Monday for a week): active and
   idle hours, flow minutes, focus switches, top apps, meetings, calendar
   hours, commits per repo, lines changed, builds, Claude Code sessions,
   messages, tool calls, tokens and estimated cost, shell commands, messages
   sent and received, browser visits and distinct domains, notifications,
   notes, clipboard copies, docked share, CPU, memory pressure, battery, and
   Molly's own errors. The query list is `DigestQueries.all` in
   `Sources/Molly/Insights/Digest.swift`.
2. **Narrative.** The digest is rendered as compact Markdown and sent to Claude
   with a fixed prompt. The reply must have three sections: Narrative,
   Recommendations, Pattern to watch.
3. **Report.** The result is written to
   `~/Library/Application Support/Molly/insights/YYYY-MM-DD.md` (or
   `YYYY-MM-DD-week.md`, named by the week's Monday) with the digest appended
   in a collapsed details block. Reports are cached: a second run returns the
   file unless you pass `--force`.

## Commands

```sh
molly insights                        # today, written and printed
molly insights --day 2026-11-02       # a past day
molly insights --week                 # the current week (Monday to now)
molly insights --week --day 2026-10-28  # the week containing that date
molly insights --digest-only          # numbers only, no Claude call, nothing written
molly insights --force                # regenerate even if the file exists
molly insights --backend cli          # force the claude CLI (or api)
```

`--digest-only` is the way to check what would be sent before you spend
anything.

## Backends

| backend | when | cost |
|---|---|---|
| `api` | `ANTHROPIC_API_KEY` is set, or `collectors.insights.apiKey` is set | billed to the key; `model` defaults to `claude-sonnet-5-5`, about a cent per report |
| `cli` | the `claude` CLI is installed (PATH, `~/.local/bin`, `~/.claude/local`) | billed to your Claude subscription; uses the CLI's default model |

`backend: "auto"` (the default) prefers the API key and falls back to the CLI.
With neither, `molly insights` fails with a clear message and nothing is sent.

## Automatic reports

Enable the `insights` collector to have the daemon write today's report once
local time passes `dailyAtHour` (default 21) and, on Mondays, last week's
report. It is **off by default** because every report costs money or
subscription budget.

```json
"insights": {
  "enabled": true,
  "interval": 300,
  "dailyAtHour": 21,
  "weekly": true,
  "model": "claude-sonnet-5-5",
  "apiKey": "",
  "backend": "auto",
  "prometheusURL": "http://localhost:9090"
}
```

Metrics: `molly_insights_last_generated_timestamp_seconds` and
`molly_insights_generations_total{kind,status}` (status `ok`, `cached`,
`error`).

## Reading reports

- `GET http://127.0.0.1:9765/insights/latest` returns the newest daily report;
  `/insights/2026-11-03` and `/insights/2026-11-02-week` return a specific one.
  The Overview dashboard links there.
- Four formats. A suffix wins: `.html`, `.md`, `.json`, `.yaml` (or `.yml`).
  Without one the `Accept` header decides (`text/html`, `text/markdown`,
  `application/json`, `application/yaml`; highest q wins, ties go in that
  order). No header, `*/*` or anything unparseable gives HTML, so a browser
  just shows the report. An `Accept` that lists only types Molly does not
  serve gets `406`. Responses carry `Vary: Accept`.
- JSON and YAML have `kind`, `date`, `generated`, `markdown` and `digest`.
  The digest is the numbers the narrative was written from, saved beside the
  report as `<date>.json` / `<date>-week.json`; reports written before that
  have `digest: null`.
- The files are plain Markdown (plus the digest JSON) in the data folder;
  keep, grep or delete them freely. `molly insights` still prints Markdown.

## Privacy

Only the digest leaves the machine, and only when a backend is configured.
The digest is built from Prometheus, so every label policy has already been
applied: a domain you denylisted shows up as `redacted` or not at all, apps
you hid are `other`. Raw sources (history databases, chat logs, shell
history) are never read by this feature. The `apiKey` is redacted in
`/config`.

Prices in the "estimated cost" line come from the `claude_code` collector's
price table, which is an estimate (see `docs/CONFIG.md`).
