# Group C collectors: git, claude_code, cursor, codex, shell, projects

How Molly watches development activity. All six are enabled by default; the
sensitive label dimensions inside them (command names, network hosts) are off
until you turn them on. Config keys live in `~/Library/Application Support/Molly/config.json`
(or `$MOLLY_CONFIG`) under `collectors.<name>`. Every collector also accepts
`enabled` (bool) and `interval` (seconds).

Counters are incremental: the first run after install initializes cursors at
"now" and never backfills history into a counter, so counters read 0 until
something new happens. Cursors persist in
`~/Library/Application Support/Molly/state/<collector>.json`. Running
`molly once` while the daemon runs advances the same cursors, so deltas seen by
`once` are not seen again by the daemon.

Label policies (`repos`, `branches`, `projects`, `commands`, `hosts`) take the
standard object: `enabled`, `mode` (`denylist`/`allowlist`), `patterns`, `hash`,
`salt`, `maxCardinality`. A disabled policy publishes the label value
`redacted`; aggregate counts without the label are always published. Label
values pass through the policy lowercased.

## git

**Measures** commits, churn, dirtiness and sync state of local repositories.
Repositories are found by walking `roots` (not descending into a repo, hidden
directories or `skipDirs`), cached, and rescanned every `rescanSeconds`. A repo
is *active* when its newest commit on any ref or an uncommitted change is within
`activeDays`; only active repos get labeled series. The `repo` label is
`owner/name` from the `origin` URL (ssh, scp-style or https, `.git` stripped),
else the directory name.

| metric | type | labels |
|---|---|---|
| `molly_git_repos` | gauge | |
| `molly_git_repos_active` | gauge | |
| `molly_git_commits_total` | counter | `repo`, `author` (`me`/`other`) |
| `molly_git_commits_today` | gauge | `repo` |
| `molly_git_lines_added_today`, `molly_git_lines_removed_today` | gauge | `repo` |
| `molly_git_dirty_files`, `molly_git_untracked_files` | gauge | `repo` |
| `molly_git_ahead`, `molly_git_behind` | gauge | `repo` |
| `molly_git_stashes` | gauge | `repo` |
| `molly_git_last_commit_timestamp_seconds` | gauge | `repo` |
| `molly_git_branch_info` | gauge (=1) | `repo`, `branch` |

Notes: `commits_total` counts commits whose author time is after a per-repo
cursor (so commits pulled from others count as `other`). `author=me` means the
author email equals the global `git config user.email` or is in `authorEmails`.
"Today" is local midnight, by author time, over `--all` refs; lines are summed
over all of today's commits regardless of author. When the `repos` policy is
disabled, per-repo gauges collapse into one `repo="redacted"` series (summed;
`max` for the timestamp). Gauges for more repos than `maxCardinality` keep the
most recently committed ones.

| key | default | |
|---|---|---|
| `roots` | `["~/src"]` | directories to search |
| `maxDepth` | `4` | levels below a root |
| `skipDirs` | `["node_modules", ".build", "vendor"]` | never entered |
| `rescanSeconds` | `1800` | repo discovery cache lifetime |
| `activeDays` | `30` | activity window |
| `authorEmails` | `[]` | extra emails that count as `me` |
| `repos` | enabled, denylist, `maxCardinality` 50 | policy |
| `branches` | enabled, denylist | policy for the `branch` label |
| `interval` | `120` | |

**Privacy.** Only read-only commands run (`log`, `status --porcelain=v2
--branch`, `stash list`, `rev-list --count`, `remote get-url origin`,
`config --global user.email`) with `GIT_OPTIONAL_LOCKS=0`, a 10 s timeout, and up
to 4 repos in parallel; a repo that times out is skipped (debug log). Commit
messages, file names, diffs and author emails are never exported; emails are
compared in memory only. Remote URLs are reduced to `owner/name`.

```json
"git": { "roots": ["~/src", "~/work"], "activeDays": 14,
         "authorEmails": ["me@work.example"],
         "repos": { "mode": "denylist", "patterns": ["acme/secret-*"], "maxCardinality": 40 } }
```

## claude_code

**Measures** Claude Code usage by tailing `~/.claude/projects/**/*.jsonl`
(including subagent transcripts) and counting lines in `~/.claude/history.jsonl`.
Per file only appended bytes are read; the byte offset is stored per path, a
partial trailing line waits for its newline, and a shrunken file is not replayed.
Files that exist at startup start at end-of-file; files *created* after Molly
started are read from the top (birth time is used rather than mtime, because a
long-running session file is modified after start but holds old data).

| metric | type | labels |
|---|---|---|
| `molly_claude_sessions_active` | gauge | |
| `molly_claude_sessions_total` | counter | |
| `molly_claude_sessions_today` | gauge | |
| `molly_claude_messages_total` | counter | `role` (`user`/`assistant`), `project` |
| `molly_claude_tool_calls_total` | counter | `tool`, `project` |
| `molly_claude_tokens_total` | counter | `model`, `kind` (`input`/`output`/`cache_read`/`cache_creation`) |
| `molly_claude_estimated_cost_usd_total` | counter | `model` |
| `molly_claude_subagent_messages_total` | counter | |
| `molly_claude_prompts_total` | counter | |
| `molly_claude_session_duration_seconds_total` | counter | `project` |

