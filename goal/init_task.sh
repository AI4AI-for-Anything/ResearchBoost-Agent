#!/bin/bash
# Lay out a new task from the owner's training code: the workspace, the agent's home, and a formulation directory
# the sandbox cannot see. What it does not do is the formulation itself (bench/, the adapter, GOAL.md, the
# frozen baseline): that is the formulating agent's job, following goal/templates/FORMULATOR_BRIEF.md.
#   usage: init_task.sh <task> <repo> [commit]
#   repo: a git URL, a local git repository, or a plain directory (snapshotted into a new repository)
#   commit: what the task is pinned to   (default: the repository's HEAD)
#
# Variables:
#   WORK   one directory per task: $WORK/<task>/{ws,home,logs}   (required)
#   CODE   the candidate's directory name in ws/   (default: the repository's name)
#
# Creates:
#   $WORK/<task>/ws/targets/reference   the code at <commit>, never changed
#   $WORK/<task>/ws/<CODE>              a clone of the same commit on branch `opt`: where the agent works
#   $WORK/<task>/ws/numerics            a frozen copy of ../numerics
#   $WORK/<task>/ws/{bench,task}        empty, for the judge and its frozen records
#   $WORK/<task>/{home,logs,assets}     the agent's home, watchdog logs, the task's environment/weights/data
#   $WORK/<task>/sandbox.env            sourced inside the sandbox: the task's Python first, offline switches
#   $WORK/<task>_formulation/           prep scripts and acceptance evidence, outside the sandbox
set -euo pipefail
TASK=${1:?usage: init_task.sh <task> <repo> [commit]}; REPO=${2:?usage: init_task.sh <task> <repo> [commit]}
COMMIT=${3:-}
HERE=$(cd "$(dirname "$0")" && pwd)
T=${WORK:?set WORK}/$TASK; W=$T/ws; F=$WORK/${TASK}_formulation
[ -e "$W" ] && { echo "$W already exists; pick another task name or remove it first"; exit 1; }
CODE=${CODE:-$(basename "${REPO%/}" .git)}
case $CODE in targets|bench|numerics|task|runs|home) echo "CODE=$CODE collides with a workspace directory; set CODE"; exit 1 ;; esac
mkdir -p "$W/targets" "$W/bench" "$W/task" "$T/home" "$T/logs" "$T/assets" "$F"

REF=$W/targets/reference
if [ -d "$REPO" ] && ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  # Not a repository: snapshot it, so the reference and the candidate share one commit.
  cp -a "$REPO/." "$REF/"
  git -C "$REF" init -q
  git -C "$REF" add -A
  git -C "$REF" -c user.name=reference -c user.email=reference@localhost commit -qm "reference snapshot of $REPO"
else
  if [ -d "$REPO" ] && [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    echo "note: $REPO has uncommitted changes; the task is pinned to a commit and does not include them"
  fi
  git clone -q "$REPO" "$REF"
fi
[ -n "$COMMIT" ] && git -C "$REF" checkout -q "$COMMIT"
HEAD=$(git -C "$REF" rev-parse HEAD)
git clone -q "$REF" "$W/$CODE"
git -C "$W/$CODE" checkout -q -b opt "$HEAD"
cp -r "$HERE/../numerics" "$W/numerics"
find "$W/numerics" -name __pycache__ -prune -exec rm -rf {} +

cat > "$T/sandbox.env" <<'EOF'
# Sourced inside the sandbox before every command (goal/sandbox/sandbox.sh). Training and judging run offline:
# put the task's Python environment, weights and data into $ASSETS first.
[ -d "$ASSETS/env/bin" ] && export PATH="$ASSETS/env/bin:$PATH"
export HF_HOME="$ASSETS/hf" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
EOF

cat > "$F/README.md" <<EOF
# $TASK formulation

Outside the sandbox: the optimizing agent never sees this directory.

- Source: $REPO
- Commit: $HEAD
- Candidate: ws/$CODE (branch opt)

Put here the prep scripts (environment, assets, baseline records, trajectory freeze, acceptance) and their
evidence, each listed in this file, as in tasks/dmd2/formulation/prep.
EOF

cat <<EOF
task $TASK pinned to $HEAD
  workspace    $W   (candidate: $CODE, branch opt)
  formulation  $F
Next (see goal/templates/FORMULATOR_BRIEF.md):
  1. build the environment and assets into $T/assets; write bench/ and the adapter, adapting tasks/dmd2/bench
  2. record the baseline twice (bitwise identical), freeze delta, pass the acceptance checks   (PREP=1 sandbox.sh)
  3. write ws/GOAL.md and ws/GOAL_LINE.txt; ENGINE=codex|claude goal/setup_home.sh $TASK
  4. MIN_SPEEDUP=<minimum> goal/clawo/run.sh $TASK "<gpus>", then supervise with goal/supervise/watch.sh
EOF
