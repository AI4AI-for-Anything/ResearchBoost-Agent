#!/bin/bash
# The final full check, run by claw-orchestrator after the goal stops. Reads ws/FINAL.json and runs the frozen
# bench on that candidate inside the task's sandbox, with the same GPUs the agent had.
#   usage: judge.sh <task> "<gpu indices>" <bench entry point>
set -uo pipefail
TASK=$1; GPUS=$2; BENCH=$3
HERE=$(cd "$(dirname "$0")" && pwd)
SANDBOX=$(cd "$HERE/../sandbox" && pwd)/sandbox.sh
W=${WORK:?set WORK}/$TASK/ws
F=$W/FINAL.json
[ -f "$F" ] || { echo "no FINAL.json in the workspace: the agent did not name a candidate"; exit 2; }
read -r TREE CONFIG < <(python3 - "$F" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('tree') or '', d.get('config') or '')
PY
)
[ -n "$TREE" ] || { echo "FINAL.json names no tree"; exit 2; }
OUT=runs/clawo-final/$(date +%m%d_%H%M%S)
mkdir -p "$W/runs/clawo-final"
ln -sfn "$(basename "$OUT")" "$W/runs/clawo-final/latest"
args=(python "$BENCH" check --tree "$TREE" --out "$OUT")
[ -n "$CONFIG" ] && args+=(--config "$CONFIG")
echo "judging tree=$TREE config=${CONFIG:-none} -> $OUT"
"$SANDBOX" "$TASK" "$GPUS" "${args[@]}"