Notes:
- *Sessions* are `<project>/<uuid>.jsonl` files (not subagent files). `active`
  = modified within `activeWindowSeconds`; `today` = created since local
  midnight; `total` = created since Molly started.
- A model response is written as several lines (one per content block) that all
  repeat `usage`. Messages and tokens are counted once per `message.id`; tool
  calls are counted per `tool_use` block. User lines that only carry tool results
  or are meta are not counted as messages.
- `subagent_messages_total` is the sidechain subset of `messages_total`.
- Session duration adds the gap between consecutive timestamped lines of a file
  when the gap is at most `sessionGapSeconds` (idle time is excluded).
- `project` comes from the line's `cwd` (fallback: the directory name with `-`
  decoded to `/`, which is lossy). Paths under `.../github.com/<owner>/<repo>`
  become `owner/repo`, anything else is the last path component.
- Cost is an **estimate**: tokens times the list prices below, not your bill.
  Unknown models cost 0. Built-in defaults (USD per million tokens; `claude-fable`
  is a guess for a flagship tier, check it):

| model substring | input | output | cacheRead | cacheWrite |
|---|---|---|---|---|
| `claude-opus` | 5 | 25 | 0.5 | 6.25 |
| `claude-sonnet` | 3 | 15 | 0.3 | 3.75 |
| `claude-haiku` | 1 | 5 | 0.1 | 1.25 |
| `claude-fable` | 15 | 75 | 1.5 | 18.75 |

| key | default | |
|---|---|---|
| `projectsDir` | `~/.claude/projects` | |
| `historyFile` | `~/.claude/history.jsonl` | |
| `activeWindowSeconds` | `300` | |
| `sessionGapSeconds` | `1800` | longest gap counted as active |
| `pricing` | `{}` | `{"<model substring>": {"input", "output", "cacheRead", "cacheWrite"}}`. Overrides are checked before the defaults, in alphabetical order of the pattern; the first substring match wins, so a short pattern shadows a longer one that extends it. A missing price field counts as 0. |
| `projects` | enabled, denylist, `maxCardinality` 30 | policy |
| `interval` | `60` | |

**Privacy.** Only `type`, `isSidechain`, `isMeta`, `cwd`, `timestamp`,
`message.id`, `message.model`, `message.usage` and the *names* of tool calls are
parsed. Message text, tool inputs and results, and `history.jsonl`'s `display`
field are never read into a variable or exported (history lines are only counted).
`stats-cache.json` is not used (it is stale on this machine).

```json
"claude_code": { "activeWindowSeconds": 600,
                 "pricing": { "claude-sonnet": { "input": 3, "output": 15, "cacheRead": 0.3, "cacheWrite": 3.75 } },
                 "projects": { "mode": "denylist", "patterns": ["clientco/*"], "maxCardinality": 20 } }
```

## cursor

**Measures** Cursor's AI attribution database
`~/.cursor/ai-tracking/ai-code-tracking.db`, via a read-only snapshot copy
(`SQLiteSnapshot`), counting rows newer than a persisted cursor (timestamps are
epoch milliseconds). Absent database: `molly_cursor_available` is 0 and the
collector reports unavailable (logged once).

| metric | type | source |
|---|---|---|
| `molly_cursor_available` | gauge | 1 when the database could be read |
| `molly_cursor_ai_code_events_total` | counter | `ai_code_hashes.createdAt` |
| `molly_cursor_scored_commits_total` | counter | `scored_commits.scoredAt` |
| `molly_cursor_conversations_total` | counter | `conversation_summaries.updatedAt` (a conversation updated again counts again) |

| key | default |
|---|---|
| `databasePath` | `~/.cursor/ai-tracking/ai-code-tracking.db` |
| `interval` | `120` |

**Privacy.** Only `count(*)` and `max(<timestamp column>)` are selected. File
names, hashes, prompts, summaries, commit messages and file contents are never
read. The original file is never opened.

```json
"cursor": { "interval": 300 }
```

## codex

**Measures** OpenAI Codex CLI sessions under `~/.codex/sessions/**/*.jsonl` with
the same incremental tailing as `claude_code`. Codex's rollout format is not a
documented contract and no sessions exist on the development machine, so parsing
is covered by a fixture written from the commonly seen shape
(`response_item` messages, `turn_context.model`, `event_msg` `token_count` with
`last_token_usage`; the older top-level `message` shape is also accepted). When
the directory is missing the collector reports unavailable.

| metric | type | labels |
|---|---|---|
| `molly_codex_sessions_active` | gauge | |
| `molly_codex_sessions_total` | counter | |
| `molly_codex_messages_total` | counter | `role` |
| `molly_codex_tokens_total` | counter | `model`, `kind` (`input`/`output`/`cache_read`) |

