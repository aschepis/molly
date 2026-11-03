# Tuning

`molly tune` looks at how Molly is actually behaving on this machine and
proposes config changes. It is rules-based, runs in a second or two, and
never changes anything unless you pass `--apply`.

```sh
molly tune            # readable list of recommendations
molly tune --json     # the same as JSON, for scripts or an agent
molly tune --apply    # merge every patch into config.json (backup written first)
```

## What it reads

| source | used for |
|---|---|
| `GET /stats` on the running daemon | series per metric family, distinct values per label, collector status |
| `GET /collectors` | runs, errors, last error, last duration, how long a source has been unavailable |
| Prometheus (`links.prometheus`) | `scrape_duration_seconds` and `scrape_samples_scraped` for the molly job |
| `GET /privacy` (when the daemon has it) | counts of values folded to `other` and `redacted` |
| the config file | current intervals and label policies |
| the machine | whether `~/.codex/sessions`, Apple Mail's Envelope Index, Accessibility trust or a scriptable browser exist |

If the daemon is not running, or predates `/stats`, `tune` runs every
collector once in-process (like `molly once`, without advancing cursors) to
measure the registry.

## The rules

| # | trigger | severity | patch |
|---|---|---|---|
| 1 | a collector unavailable for over an hour with a permission-shaped error | warn | `enabled: false` for that collector (or grant the permission instead) |
| 2 | a collector's last run took more than half its interval | warn | `interval` raised to twice the run time |
| 3 | more than 20% of a collector's runs failed (at least 5 runs) | warn | none; the last error is shown |
| 4 | a label has more than 100 distinct values, or more than twice its `maxCardinality` | warn | `maxCardinality` halved (or set to 50 when unlimited) on the governing policy |
| 5 | more than 5000 series in the registry or per scrape | warn | `enabled: false` on the label policies of the three largest families |
| 6 | scrapes take more than 2 seconds | warn | intervals doubled for the three slowest collectors |
| 7 | a disabled collector whose source exists on this machine | info | none; enabling data collection is your call |
| 8 | `browser.domains`, `shell.hosts` or `shell.commands` enabled without `hash` | info | none |
| 9 | `server.bind` is not loopback and `events.token` is empty | warn | none |

Rules that suggest disabling a label policy keep the aggregate metric; only
the per-value series go away. Nothing here ever enables a sensitive
dimension.

## Applying

`--apply` deep-merges the combined patch into the config file: objects merge
key by key, arrays and scalars are replaced. The previous file is copied to
`config.json.bak-<timestamp>` first and the result is validated before it is
written. The daemon does not watch the file, so choose "Reload Config" from
the menu bar (or restart) afterwards. Review the printed patches before
applying: a recommendation to disable a collector is a judgement about
noise, not about what you want to measure.

## Reading the numbers yourself

The Health dashboard's "Registry size" row shows `molly_self_series_total`,
`molly_self_metric_families` and the largest families. A family that grows
day over day is the usual sign that a label policy needs `maxCardinality`
or a denylist pattern.
