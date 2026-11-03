# The Settings window

Open it from the menu bar (Settings…, or ⌘, while the menu is open). It edits
the same `config.json` the daemon reads, so anything you can set in the file
you can set here, and the file stays the source of truth for `molly validate`,
`molly tune` and hand edits.

## How edits land

- Changes stay in memory until you press **Apply**. The footer shows unsaved
  changes, or the reason the current edits would be rejected (the same checks
  `molly validate` runs).
- Apply validates, copies the previous file to `config.json.bak-<timestamp>`
  next to it (the ten newest are kept), writes the new file, and reloads the
  daemon exactly like **Reload Config**.
- **Revert** drops the in-memory edits. Reopening the window re-reads the
  file unless you have unapplied edits.
- Keys the window does not know about are kept as they are. Keys are written
  in sorted order.
- Salts and API keys are write-only: the window shows whether one is set and
  lets you replace or clear it, never the value.

## Tabs

| tab | what it holds |
|---|---|
| Collectors | every collector: on/off, poll interval, the permission it needs and a button to the matching System Settings pane when the daemon reports it unavailable |
| Privacy | every sensitive label dimension from [PRIVACY.md](PRIVACY.md): record real names or not, allowlist or denylist, patterns, hashing, cardinality limit, plus the Strict / Balanced / Developer presets |
| Server | bind address and port, Grafana and Prometheus links, log level, extra const labels, the hook token |
| Agents | the insights collector (backend, model, schedule, API key) and the MCP Prometheus URL |
| Maintenance | forget data per collector, Prometheus retention |

### Presets

A preset copies the collector on/off flags and every label policy from one of
the example configs in `config/` over your current settings, leaving paths,
intervals and tokens alone. Existing salts are kept when the preset has none.
The presets are embedded in the binary by `scripts/generate-presets.py`; a
unit test fails when the embedded copy and the file drift apart.

### Forget data

Each collector that keeps an import cursor (last imported message, last seen
commit, ...) has a file under `~/Library/Application Support/Molly/state/`.
**Forget** deletes that file after pausing collection, then reloads, so the
collector starts as if freshly installed: counters restart from its next run
and nothing older than that is backfilled.

Metrics already stored in Prometheus are not touched. To delete history use
`molly prune --older-than 30d` (needs the admin API, which the local stack
enables) or stop the stack and remove `deploy/data/prometheus`.

### Prometheus retention

`stack.retention` is a Prometheus duration (`90d`, `26w`, `2y`). **Apply
retention** saves the config, writes `PROMETHEUS_RETENTION=<value>` into
`<stack.composeDir>/.env` (other lines are kept) and runs
`docker compose up -d prometheus` there, which recreates the container with
the new `--storage.tsdb.retention.time`. The compose folder defaults to the
`deploy/` folder of a source checkout found near the running binary; set
`stack.composeDir` when Molly runs from `/Applications` and the checkout lives
elsewhere. `deploy/.env` is ignored by git.

## Config keys the window adds

| key | default | meaning |
|---|---|---|
| `stack.retention` | `"2y"` | retention applied to the local stack |
| `stack.composeDir` | the checkout's `deploy/` | where `docker-compose.yml` lives |

Everything else the window edits is documented in [CONFIG.md](CONFIG.md).
