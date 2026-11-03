# Group D collectors: power, builds, tabs

How Molly sees the machine's power state, build activity and browser load.
`power` and `builds` are enabled by default; `tabs` is off because it needs
Automation permission. Every collector accepts `enabled` and `interval`; other
keys are in [CONFIG.md](../CONFIG.md). Cursors persist in
`~/Library/Application Support/Molly/state/<collector>.json`, and `molly once`
reads them but never advances them.

## power

**Measures** sleep, dark wake, full wake and boot events, the latest wake
reason, and awake and asleep time since local midnight.

**Source.** `pmset -g log` (about two seconds to run, so the interval is 300s)
and `sysctl kern.boottime`. Only `Sleep`, `Wake` and `DarkWake` lines are
parsed; the thousands of `Assertions` lines are skipped. Timestamps are
pmset's local format with an offset, for example `2026-11-03 08:41:12 -0500`.

**Cursor.** The newest parsed event time. On the first run it starts at process
start minus `backfillSeconds` (default 86400), so a fresh install counts the
last day. This is a deliberate exception to "never backfill"; set
`backfillSeconds` to 0 to avoid it.

**Awake time.** A full `Wake` event means awake; `Sleep` and `DarkWake` mean
asleep. Maintenance and Power Nap dark wakes are common on laptops, so they are
sleep, not awake time. The state at midnight is taken from the last earlier
event, or inferred from the first event of the day when the log starts later.
The two gauges sum to the seconds since midnight.

**Wake reason.** The free text after `due to` is mapped to one of `lid`,
`power button`, `user activity`, `scheduled`, `notification`, `other`. Raw text
is never exported.

**Boots.** Counted when `kern.boottime` is later than the last boot seen. `last
reboot` is not used because it prints no year.

**Permissions.** None.

## builds

**Measures** which build tools are running, for how long, and how often builds
start, plus Xcode build logs and DerivedData size.

**Detection.** The libproc listing that `processes` uses, matched against the
`tools` map by whole process name. A trailing `*` is a prefix match
(`clang-*`). Substring matching is avoided because `clangd`, `gopls` and
build daemons such as `buildkitd` would read as builds. `java` is not matched
for gradle; it is too generic. A tool's seconds and starts come from a pure
state machine: a sample with at least one process credits the elapsed time
(capped at two intervals, so a sleep gap is not counted as build time) and a
tool that was absent in the previous sample counts a new build. A build already
running when Molly starts counts as one start.

**Xcode.** New `.xcactivitylog` files under `DerivedData/*/Logs/Build/`, by
modification time, counted once each. The cursor starts at process start, so
history is not backfilled. `du -sk` on DerivedData runs on a background queue
with a 20 second timeout, at most every `derivedDataSeconds` (default 1800).
Nothing is published when DerivedData is absent.

**Permissions.** None. Processes owned by other users and system daemons are
not visible to libproc and are not counted.

## tabs

**Measures** open window and tab counts per running browser: Safari, Google
Chrome, Brave, Arc, Edge and Vivaldi.

**Source.** `osascript -e 'tell application id "<bundle id>" to return (count of
windows) & (count of tabs of windows)'`. Bundle ids are checked against
`NSWorkspace.shared.runningApplications` first, so a browser that is not
running is never asked and never launched. Titles and URLs are never requested.
A browser that does not answer (permission denied, scripting unsupported) is
logged once and skipped; if every running browser fails the collector reports
itself unavailable.

**Doctor note.** The first run triggers one macOS Automation prompt per browser
("Molly wants to control Google Chrome"). Allow it, or grant it later in System
Settings > Privacy & Security > Automation, under the host process (your
terminal during development, `molly` or `Molly.app` under launchd). To be
asked again, reset it with:

```sh
tccutil reset AppleEvents
```

Append the host app's bundle id to limit the reset to that app (for example
`tccutil reset AppleEvents com.apple.Terminal`).

**Config.** `browsers` limits which browsers are asked; empty or absent means
all that are running.
