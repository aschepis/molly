#!/bin/sh
# Fails when the iOS app's type catalog and the Mac's HealthType disagree on a raw name.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)

# Reads the contiguous `case name` / `case name = "raw"` lines at the top of an enum.
raw_names() {
  awk -v enum="$2" '
    $0 ~ "enum " enum "[ :]" { inside = 1; next }
    inside && /^[[:space:]]*case [A-Za-z0-9_]+( = "[^"]+")?[[:space:]]*$/ {
      line = $0
      if (match(line, /"[^"]+"/)) { print substr(line, RSTART + 1, RLENGTH - 2) }
      else { sub(/^[[:space:]]*case /, "", line); sub(/[[:space:]]*$/, "", line); print line }
      next
    }
    inside && /^[[:space:]]*$/ { exit }
  ' "$1"
}

mac=$(raw_names "$root/Sources/Molly/Health/HealthModel.swift" HealthType)
ios=$(raw_names "$root/ios/MollyHealthCore/Sources/MollyHealthCore/HealthCatalog.swift" MollyHealthType)

if [ -z "$mac" ] || [ -z "$ios" ]; then
  echo "check-health-types: could not read a type list" >&2
  exit 1
fi
if [ "$mac" != "$ios" ]; then
  echo "check-health-types: Mac HealthType and iOS MollyHealthType differ" >&2
  echo "mac:" >&2
  echo "$mac" >&2
  echo "ios:" >&2
  echo "$ios" >&2
  exit 1
fi
echo "check-health-types: $(echo "$mac" | wc -l | tr -d ' ') types match"
