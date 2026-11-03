#!/usr/bin/env bash
# Opens each Settings tab in the running Molly daemon and saves a PNG of the window.
# Uses screencapture; when the terminal lacks Screen Recording permission it falls
# back to the daemon rendering its own window (molly settings --snapshot).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
molly="${MOLLY_BIN:-/Applications/Molly.app/Contents/MacOS/molly}"
out="$root/docs/screenshots"
tabs=(collectors privacy server agents maintenance)
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

[ -x "$molly" ] || { echo "molly binary not found at $molly (set MOLLY_BIN)" >&2; exit 1; }
swiftc -O "$root/scripts/window-id.swift" -o "$scratch/window-id"
mkdir -p "$out"

snap_in_process() {
  local tab="$1" target="$2"
  rm -f "$target"
  "$molly" settings "$tab" --snapshot "$target"
  for _ in $(seq 1 20); do
    [ -s "$target" ] && return 0
    sleep 0.25
  done
  return 1
}

for tab in "${tabs[@]}"; do
  target="$out/settings-$tab.png"
  "$molly" settings "$tab"
  id=""
  for _ in $(seq 1 20); do
    id="$("$scratch/window-id" 2>/dev/null || true)"
    [ -n "$id" ] && break
    sleep 0.25
  done
  [ -n "$id" ] || { echo "Settings window did not appear for tab $tab" >&2; exit 1; }
  sleep 0.5 # let SwiftUI finish switching tabs
  if ! screencapture -o -x -l "$id" "$target" 2>/dev/null; then
    snap_in_process "$tab" "$target" || { echo "could not capture tab $tab" >&2; exit 1; }
  fi
  echo "wrote $target"
done
"$molly" settings --close
