#!/bin/bash
# Supervisor watchdog, run on the GPU host outside the sandbox. Exits with a one-line reason when something needs the
# supervisor's attention; otherwise exits after MAX seconds. The supervising agent runs it in the background and
# reacts to each EVENT line.
# usage: watch.sh <task> "<gpu indices>" [MAX seconds]
TASK=$1; GPUS=$2; MAX=${3:-6600}
W=${WORK:?set WORK}/$TASK
ID=$(cat "$W/clawo/run_id" 2>/dev/null) || { echo "EVENT no-run-recorded $(date +%T)"; exit 0; }
CLAWO=${CLAWO:-clawo}
start=$(date +%s)
rounds() { grep -c "^## " "$W/ws/WORK_LOG.md" 2>/dev/null || echo 0; }
# workflow state, goal status and resume attempts, from the run's checkpoint
state() {
  "$CLAWO" workflow show "$ID" --json 2>/dev/null | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception:
    print("unreachable - -"); sys.exit()
g = (r.get("nodes", {}).get("goal") or {}).get("data") or {}
print(r.get("state"), g.get("status", "-"), g.get("resumes", 0))'
}
r0=$(rounds); read -r _ _ resumes0 < <(state); idle=0
while :; do
  now=$(date +%s); el=$((now-start))
  read -r run goal resumes < <(state)
  if [ "$run" = unreachable ]; then echo "EVENT clawo-unreachable $(date +%T)"; exit 0; fi
  if [ "$run" != running ] && [ "$run" != verifying ]; then echo "EVENT run-$run goal=$goal $(date +%T)"; exit 0; fi
  if [ "$resumes" != "$resumes0" ]; then echo "EVENT goal-resumed $resumes (was $resumes0) goal=$goal $(date +%T)"; exit 0; fi
  r=$(rounds)
  if [ "$r" != "$r0" ]; then echo "EVENT new-work-log-round $r (was $r0) $(date +%T)"; exit 0; fi
  busy=0
  for g in $GPUS; do
    used=$(nvidia-smi -i "$g" --query-gpu=memory.used --format=csv,noheader,nounits)
    [ "${used:-0}" -gt 2000 ] && busy=$((busy+1))
  done
  if [ "$busy" = 0 ]; then idle=$((idle+1)); else idle=0; fi
  if [ "$idle" -ge 25 ]; then echo "EVENT gpus-idle-25min-no-new-round $(date +%T)"; exit 0; fi
  # a real goal hit: a full check (not --quick) with PASS and a speedup number
  hit=$(W=$W python3 - <<'PY'
import glob, json, os
for f in glob.glob(os.environ["W"] + "/ws/runs/*/*/check.json"):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if d.get("status") == "PASS" and not d.get("quick") and (d.get("performance") or {}).get("speedup"):
        print(f, (d["performance"]).get("speedup")); break
PY
)
  if [ -n "$hit" ]; then echo "EVENT full-check-PASS $hit $(date +%T)"; exit 0; fi
  free=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
  if [ "${free:-999}" -lt 100 ]; then echo "EVENT low-disk ${free}G $(date +%T)"; exit 0; fi
  if [ "$el" -ge "$MAX" ]; then echo "EVENT periodic-timeout $(date +%T)"; exit 0; fi
  sleep 60
done
