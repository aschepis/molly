#!/usr/bin/env bash
# Builds packaging/AppIcon.icns from scripts/render-icon.swift using only
# tools that ship with macOS (swift, sips, iconutil).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/packaging/AppIcon.icns}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
swift "$here/scripts/render-icon.swift" "$work/icon-1024.png" 1024 >/dev/null

for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$out"
echo "wrote $out"
