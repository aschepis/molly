#!/usr/bin/env bash
# Reports molly_* metric names used by dashboards and rules that are absent from a metrics list.
# usage: scripts/check-dashboards.sh <metrics.txt|docs/METRICS-PLAN.md>
set -euo pipefail

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 <metrics.txt>" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 -I - "$1" "$root/deploy/grafana/dashboards" "$root/deploy/prometheus/rules" <<'PY'
import glob
import os
import re
import sys

metrics_file, dashboards_dir, rules_dir = sys.argv[1:4]
token = re.compile(r"molly_[a-z0-9_:]+")


def tokens(text):
    return {t.rstrip(":") for t in token.findall(text)}


def expand_braces(text):
    """The plan abbreviates families as molly_prefix_{a,b}; expand them to full names."""
    def expand(match):
        return " ".join(match.group(1) + part.strip() for part in match.group(2).split(","))
    return re.sub(r"(molly_[a-z0-9_]*_)\{([a-z0-9_, ]+)\}", expand, text)


known = tokens(expand_braces(open(metrics_file, encoding="utf-8").read()))

recorded = set()
rule_files = sorted(glob.glob(os.path.join(rules_dir, "*.yml")))
for path in rule_files:
    for line in open(path, encoding="utf-8"):
        match = re.match(r"\s*-?\s*record:\s*(\S+)", line)
        if match:
            recorded.add(match.group(1))

used = {}
for path in sorted(glob.glob(os.path.join(dashboards_dir, "*.json"))) + rule_files:
    for t in tokens(open(path, encoding="utf-8").read()):
        used.setdefault(t, set()).add(os.path.basename(path))

missing = {t: files for t, files in used.items()
           if ":" not in t and t not in known}
undefined_recordings = {t: files for t, files in used.items()
                        if ":" in t and t not in recorded}

for t in sorted(missing):
    print("missing metric: %s (%s)" % (t, ", ".join(sorted(missing[t]))))
for t in sorted(undefined_recordings):
    print("undefined recording rule: %s (%s)" % (t, ", ".join(sorted(undefined_recordings[t]))))

print("%d metric names checked, %d missing, %d undefined recording rules"
      % (len(used), len(missing), len(undefined_recordings)))
sys.exit(1 if missing or undefined_recordings else 0)
PY
