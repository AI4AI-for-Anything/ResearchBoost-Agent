#!/bin/bash
# Start one goal-mode run of <task> on claw-orchestrator: a Codex /goal on one codex-app thread inside the task's
# sandbox, judged by the task's frozen bench when Codex stops.
#   usage: run.sh <task> "<gpu indices>"
#
# Variables:
#   WORK                one directory per task: $WORK/<task>/{ws,home,logs}   (required)
#   MIN_SPEEDUP         the speedup the final judge must reach; the minimum stated in GOAL.md   (required)
#   BENCH               the bench entry point inside ws/   (default bench/bench.py; RAE uses bench/run.py)
#   CHECK_TIMEOUT_MIN   wall clock for the final full check   (default 360)
#   MAX_REPAIRS         times a failed final check is sent back to the same thread   (default 1)
#   TOKEN_BUDGET        tokens the goal may spend   (default: none)
#   GOAL_TIMEOUT_MIN    wall clock for one goal pass   (default: none)
#   CLAWO               the clawo CLI   (default clawo on PATH); `clawo serve` must be running on this host
#   ASSETS, LOCAL, CODEX_ENV, TOOLS, SANDBOX_NET, BWRAP   passed on to sandbox.sh when set
#
# Writes $WORK/<task>/clawo/{objective.txt,contract.json,judge.sha256,run_id}. Follow the run with status.sh.
set -euo pipefail
TASK=$1; GPUS=$2
HERE=$(cd "$(dirname "$0")" && pwd)
SANDBOX=$(cd "$HERE/../sandbox" && pwd)/sandbox.sh
T=${WORK:?set WORK}/$TASK; W=$T/ws; C=$T/clawo
: "${MIN_SPEEDUP:?set MIN_SPEEDUP to the minimum speedup in GOAL.md}"
CLAWO=${CLAWO:-clawo}
[ -f "$W/GOAL_LINE.txt" ] || { echo "no $W/GOAL_LINE.txt"; exit 1; }
[ -f "$T/home/.codex/config.toml" ] || { echo "no Codex home for $TASK: run goal/setup_home.sh $TASK first"; exit 1; }
"$CLAWO" workflow list --limit 1 >/dev/null || { echo "clawo serve is not reachable; start it first"; exit 1; }
mkdir -p "$C" "$T/logs"

# The objective is the task's own /goal line. One sentence is added: the harness, not the agent, runs the final
# full check, so it has to be told which candidate to judge.
python3 - "$W/GOAL_LINE.txt" "$C/objective.txt" <<'PY'
import sys
line = open(sys.argv[1]).read().strip()
if line.startswith('/goal'):
    line = line[len('/goal'):].strip()
line += (' When you stop, whether the goal is reached or you are wrapping up, write FINAL.json in the workspace'
         ' root as {"tree": "<candidate directory>", "config": "<switch file>"}, naming the version to be judged.'
         ' The harness then runs the full check on it with the frozen bench; that result is the verdict.')
open(sys.argv[2], 'w').write(line + '\n')
PY

# The judge as it is now, file by file: accept.py refuses a verdict from a judge that changed since launch.
(cd "$W" && find bench numerics task -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha256sum) \
  > "$C/judge.sha256"

# Codex and the checks are started by `clawo serve`, which does not have this shell's environment. Everything
# sandbox.sh reads is passed explicitly, in front of each command.
ENVP=(/usr/bin/env "WORK=$WORK")
for v in ASSETS LOCAL CODEX_ENV TOOLS SANDBOX_NET BWRAP; do
  if [ -n "${!v:-}" ]; then ENVP+=("$v=${!v}"); fi
done

# Both checks are written here, by the caller; the agent never sees or edits them.
python3 - "$C/contract.json" "$HERE" "$TASK" "$GPUS" "${BENCH:-bench/bench.py}" "$MIN_SPEEDUP" \
  "${CHECK_TIMEOUT_MIN:-360}" "${ENVP[@]}" <<'PY'
import json, sys
out, here, task, gpus, bench, min_speedup, minutes, *envp = sys.argv[1:]
json.dump({
    'id': f'{task}-final-check',
    # The bench is the only verdict; the runtime's test-file snapshot does not apply to a judged workspace.
    'protectTests': False,
    'checks': [
        {'id': 'full-check', 'type': 'command', 'cmd': envp[0],
         'args': [*envp[1:], f'{here}/judge.sh', task, gpus, bench], 'timeoutMs': int(float(minutes) * 60_000)},
        {'id': 'accept', 'type': 'command', 'cmd': envp[0],
         'args': [*envp[1:], 'python3', f'{here}/accept.py', task, min_speedup], 'timeoutMs': 60_000},
    ],
}, open(out, 'w'), indent=1)
PY

LAUNCH=()
for a in "${ENVP[@]}" "$SANDBOX" "$TASK" "$GPUS"; do LAUNCH+=(--launcher "$a"); done
args=(goal --objective-file "$C/objective.txt" --cwd "$W" "${LAUNCH[@]}"
      --sandbox danger-full-access --contract "$C/contract.json"
      --max-repairs "${MAX_REPAIRS:-1}" --json)
if [ -n "${TOKEN_BUDGET:-}" ]; then args+=(--token-budget "$TOKEN_BUDGET"); fi
if [ -n "${GOAL_TIMEOUT_MIN:-}" ]; then args+=(--goal-timeout "$GOAL_TIMEOUT_MIN"); fi
"$CLAWO" "${args[@]}" | tee "$C/start.json"
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runId"])' "$C/start.json" > "$C/run_id"
echo "run $(cat "$C/run_id"); follow it with goal/clawo/status.sh $TASK"