Cached input is split out of `input_tokens`; repeated `token_count` events with
an unchanged cumulative total are skipped. No cost estimate, no project label.

| key | default |
|---|---|
| `sessionsDir` | `~/.codex/sessions` |
| `activeWindowSeconds` | `300` |
| `interval` | `120` |

**Privacy.** Only line type, message role, model name and token counts are read;
message content and the session's `cwd` are ignored.

```json
"codex": { "sessionsDir": "~/.codex/sessions" }
```

## shell

**Measures** commands run, from history files tailed by byte offset: zsh
(extended format `: epoch:duration;command`, multi-line continuations), bash
(timestamp comment lines when `HISTTIMEFORMAT` is set, otherwise line delta),
fish (`- cmd:` / `when:`). A pipeline or `&&`/`;` chain counts as one command.
For timestamped formats, entries older than the last counted one are ignored, so
a history rewrite (zsh compaction) does not replay old commands. `commands_today`
is seeded at startup from timestamps in the file (bash without timestamps counts
only commands seen while running) and resets at local midnight.

| metric | type | labels |
|---|---|---|
| `molly_shell_commands_total` | counter | `shell` (`zsh`/`bash`/`fish`) |
| `molly_shell_commands_today` | gauge | `shell` |
| `molly_shell_command_names_total` | counter | `command`; only when policy `commands` is enabled |
| `molly_shell_network_hosts_total` | counter | `remote_host`; only when policy `hosts` is enabled |

The label is `remote_host`, not `host`, because `host` is a registry-wide const
label and the registry rejects the collision.

Command name = basename of the first word of the first pipeline segment after
removing leading `FOO=bar` assignments, `sudo` (with its flags), `time` and
`nohup`. Hosts come from `http(s)://` URLs anywhere in the line and from the
first operand of `curl wget ssh scp sftp ping nc telnet dig nslookup host`
(skipping known value flags such as `ssh -p 22`; `user@` and `:port` stripped;
scp/sftp use the first `host:path` operand). Text after an unquoted `#` is
ignored. This is a best-effort parser, not a shell: `$(...)`, aliases and
here-docs are not interpreted.

| key | default | |
|---|---|---|
| `shells` | `["zsh","bash","fish"]` | which histories to read |
| `zshHistory` | `~/.zsh_history` | |
| `bashHistory` | `~/.bash_history` | |
| `fishHistory` | `~/.local/share/fish/fish_history` | |
| `commands` | **disabled**, allowlist, `maxCardinality` 50 | an allowlist is recommended |
| `hosts` | **disabled**, denylist, `maxCardinality` 50 | |
| `interval` | `60` | |

**Privacy.** Command text is held in memory only to extract a name and hosts; it
is never stored, logged or exported, and arguments never appear in any label.
With both policies disabled (default) names and hosts are not even extracted and
only counts are published. History files that do not exist are skipped; if none
exist the collector reports unavailable. `cwd` is not available from any of the
history formats; the prompt hook from `molly shell-hook` (see
[HOOKS.md](../HOOKS.md#shell-hook)) supplies it to the `projects` collector.

```json
"shell": { "shells": ["zsh"],
           "commands": { "enabled": true, "mode": "allowlist",
                         "patterns": ["git", "docker", "kubectl", "swift", "npm", "cargo", "make"] },
           "hosts": { "enabled": true, "mode": "denylist", "patterns": ["*.corp.example"] } }
```

## projects

**Measures** which projects are currently being worked on. `git` (new commit, or
a repo's dirty/untracked counts changed between runs) and `claude_code` (any
user/assistant line, at the line's timestamp) report `(project, source, time)` to
a process-wide `ProjectTracker`; this collector publishes the union. Project
names use the same normalization everywhere (`owner/repo` under `github.com/`,
else last path component). Register order puts it after `git` and `claude_code`.

| metric | type | labels |
|---|---|---|
| `molly_project_active` | gauge (=1) | `project`: activity within `activeWindowSeconds` |
| `molly_project_last_activity_timestamp_seconds` | gauge | `project`, `source` (`git`/`claude`/`shell`) |
| `molly_projects_active` | gauge | count of active projects (not capped by the policy) |

Projects idle longer than `retentionSeconds` are dropped; at most
`maxCardinality` projects (most recent first) are labeled. Source `shell` is
emitted once the shell hook (`molly shell-hook install`) is in place.

| key | default | |
|---|---|---|
| `activeWindowSeconds` | `1800` | |
| `retentionSeconds` | `86400` | |
| `projects` | enabled, denylist, `maxCardinality` 30 | same policy key as `claude_code` (each collector reads its own section) |
| `interval` | `60` | |

**Privacy.** Derived data only; nothing is read from disk. Under `molly once
--collector projects` the tracker is empty because the producers do not run.

```json
"projects": { "activeWindowSeconds": 900, "projects": { "patterns": ["clientco/*"] } }
```
