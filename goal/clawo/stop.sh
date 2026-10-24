#!/bin/bash
# Stop a goal-mode run: interrupts the running turn and pauses the goal. The thread stays on disk.
#   usage: stop.sh <task>
set -euo pipefail
TASK=$1; T=${WORK:?set WORK}/$TASK
"${CLAWO:-clawo}" workflow cancel "$(cat "$T/clawo/run_id")"
