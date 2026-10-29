#!/bin/bash
# Pick a goal-mode run up after the host or `clawo serve` restarted (it is started again if it is not running).
# The goal continues on the same Codex thread or Claude Code session.
#   usage: resume.sh <task>
set -euo pipefail
TASK=$1; T=${WORK:?set WORK}/$TASK
"$(cd "$(dirname "$0")" && pwd)/serve.sh"
"${CLAWO:-clawo}" workflow resume "$(cat "$T/clawo/run_id")"
