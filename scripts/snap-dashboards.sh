#!/usr/bin/env bash
# Renders every provisioned Grafana dashboard to docs/screenshots/dashboard-<uid>.png.
# usage: scripts/snap-dashboards.sh [range]   (default 24h; e.g. 6h, 7d)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
range="${1:-24h}"
grafana="${GRAFANA_URL:-http://localhost:3030}"
user="${GF_SECURITY_ADMIN_USER:-admin}"
password="${GF_SECURITY_ADMIN_PASSWORD:-admin}"
width=1600
out="$root/docs/screenshots"

# deploy/.env is where compose reads the admin password from.
if [ -z "${GF_SECURITY_ADMIN_PASSWORD:-}" ] && [ -f "$root/deploy/.env" ]; then
  from_env="$(grep -E '^GF_SECURITY_ADMIN_PASSWORD=' "$root/deploy/.env" | tail -1 | cut -d= -f2- || true)"
  password="${from_env:-$password}"
fi

# Compose bind-mounts ./data, so running it from a worktree would move the
# shared containers' databases under that worktree and lose them when it goes.
if [ -f "$root/.git" ]; then
  echo "refusing to run docker compose from a worktree ($root); run from the main checkout" >&2
  exit 2
fi
(cd "$root/deploy" && docker compose --profile render up -d grafana renderer)

for _ in $(seq 1 60); do
  curl -fsS "$grafana/api/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$grafana/api/health" >/dev/null || { echo "Grafana not reachable at $grafana" >&2; exit 1; }

mkdir -p "$out"
status=0
for file in "$root"/deploy/grafana/dashboards/*.json; do
  uid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uid"])' "$file")"
  # One grid unit is 30px plus 8px margin; the extra covers the kiosk header.
  height="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(max(p["gridPos"]["y"]+p["gridPos"]["h"] for p in d["panels"])*38+120)' "$file")"
  target="$out/dashboard-$uid.png"
  url="$grafana/render/d/$uid?width=$width&height=$height&kiosk&from=now-$range&to=now&timeout=90"
  if curl -fsS --retry 3 --retry-all-errors --retry-delay 10 -u "$user:$password" --max-time 150 -o "$target" "$url"; then
    echo "wrote $target"
  else
    echo "failed to render $uid" >&2
    rm -f "$target"
    status=1
  fi
done
exit $status
