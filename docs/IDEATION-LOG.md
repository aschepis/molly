# Ideation log

After the MVP, three ideation loops each picked features from
`docs/ROADMAP.md`, built them with up to four parallel agents, and recorded
the outcome here.

## Loop 1: live events and deeper signals (2026-11-03)

Theme: the MVP polls files and system APIs. This loop adds sources that are
event-driven or that explain the texture of a day.

Picked:
1. **Claude Code hooks** (`molly hook` + `POST /event`). Zero-lag tool-call
   and session counters, plus a generic event endpoint any script can use.
2. **Input intensity, clipboard rhythm, connected hardware.** Three small
   collectors: key/click counts per minute (opt-in, Accessibility), copy
   frequency and content type (never content), displays/USB/audio devices.
3. **Flow detection and context-switch ledger** as Prometheus recording rules,
   plus a weekly review dashboard and agent-ROI panels.
4. **Sleep/boot forensics and build activity.** `pmset -g log` and `last
   reboot` parsed into counters so gaps are explainable; compiler/build
   processes and Xcode DerivedData logs as build metrics; browser tab counts
   (opt-in AppleScript).

Outcome: (pending)
