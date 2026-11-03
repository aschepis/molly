# Group B collectors: browser, messages, notes, knowledge, calendar, mail

These collectors read other apps' SQLite databases. Every read goes through
`SQLiteSnapshot.open` (copy, then open the copy read-only), so Molly never
locks or modifies a source database.

Common behaviour:

- Counters (`*_total`) are incremental. Each source has a cursor in
  `~/Library/Application Support/Molly/state/<collector>.json`. On first run the
  cursor starts at "now" (process start, or the newest ROWID), so history is
  never backfilled. Cursors survive restarts, so activity that happened while
  Molly was stopped is counted on the next run.
- `*_today` gauges are recomputed from the source every run with a local
  midnight boundary (`Calendar.current.startOfDay`).
- A missing or unreadable source raises `CollectorUnavailable` (logged once).
  Full Disk Access must be granted to the host process (your terminal in
  development, the `molly` binary or `Molly.app` under launchd).
- Label values pass through `LabelFilter`, which lowercases them.
- Privacy: no URL, page title, message text, contact, note title, event title or
  email address is ever read into a metric or log line.

Every collector accepts `enabled` and `interval` (seconds).

## browser

Visits recorded in browser history.

Detected automatically: `safari`, `chrome`, `chrome_beta`, `chrome_canary`,
`brave`, `arc`, `edge`, `vivaldi`, `firefox`, `orion` (every Chromium profile
directory named `Default` or `Profile N`, every Firefox profile). Profiles of one
browser are summed under one `browser` label. Each profile has its own cursor.
Orion is assumed to use Safari's history schema (unverified; no Orion on the
development machine).

| metric | type | labels |
|---|---|---|
| `molly_browser_available` | gauge | `browser`; 1 if readable, 0 if detected but unreadable |
| `molly_browser_visits_total` | counter | `browser` |
| `molly_browser_visits_today` | gauge | `browser` |
| `molly_browser_distinct_domains_today` | gauge | `browser` |
| `molly_browser_domain_visits_total` | counter | `browser`, `domain` (policy `domains`) |
| `molly_browser_domain_visits_today` | gauge | `browser`, `domain` (policy `domains`) |
| `molly_browser_history_rows` | gauge | `browser` (rows in the URL table) |

Domain labels are the lowercased host with scheme, userinfo and port stripped.
`www.` is kept, punycode is left as is. Only `http`, `https` and `ftp` URLs count
toward domains (they still count as visits). The per-run domain counter delta is
capped to `maxCardinality` (remainder in `other`), but the series set can still
grow over time.

| key | default | meaning |
|---|---|---|
| `interval` | 60 | seconds between runs |
| `browsers` | `[]` (all) | restrict to these browser names |
| `extraProfiles` | `[]` | `[{"browser": "chrome", "path": "/path/to/History"}]`; schema inferred from the name (`safari`/`orion` = Safari, `firefox` = Firefox, anything else Chromium) |
| `domains` | disabled, denylist, maxCardinality 50 | label policy for `domain` |

Permissions: Full Disk Access for Safari only. Chromium and Firefox histories are
readable without it.

```json
"browser": {
  "enabled": true,
  "interval": 60,
  "browsers": ["safari", "chrome"],
  "extraProfiles": [{ "browser": "chrome", "path": "~/Library/Application Support/Google/Chrome/Profile 3/History" }],
  "domains": { "enabled": true, "mode": "denylist", "patterns": ["*.bank.example"], "maxCardinality": 50 }
}
```

## messages

Counts from `~/Library/Messages/chat.db`. Service messages are excluded.
Cursor: last `message.ROWID`.

| metric | type | labels |
|---|---|---|
| `molly_messages_total` | counter | `service` (iMessage, SMS, RCS, other), `direction` (sent, received) |
| `molly_messages_today` | gauge | `service`, `direction` |
| `molly_messages_with_attachments_total` | counter | `direction` |
| `molly_message_chats_active_today` | gauge | |
| `molly_messages_unread` | gauge | received messages with `is_read = 0` |

| key | default | meaning |
|---|---|---|
| `interval` | 60 | |
| `path` | `~/Library/Messages/chat.db` | override |

Permissions: Full Disk Access. Privacy: only aggregate counts are selected; no
text, handles or chat names.

```json
"messages": { "enabled": true, "interval": 60 }
```

## notes

From `NoteStore.sqlite` (`ZICCLOUDSYNCINGOBJECT`). Notes are rows with a
`ZTITLE1`; folders are rows with a `ZTITLE2`. Notes marked for deletion and notes
in "Recently Deleted" are excluded. Cursor: wall-clock time of the previous run.
Modified counts include newly created notes.

| metric | type | labels |
|---|---|---|
| `molly_notes_count` | gauge | |
| `molly_notes_folders` | gauge | |
| `molly_notes_created_total` / `molly_notes_modified_total` | counter | |
| `molly_notes_created_today` / `molly_notes_modified_today` | gauge | |
| `molly_notes_folder_modified_total` | counter | `folder` (policy `folders`) |

