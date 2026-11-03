# Questions for Adam

Things I could not resolve on my own. Each has the default I took so work
could continue; change the default and the code will follow.

## Claude pricing table
`collectors.claude_code.pricing` ships built-in per-million-token prices for
opus/sonnet/haiku rows that are plausible list prices and a `claude-fable`
row that is a guess (15 in / 75 out / 1.5 cache read / 18.75 cache write).
`molly_claude_estimated_cost_usd_total` is only as good as this table.
Default: documented as an estimate; override in config.

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

## Full Disk Access does not survive rebuilds (ad-hoc signature)

`make app` signs with `codesign --sign -`. An ad-hoc signature has no stable
identity, so macOS ties the Full Disk Access grant to the binary's CDHash.
Every `make install` produces a new CDHash and the grant silently stops
applying: Molly.app still shows as enabled in System Settings, but the
launchd daemon logs "not readable (missing file or Full Disk Access)" for
Messages, Notes, Calendar, knowledgeC and Safari history. Toggling the entry
off and on (or removing and re-adding the app) restores it.

Options only you can pick:
1. Sign with your Apple Development / Developer ID certificate
   (`CODESIGN_IDENTITY=... make app`) so the identity is stable across builds.
2. Create a self-signed code-signing certificate in Keychain Access and use it
   the same way. Free, no Apple account needed.
3. Keep ad-hoc signing and re-toggle Full Disk Access after each install.

Observed 2026-11-03: after `make install` + `launchctl kickstart`, the four
collectors stayed unavailable from the daemon while `molly doctor` run from
a terminal with Full Disk Access reported everything readable.
