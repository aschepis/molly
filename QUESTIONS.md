# Questions for Adam

Things I could not resolve on my own. Each has the default I took so work
could continue; change the default and the code will follow.

## Claude pricing table
`collectors.claude_code.pricing` ships built-in per-million-token prices for
opus/sonnet/haiku rows that are plausible list prices. The guessed
`claude-fable` row (15/75) is gone: a model with no row now costs 0 and logs
one warning naming the model, so a wrong price can no longer pass as data.
New `collectors.claude_code.pricing.mode` is `list` (default) or `subscription`.
Under `subscription` the series keeps its name but the dashboards and digest
call it a list-price equivalent and `HighClaudeSpend` stays silent.
Still open: set `mode` to `subscription` if that is how you pay, and add a row
for the fable model once you have its list price.

## Codex session format
No `~/.codex/sessions` on this machine, so the `codex` collector's parser was
written from recollection of the rollout JSONL format and tested only on
fixtures. Default: collector reports unavailable until the folder exists.
If you use Codex elsewhere, a sample file would let me verify it.

## Messages and Mail defaults
`messages` is on by default (counts only, per service and direction, never
content or contacts). `mail` is off by default. mac-timeline shipped
communication volume off; I kept messages on because you listed "messages
sent" as a must-have. Say if you want it off.

## Full Disk Access for the daemon
The terminal already has it, so `swift run` works. The launch agent runs the
built binary or Molly.app, which needs its own grant in System Settings >
Privacy & Security > Full Disk Access. `molly doctor` tells you which sources
are unreadable. Default: nothing installed; `make install` then
`molly install-agent` when you are ready.

## Wi-Fi SSID needs Location Services
macOS only reveals the SSID to processes with Location permission. Default:
`system.wifi` policy disabled; `molly_network_wifi_connected` still reports.

## Browser tab counts need Automation permission
The `tabs` collector (loop 1) asks Safari/Chrome via AppleScript, which
prompts once per browser. Default: disabled.

## Input intensity needs Accessibility
The `input` collector (loop 1) counts key/click events (never keycodes) via a
listen-only event tap. Default: disabled.

## Hooks into ~/.claude/settings.json
`molly hook install` (loop 1) merges hook entries into your Claude Code
settings with a backup. I did not run it on this machine. Default: not
installed; `molly hook snippet` prints what it would add.

## Unknown config keys are ignored silently
`molly validate` warns about unknown collector sections but not unknown keys
inside a section (each collector reads its keys dynamically). A typo like
`intervl` is ignored. Fixing this needs a per-collector key manifest; on the
roadmap, not done.

## Screen Recording for window titles
The `titles` collector (loop 3) needs Screen Recording for the molly
binary/Molly.app and hashes titles by default. Default: collector off.

## Automation prompts for media (Music/Spotify)
The `media` collector asks each player via AppleScript, one prompt per app.
Default: collector off.

## Insights backend and budget
`molly insights` uses `ANTHROPIC_API_KEY` if set, else the `claude` CLI on
your subscription. The scheduled daily run (`collectors.insights`) is off by
default; I generated exactly one real report during development, into a
scratch folder. Default: off; `molly insights --digest-only` is free.

## Prometheus admin API is now on
Needed for `molly export` snapshots and `molly prune`. Fine on localhost;
if you ever expose 9090, turn it off or put auth in front.

## Shell hook install
`molly shell-hook install` appends a block to your rc file with a backup. Not
run on this machine. Default: `molly shell-hook snippet` to inspect first.

## Full Disk Access does not survive rebuilds (resolved 2026-11-03)

Ad-hoc signing pinned the Full Disk Access grant to each build's content
hash, so every `make install` silently revoked it. `make app` now signs with
the "Developer ID Application" certificate in your keychain (hardened runtime,
timestamp, `packaging/Molly.entitlements`), falling back to ad-hoc with a
warning when no identity matches. See docs/SIGNING.md.

Still yours to decide: whether to notarize (`make notarize` needs a
`notary-profile` keychain entry, which does not exist yet) before giving the
app to another Mac.
