# Claude Code hooks and the event endpoint

The `claude_code` collector tails session logs, which lags by up to its
interval. Hooks are instant: Claude Code runs `molly hook` on every tool call,
prompt and session boundary, and Molly counts it the moment it arrives.

## How it works

```
Claude Code ──hook stdin JSON──▶ molly hook ──POST /event──▶ Molly ──▶ /metrics
```

`molly hook` reads the hook payload from stdin, adds `"source": "claude_code"`,
posts it to `http://<server.bind>:<server.port>/event` with a 2 second
timeout, and always exits 0. A stopped Molly never blocks Claude Code.

Molly keeps only four things from a hook payload: `hook_event_name`,
`tool_name`, `session_id` (in memory, for the active-sessions gauge) and the
project name derived from `cwd`. Prompts, `tool_input`, `transcript_path` and
everything else are discarded.

## Setup

1. Make sure Molly is running (`swift run molly` or the launch agent).
2. Print the hook configuration and review it:

   ```sh
   molly hook snippet
   ```

3. Merge it into `~/.claude/settings.json`:

   ```sh
   molly hook install
   ```

   This backs the file up to `settings.json.molly-backup-<timestamp>`, keeps
   every existing hook, and is safe to run again. It refuses to touch a file
   that is not valid JSON. The command path it writes is the absolute path of
   the `molly` binary you ran, so run it from the installed binary
   (`/Applications/Molly.app/Contents/MacOS/molly hook install`), not from a
   `.build` folder you will delete.

4. Restart your Claude Code sessions. New sessions pick up the hooks.

Remove the hooks with `molly hook uninstall`. It removes exactly the groups it
added (any hook whose command ends in `molly hook`) and leaves yours alone.

## Metrics

| metric | type | labels | meaning |
|---|---|---|---|
| `molly_events_total` | counter | `source`, `event` | every accepted event |
| `molly_claude_hook_events_total` | counter | `event`, `tool`, `project` (policy `projects`) | hook events by name and tool |
| `molly_claude_hook_sessions_active` | gauge | | sessions seen within `activeWindowSeconds` without a `SessionEnd` |
| `molly_claude_hook_last_event_timestamp_seconds` | gauge | | unix time of the last hook event |

Hook activity also feeds the `projects` collector (`source="claude"`).

## Posting your own events

Any script can post to the same endpoint:

```sh
curl -X POST http://127.0.0.1:9765/event \
  -H 'Content-Type: application/json' \
  -d '{"source": "backup", "event": "finished", "value": 1}'
```

| field | required | meaning |
|---|---|---|
| `source` | yes (implied `claude_code` when `hook_event_name` is present) | who sent it |
| `event` | yes (or `hook_event_name`) | what happened |
| `value` | no, default 1 | amount to add to the counter, must be >= 0 |
| `labels` | no | may carry `tool_name`, `session_id`, `cwd` for Claude events |

Responses: `204` accepted, `400` bad JSON or missing fields, `401` wrong or
missing token, `413` body over 64 KiB, `503` the `events` collector is
disabled. Label values are trimmed to letters, digits and `_-.:/` and 64
characters.

## Config

```json
"events": {
  "enabled": true,
  "interval": 60,
  "activeWindowSeconds": 300,
  "token": "",
  "projects": {"enabled": true, "mode": "denylist", "patterns": [], "hash": false, "salt": "", "maxCardinality": 30}
}
```

`token`, when set, must be sent as `Authorization: Bearer <token>`.
`molly hook` reads it from the same config. The endpoint only listens on
`server.bind` (loopback by default), so the token matters only if you bind
to a LAN address.

## Shell hook

Shell history has no working directory, so the `projects` collector could
not see what you do in a terminal. The shell hook fixes that: a prompt hook
posts `{"source":"shell","event":"prompt","shell":"zsh","exit":0,"cwd":"..."}`
to `/event` after every command. Molly keeps only the project name derived
from `cwd` (`owner/repo` under `github.com`, else the last path component),
run through the `events.projects` policy, plus the shell name and whether the
last command failed.

```sh
molly shell-hook snippet                 # print the zsh block
molly shell-hook snippet --shell bash    # or fish
molly shell-hook install [--shell zsh]   # append the block to ~/.zshrc (backup first)
molly shell-hook uninstall               # remove exactly that block
```

The block is delimited by `# >>> molly shell hook >>>` and
`# <<< molly shell hook <<<`, so `install` is idempotent and `uninstall`
touches nothing else. It runs `curl` in the background with a 0.3 s timeout
and discards all output, so a stopped Molly never slows the prompt. Set
`MOLLY_SHELL_HOOK=0` in a shell to pause it there. Directories whose path
contains a double quote are skipped rather than mis-encoded. The snippet
bakes in `server.bind`, `server.port` and `events.token` from the config at
the time you run it; re-run `install` after changing them.

Metrics: `molly_shell_prompts_total{shell}`,
`molly_shell_last_exit_nonzero_total{shell}`, and
`molly_project_last_activity_timestamp_seconds{source="shell"}` via the
`projects` collector.
