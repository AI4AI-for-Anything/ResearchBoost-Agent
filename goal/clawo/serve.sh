#!/bin/bash
# Make sure `clawo serve` is running on this host: return at once when it answers, otherwise start it detached
# (log: $WORK/clawo-serve.log) and wait until it answers.
#   usage: serve.sh
#   CLAWO   the clawo CLI   (default clawo on PATH)
set -euo pipefail
CLAWO=${CLAWO:-clawo}
command -v "$CLAWO" >/dev/null || { echo "no $CLAWO: npm install -g @enderfga/claw-orchestrator"; exit 1; }
"$CLAWO" workflow list --limit 1 >/dev/null 2>&1 && exit 0
LOG=${WORK:?set WORK}/clawo-serve.log
# `clawo serve` reaps sessions idle for OPENCLAW_SERVE_TTL_MINUTES (its default: 60), and a goal turn does not
# refresh that activity time: an hours-long goal was killed and resumed every hour, each time spending one of its
# 20 resumes with a doubling backoff. Keep sessions for as long as a goal can run.
export OPENCLAW_SERVE_TTL_MINUTES=${OPENCLAW_SERVE_TTL_MINUTES:-100000}
mkdir -p "$WORK"
# its own session, so it outlives this shell and the agent that ran it
if command -v setsid >/dev/null; then
  setsid nohup "$CLAWO" serve >> "$LOG" 2>&1 < /dev/null &
else
  nohup "$CLAWO" serve >> "$LOG" 2>&1 < /dev/null &
fi
for _ in $(seq 1 30); do
  sleep 1
  "$CLAWO" workflow list --limit 1 >/dev/null 2>&1 && { echo "started clawo serve (log: $LOG)"; exit 0; }
done
echo "clawo serve did not come up within 30 s; see $LOG"; exit 1
