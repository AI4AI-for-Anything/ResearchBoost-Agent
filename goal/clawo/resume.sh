#!/bin/bash
# Pick a goal-mode run up after the host or `clawo serve` restarted. The goal continues on the same Codex thread.
#   usage: resume.sh <task>
set -euo pipefail
TASK=$1; T=${WORK:?set WORK}/$TASK
"${CLAWO:-clawo}" workflow resume "$(cat "$T/clawo/run_id")"
