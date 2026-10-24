#!/bin/bash
# Send a rule-level reminder into the running turn (never optimization advice; see docs/goal-mode.md).
#   usage: steer.sh <task> "<text>"
set -euo pipefail
TASK=$1; TEXT=$2; T=${WORK:?set WORK}/$TASK
"${CLAWO:-clawo}" workflow steer "$(cat "$T/clawo/run_id")" "$TEXT"