Deviation from the plan: the per-folder counter is its own family
(`molly_notes_folder_modified_total`) because one Prometheus family cannot be both
labelled and unlabelled.

| key | default | meaning |
|---|---|---|
| `interval` | 120 | |
| `path` | `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` | |
| `folders` | disabled, denylist, maxCardinality 50 | label policy for `folder` |

Permissions: Full Disk Access. Privacy: note titles and bodies are never selected.

```json
"notes": { "enabled": true, "folders": { "enabled": false } }
```

## knowledge

System-recorded usage from `knowledgeC.db`, which keeps accumulating while Molly
is not running. Rows are selected with `ZENDDATE > cursor AND ZENDDATE <= now` and
each row is clipped to start no earlier than the cursor, so rows extended in place
are not double counted. Open-ended rows (no end date yet) are skipped until they
close. One cursor (newest `ZENDDATE` seen) per stream.

Streams: `/app/usage`, `/app/mediaUsage`, `/display/isBacklit` (value 1),
`/bluetooth/isConnected` (value 1), `/notification/usage` (action `Receive`, app
from the structured metadata table).

| metric | type | labels |
|---|---|---|
| `molly_knowledge_app_usage_seconds_total` | counter | `app` (bundle id, policy `apps`) |
| `molly_knowledge_app_usage_seconds_today` | gauge | `app` |
| `molly_knowledge_notifications_total` | counter | `app` |
| `molly_knowledge_notifications_today` | gauge | |
| `molly_knowledge_media_playing_seconds_total` | counter | `app` |
| `molly_knowledge_display_on_seconds_total` | counter | |
| `molly_knowledge_bluetooth_connected_seconds_total` | counter | |

When `apps` is disabled, every app series collapses into `app="redacted"`.
Notifications without a recorded app use `app="unknown"`.

| key | default | meaning |
|---|---|---|
| `interval` | 60 | |
| `path` | `~/Library/Application Support/Knowledge/knowledgeC.db` | |
| `apps` | enabled, denylist, maxCardinality 50 | label policy for `app` |

Permissions: Full Disk Access. Privacy: bundle ids only; no content.

```json
"knowledge": { "enabled": true, "apps": { "enabled": true, "mode": "denylist", "patterns": ["com.example.private"] } }
```

## calendar

Reads Calendar's `OccurrenceCache` (recurring events already expanded), joined to
`CalendarItem` and `Calendar`. Hidden and cancelled (status 3) items are ignored.
Looks for `~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb`
then `~/Library/Calendars/Calendar.sqlitedb`. If the tables are missing the
collector reports itself unavailable.

| metric | type | labels |
|---|---|---|
| `molly_calendar_events_today` | gauge | `calendar` (policy `calendars`; one `redacted` series when disabled) |
| `molly_calendar_event_seconds_today` | gauge | timed events only, overlaps merged |
| `molly_calendar_event_seconds_remaining_today` | gauge | |
| `molly_calendar_in_event` | gauge | 1 during a timed event |
| `molly_calendar_next_event_start_seconds` | gauge | seconds until next timed event, -1 if none cached |

All-day events count in `events_today` but not in seconds. The next-event lookup
only sees what Calendar has cached in `OccurrenceCache`.

| key | default | meaning |
|---|---|---|
| `interval` | 300 | |
| `path` | auto-detected | override |
| `calendars` | disabled, denylist, maxCardinality 50 | label policy for `calendar` |

Permissions: Full Disk Access. Privacy: event titles, locations, attendees and
notes are never selected. EventKit is not used.

```json
"calendar": { "enabled": true, "calendars": { "enabled": true, "mode": "allowlist", "patterns": ["Work"] } }
```

## mail

Best-effort, default `enabled: false`. Reads the highest
`~/Library/Mail/V<n>/MailData/Envelope Index`. Direction comes from the mailbox
URL: a final path component starting with `Sent` is sent; Drafts, Junk, Spam,
Trash, Deleted, Outbox and SendLater are ignored; everything else is received.
Deleted messages are ignored. Cursor: last `messages.ROWID`. A schema mismatch
(Mail changes this between macOS releases) makes the collector unavailable.

| metric | type | labels |
|---|---|---|
| `molly_mail_messages_total` | counter | `direction` |
| `molly_mail_messages_today` | gauge | `direction` |
| `molly_mail_unread` | gauge | |

| key | default | meaning |
|---|---|---|
| `enabled` | false | |
| `interval` | 120 | |
| `path` | auto-detected | override |

Permissions: Full Disk Access. Privacy: only mailbox URLs and counts; no senders,
subjects or addresses.

```json
"mail": { "enabled": true, "interval": 120 }
```

## Doctor checks

`molly doctor` lists detected browsers and profile counts, whether Safari history
is readable, and whether `chat.db` is readable.
