#!/bin/bash
# Run sandbox.sh in the background and return at once, under a parent shell that waits for it.
#   usage: background.sh <log file> <task> "<gpu indices>" command ...
#
# Started as `setsid nohup sandbox.sh ... &` from a shell that exits right after (an ssh or `kubectl exec` session),
# a sandboxed command can die silently. Seen with bubblewrap 0.9 in a Kubernetes container (user-namespace mode): a
# process that started a child in its own session and waited for it (bench.py waiting on torchrun) was gone as soon
# as the child returned, with nothing in its log, while an orphaned torchrun had run its case to the end, which hides
# the failure. The same launch under a parent that waits for the sandbox runs to completion; that parent is what this
# script provides. It appends "exit <code> <time>" to the log when the sandbox ends.
set -euo pipefail
LOG=${1:?usage: background.sh <log file> <task> "<gpus>" command ...}; shift
[ $# -ge 3 ] || { echo 'usage: background.sh <log file> <task> "<gpus>" command ...'; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$(dirname "$LOG")"
setsid -f bash -c 'log=$1; shift; "$@" > "$log" 2>&1 < /dev/null; echo "exit $? $(date -u +%FT%TZ)" >> "$log"' \
  bash "$LOG" "$HERE/sandbox.sh" "$@" < /dev/null > /dev/null 2>&1
echo "started in the background; log: $LOG"
