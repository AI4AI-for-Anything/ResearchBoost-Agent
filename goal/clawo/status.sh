#!/bin/bash
# One look at a goal-mode run: the workflow and the goal's progress, the rounds in WORK_LOG.md, the last check.
#   usage: status.sh <task>
set -uo pipefail
TASK=$1; T=${WORK:?set WORK}/$TASK
ID=$(cat "$T/clawo/run_id" 2>/dev/null) || { echo "no run recorded for $TASK"; exit 1; }
"${CLAWO:-clawo}" workflow show "$ID"
echo "WORK_LOG rounds: $(grep -c '^## ' "$T/ws/WORK_LOG.md" 2>/dev/null || echo 0)"
last=$(find "$T/ws/runs" -mindepth 3 -maxdepth 3 -name check.json -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
[ -n "$last" ] && python3 - "$last" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
perf = d.get('performance') or {}
print(f"last check: {sys.argv[1]}: {d.get('status')} speedup={perf.get('speedup')} quick={d.get('quick', False)}")
PY
exit 0
