# Apple Health from your iPhone

macOS has no HealthKit, so a Mac cannot read your Health data. Your iPhone can:
the Molly Health app (or, as a fallback, a Shortcut) collects the numbers and posts them to Molly over Tailscale (or your home network).
Molly turns them into `molly_health_*` metrics, a **Body** Grafana dashboard
([DASHBOARDS.md](DASHBOARDS.md#body-molly-body)) and, in coarse buckets, your
insights digest.

```
iPhone app ──POST /health (Bearer token)──▶ Molly (Tailscale) ──▶ /metrics ──▶ Prometheus
```

This is the most personal data Molly handles. Read "Health data" in
[PRIVACY.md](PRIVACY.md) first. In short: it is off by default, nothing is
accepted without a token, and Molly refuses to take it over a non-loopback
bind unless you say so explicitly.

## 1. Turn it on on the Mac

Pick a long random token (`openssl rand -hex 24`) and edit `config.json`
(`molly config-path`). The recommended setup is Tailscale: Molly keeps serving
loopback and also serves your Tailscale address, so only devices on your tailnet
can reach the health route. Get the address with `tailscale ip -4`.

```json
{
  "server": { "bind": ["127.0.0.1", "100.101.102.103"], "port": 9765 },
  "collectors": {
    "health": {
      "enabled": true,
      "token": "PASTE-THE-TOKEN",
      "allowRemoteBind": true
    }
  }
}
```

Molly serves on `127.0.0.1` by default, which your phone cannot reach. Adding a
non-loopback address exposes health data to that network, so the health
collector then also requires `allowRemoteBind: true`. Without it the collector
will not start (`/collectors` and the Settings window show it as unavailable,
and the message lists the non-loopback binds) and `POST /health` answers `403`.

Notes:

- Keeping `127.0.0.1` in the list means nothing else changes: the Docker
  Prometheus target stays `host.docker.internal:9765`, and the CLI, the Settings
  window and `molly mcp` keep talking to loopback.
- If Tailscale starts after Molly (login item order, a reboot), the Tailscale
  address does not exist yet. Molly logs that once, keeps serving loopback, and
  retries every 30 seconds until it binds. `molly_server_listening{bind}` and
  `/stats` show which addresses are up.
- Remember `/metrics` has no authentication. Anyone who can reach the Tailscale
  address can read the health gauges; use Tailscale ACLs if the tailnet is shared.

Fallback without Tailscale: bind to the Mac's **LAN IP** (`ipconfig getifaddr en0`)
instead of the Tailscale address, not `0.0.0.0`, so Molly does not listen on every
interface (VPN, hotspot, Docker). Reserve the address in your router since DHCP
addresses change, keep the macOS firewall on, and use the same `bind` list with
loopback first. Phone and Mac must then be on the same network.

Restart Molly. `curl` should now work from the Mac (replace the address):

```sh
curl -i -X POST http://100.101.102.103:9765/health \
  -H 'Authorization: Bearer PASTE-THE-TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"device":"iphone","date":"2026-11-03","totals":{"steps":8120,"stand_hours":9}}'
```

`200` with `{"accepted": 2, "rejected": {}}` means it worked. `401` is a wrong
or empty token, `403` is the bind guard, `400` is a body Molly could not use,
`413` is a body over 64 KiB, `503` is the collector being disabled.

## 2. The address your phone uses

With Tailscale, use the MagicDNS name: `http://<machine>.<tailnet>.ts.net:9765/health`
(plain `http://`, the tailnet already encrypts the traffic). Find the name in the
Tailscale menu or with `tailscale status`. It works from anywhere your phone is
connected to Tailscale, not just on home Wi-Fi.

On the LAN fallback use `http://<your-mac>.local:9765/health` (System Settings >
General > Sharing > Local hostname, or `scutil --get LocalHostName`); the phone
must be on the same Wi-Fi, so set the automation to run on arrival to avoid
failures away from home. `.local` resolves through Bonjour; if it does not on
your network, use the IP.

## 3. The payload

Two shapes, both `Content-Type: application/json`.

**Samples** (one entry per Health sample or per hour):

```json
{
  "device": "iphone",
  "samples": [
    {"type": "steps", "start": "2026-11-03T08:00:00-05:00", "end": "2026-11-03T09:00:00-05:00", "value": 812, "unit": "count"},
    {"type": "heart_rate_bpm", "start": "2026-11-03T09:10:00-05:00", "end": "2026-11-03T09:10:00-05:00", "value": 71},
    {"type": "bedtime", "value": "2026-11-02T23:30:00-05:00"}
  ]
}
```

**Daily totals** (Shortcuts sums the samples itself; easiest):

```json
{
  "device": "iphone",
  "date": "2026-11-03",
  "totals": {"steps": 8120, "stand_hours": 9, "exercise_minutes": 34,
             "sleep_minutes": 455, "bedtime": "2026-11-02T23:30:00-05:00",
             "resting_heart_rate_bpm": 57}
}
```

**Several days of totals** (backfill after the phone was offline; at most 31 entries):

```json
{
  "device": "iphone",
  "days": [
    {"date": "2026-11-01", "totals": {"steps": 7410, "sleep_minutes": 430}},
    {"date": "2026-11-02", "totals": {"steps": 9022, "sleep_minutes": 455}},
    {"date": "2026-11-03", "totals": {"steps": 8120}}
  ]
}
```

Each entry is handled exactly like the single `date` + `totals` form, including
the `maxAgeSeconds` cut-off, and a bad entry (unparseable date, too old, bad
value) is counted in `rejected` without failing the others. The response's
`accepted` and `rejected` cover all days. More than 31 entries, or `days`
together with `totals` or `samples`, is a `400`. 31 days of all 21 types, with
a full ISO timestamp for each value, is about 33 KB, so the 64 KiB body limit
below stays as it is.

Rules:

- Times are ISO 8601 with an offset. Days are your Mac's local days.
- `value` may be a number or a string (Shortcuts often produces strings).
- The token goes in `Authorization: Bearer <token>`, or in a `"token"` field.
- `totals` without `date` means today. A day's totals **replace** that day's
  value, so send them as often as you like. Do not mix `samples` and `totals`
  for the same type and day.
- Samples are keyed by `start` and `end`: re-posting the same hour replaces it
  instead of adding twice, so an hourly automation can resend the whole day.
- Samples that ended more than `maxAgeSeconds` ago (7 days) are rejected, as
  are unknown types, unusable values and unparseable times. Rejections are
  counted in `molly_health_samples_rejected_total{reason}` and never fail the
  rest of the post.
- `device` is a free label: lowercased, `[a-z0-9_-]`, 32 characters, at most 5
  distinct values and then `other`.
- Bodies over 64 KiB (roughly 400 samples) get `413`: send totals, or one day
  at a time.

### Types and the Health data to read

| `type` | meaning and unit | Shortcuts: Find Health Samples where Type is... | day value |
|---|---|---|---|
| `steps` | count | Steps | sum |
| `stand_hours` | hours stood | Apple Stand Hours (count of "stood" samples) | sum |
| `active_energy_kcal` | kcal | Active Energy | sum |
| `exercise_minutes` | minutes | Exercise Minutes | sum |
| `resting_heart_rate_bpm` | bpm | Resting Heart Rate | latest |
| `heart_rate_bpm` | bpm | Heart Rate | latest |
| `hrv_ms` | ms | Heart Rate Variability | latest |
| `sleep_minutes` | minutes asleep | Sleep Analysis, asleep stages | sum, on the wake-up day |
| `sleep_in_bed_minutes` | minutes in bed | Sleep Analysis, in bed | sum, on the wake-up day |
| `bedtime` | ISO time or `HH:mm` | Sleep Analysis, earliest Start Date of the night | latest |
| `wake_time` | ISO time or `HH:mm` | Sleep Analysis, latest End Date of the night | latest |
| `walking_distance_m` | metres | Walking + Running Distance | sum |
| `flights_climbed` | count | Flights Climbed | sum |
| `daylight_minutes` | minutes | Time in Daylight | sum |
| `headphone_audio_db` | dB | Headphone Audio Levels | day maximum |
| `vo2max` | mL/min-kg | Cardio Fitness (VO2 Max) | latest |
| `body_mass_kg` | kg | Body Mass | latest |
| `respiratory_rate` | breaths/min | Respiratory Rate | latest |
| `blood_oxygen_ratio` | 0 to 1 (97 and "97 %" are read as 0.97) | Blood Oxygen Saturation | latest |
| `wrist_temperature_delta_c` | degrees C change from baseline | Sleeping Wrist Temperature | latest |
| `mindful_minutes` | minutes | Mindful Minutes | sum |

In `samples` form a `unit` is converted when it is recognised (`km`, `mi`, `lb`,
`g`, `kJ`, `s`, `hr`, `degF`); otherwise the canonical unit above is assumed.
`totals` always uses the canonical units. Send only the types you care about.

Bedtime and wake time are stored as seconds after local midnight. A bedtime
before noon counts past 24:00, so 23:30 is `84600` and 01:15 is `90900`, and the
night belongs to the morning you wake up. `molly_health_sleep_minutes_last_night`
and `molly_health_bedtime_seconds` are the numbers to correlate against the
next day's work.

## 4. Install the iPhone app (recommended)

`ios/` holds **Molly Health**, a small open-source SwiftUI app that reads
HealthKit directly and posts the daily totals from section 3 to `POST /health`.
It sends nothing unless a type has data, so an empty type never stops the rest
(the Shortcut's "Find Health Samples" halts the whole run on one). No analytics,
no third-party code, and no network calls other than your configured Mac URL.

1. On the Mac, open `ios/MollyHealth.xcodeproj` in Xcode (or `make ios-project`
   first if you changed `ios/project.yml`).
2. Select the **MollyHealth** target, then Signing & Capabilities, and pick your
   team. The project defaults to team `DQR8D2E7KK` and bundle id
   `com.aschepis.molly.health`; change both if they are not yours.
3. Plug in the iPhone, trust the Mac, choose the phone as the run destination
   and press Run. The first time, enable Developer Mode on the phone (Settings >
   Privacy & Security) and trust the developer profile (Settings > General >
   VPN & Device Management).
4. In the app tap **Grant Health access** and allow every type you want. iOS
   asks once; change it later in Settings > Health > Data Access.
5. Paste the token. `molly config-path` prints the config file; the value is
   `collectors.health.token`. The server URL defaults to
   `http://adams-macbook-pro.tail853834.ts.net:9765`; edit it to your Mac's
   MagicDNS name (section 2).
6. Tap **Test connection**. It calls `/healthz` and then `/health/status` with
   the token. "server does not report status yet" means the Mac is older than the
   status route (404); "bad token" is a 401; "health collector disabled on the
   Mac" is a 503.
7. Tap **Send now**, check the status section (HTTP status, accepted and
   rejected counts) and the table of today's totals, then look at the Body
   dashboard.
8. For background updates leave Background App Refresh on (Settings > General)
   and open the app once after a reboot. The app registers an hourly HealthKit
   observer for each enabled type and a background refresh task as a fallback;
   each posts today, plus yesterday when the date changed since the last post so
   last night's sleep lands on the wake-up day. Posts are limited to one per five
   minutes, except Send now. iOS decides when background work really runs, so a
   phone left locked for hours may deliver late; HealthKit data is protected while
   the phone is locked, so queries made then can come back empty and the next
   unlocked delivery fixes the day.

Things to know:

- **Reinstall once a year.** A development build signed with a paid Apple
  Developer account stops launching after a year (a free account: seven days).
  Run it from Xcode again to renew it. Your settings and token survive.
- **Backfill** posts one request per day, oldest first. The Mac rejects days older
  than `collectors.health.maxAgeSeconds` (7 days by default), so raise it before
  backfilling a month.
- A type with no samples is left out of the post, except steps, active energy,
  walking distance, flights, exercise, daylight, stand hours and mindful minutes,
  which send `0` when the query ran and found nothing.
- Sleep is the union of the asleep stages of samples that ended today, so a watch
  and a phone recording the same night are not counted twice.
- HealthKit exposes the absolute sleeping wrist temperature, not the change from
  baseline. The app sends today's average minus the average of the previous 28
  days as `wrist_temperature_delta_c`; it is omitted until there is a baseline.
- The app allows plain HTTP to any host because the address is normally a
  Tailscale name (the tailnet encrypts the traffic). Use `https://` if you front
  Molly with something that terminates TLS.

See [ios/README.md](../ios/README.md) for the layout and build commands.

## 4b. Fallback: a Shortcut

If you cannot run the app, a Shortcut does the same job, with one weakness: a
Health type with no samples can halt the run, so some days send nothing.

### The fast way: generate it

```sh
scripts/generate-health-shortcut.py adams-macbook-pro.tail853834.ts.net
```

writes a signed `Molly Health.shortcut` to the Desktop with every type from the
table, the token from your config and the URL for the host you name. Open the
file on the Mac to import it into Shortcuts (iCloud syncs it to the phone), or
AirDrop it to the phone. The first run asks for Health read access per type.
The file contains the token: it is git-ignored, do not share it.

A dozen Health type labels in the generator were not confirmed against a real
export (the script prints them). If a "Find Health Samples" row shows an empty
type on the phone, pick the type from its menu once; everything else is wired.

### By hand

I cannot drive the Shortcuts app from here, so treat the action names as a
guide: Apple renames them between iOS versions. The steps are the same shape in
every version. Start with `steps` only, check it with `curl`, then add types.

1. Open **Shortcuts** on the iPhone, tap **+**, name it "Molly Health".
2. **Date** (Current Date), then **Format Date** with format **ISO 8601**.
   Name the result `Today`. Use a custom format `yyyy-MM-dd` for the `date`
   field.
3. For each type, add **Find Health Samples**:
   - Type: the name from the table.
   - Filter: **Start Date is today**. For sleep use **End Date is today**
     because the night ends this morning.
   - Then **Calculate Statistics** (Sum for additive types, Latest for point
     types) over the samples' **Value** (or **Duration** for sleep, in
     minutes). Name each result, for example `Steps`.
   - Sleep: add a filter on **Value** so asleep stages are counted in
     `sleep_minutes` and in-bed in `sleep_in_bed_minutes`. For `bedtime` sort
     by **Start Date** earliest first, **Limit 1**, **Get Details of Health
     Samples: Start Date**, format as ISO 8601. For `wake_time` use latest
     **End Date**.
   - A type with no samples gives an empty result: wrap it in **If Has Any
     Value** or leave it out of the dictionary.
4. **Dictionary**: keys `device` (text `iphone`), `date` (the formatted date)
   and `totals` (a nested **Dictionary** with one key per type, values from the
   statistics above).
5. **Get Contents of URL**:
   - URL `http://<your-mac>.local:9765/health`
   - Method **POST**
   - Headers: `Authorization` = `Bearer PASTE-THE-TOKEN`, `Content-Type` =
     `application/json`
   - Request Body **JSON**, using the Dictionary from step 4.
6. Optionally **Show Notification** with the result while you test; remove it
   when it works.

### Run it on a schedule

In **Automation** create a **Personal Automation** that runs the Shortcut and
turn off **Ask Before Running** (and **Notify When Run**):

- **Time of Day**, hourly (create one automation per hour you want), or
- **Charger** connected (you plug in at night and in the morning), or
- **Arrive** at home (the Mac is reachable when you walk in), or
- **Wi-Fi** your home network.

Because totals replace the day, running it often is harmless. Running it on
the charger at night and on arrival at home is usually enough for sleep and
daily totals; hourly gives you `NotStandingEnough` and the live tiles.

## 5. Check it

```sh
curl -s http://127.0.0.1:9765/metrics | grep molly_health      # on the Mac, if bound there
molly once --collector health
```

Ask the running daemon what it has stored (same token as the POST, in the
`Authorization` header):

```sh
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9765/health/status
molly health status        # same thing as a table, token read from config.json
```

The JSON is `{"ok": true, "last_post": <unix seconds or null>, "devices": [...],
"today": {"<type>": value}, "yesterday": {...}, "types": [every type Molly
accepts], "max_age_seconds": N, "max_body_bytes": N}`. Values are the stored
day values in the units of the Types table; `bedtime` and `wake_time` are
seconds after local midnight (bedtime after midnight counts past 86400). The
token is never included. Answers match POST: `401` without or with a wrong
token (the body `token` field does not apply to a GET), `403` when the bind
guard refuses, `503` when the collector is disabled. `molly health status`
exits 1 when the daemon is unreachable, the token is rejected, or the
collector is disabled.

The Body dashboard's **Pipeline** row shows the age of the last post and what
was accepted or rejected. `molly_health_samples_rejected_total{reason}` rising
means the payload needs a look (`bad_type` is a misspelt type, `bad_time` a time
that is not ISO 8601).

## 6. Import your history

The Shortcut only supplies recent days. To load years of history, export from
the Health app (profile picture > **Export All Health Data**) and import the
zip:

```sh
molly health import ~/Downloads/export.zip --out molly-health.om
```

Molly streams `export.xml` (exports are gigabytes; it is never loaded into
memory) and writes one `molly_health_day{type,user,host}` sample per type per
local day, timestamped at 12:00, ending with `# EOF`. A zip is first unpacked
to a temporary file, so allow disk space for the XML. It reads quantity records
for the types above plus sleep analysis (asleep stages merged across sources,
in bed, bedtime, wake time), stand hours and mindful sessions. Imported
`wrist_temperature_delta_c` is not available (the export holds the absolute
temperature, not the change). Watch and phone both record steps; the export
keeps both, so imported steps can read higher than the Health app's total.

Then load it into Prometheus. `promtool` writes blocks straight into the data
directory, so **Prometheus must be stopped** (or the blocks moved in while it is
down):

```sh
make stack-down
promtool tsdb create-blocks-from openmetrics molly-health.om deploy/data/prometheus
make stack-up
```

Without `promtool`, use the image the stack runs:

```sh
docker run --rm -v "$PWD:/in" -v "$PWD/deploy/data/prometheus:/data" \
  --entrypoint promtool prom/prometheus:v3.7.3 \
  tsdb create-blocks-from openmetrics /in/molly-health.om /data
```

The command prints the exact paths for your setup (`export.prometheusDataDir`
or `MOLLY_DATA_DIR` change the data directory). Importing the same file twice
duplicates blocks; Prometheus merges identical samples on compaction, but
prefer to import once. The Body dashboard reads `molly_health_day` for history
and `molly_health_today`/`_yesterday` for live data in the same panels.

## Metrics and rules

See the `health` section of [METRICS.md](METRICS.md). The `molly-body` rule group
adds `molly:health_sleep_minutes:last_night` and
`molly:active_unbroken_hours:1d`, and the informational alert
`NotStandingEnough` (active for 90 minutes with no new stand hour or steps).

## Insights

`molly insights` includes, when the collector is on, three coarse buckets only:
sleep (short under 6 h, ok, long over 9 h), movement (low under 5,000 steps,
ok, high over 12,000) and resting heart rate against your four-week norm (down,
flat, up, at a 2 bpm shift). Nothing finer reaches the model unless you set
`collectors.health.detailedInsights` to `true`, which adds sleep minutes, steps,
exercise, stand hours, resting heart rate and HRV.
