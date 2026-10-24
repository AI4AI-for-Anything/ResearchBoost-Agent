"""Acceptance on the final full check: PASS, speedup at least the minimum, and the judge unchanged since launch.

    python3 accept.py <task> <min speedup>

Reads $WORK/<task>/ws/runs/clawo-final/latest/check.json, written by judge.sh, and the judge digests run.sh
recorded in $WORK/<task>/clawo/judge.sha256. Exit 0 accepts.
"""
import hashlib
import json
import os
import sys
from pathlib import Path

task, min_speedup = sys.argv[1], float(sys.argv[2])
root = Path(os.environ['WORK']) / task
ws = root / 'ws'
check = ws / 'runs' / 'clawo-final' / 'latest' / 'check.json'
if not check.is_file():
    sys.exit(f'no {check}: the full check did not write a verdict')
res = json.loads(check.read_text())
status = res.get('status')
perf = res.get('performance') or {}
speedup = perf.get('speedup', perf.get('measured_speedup'))
print(f'status={status} speedup={speedup} evaluator_sha256={res.get("evaluator_sha256")}')

problems = []
if status != 'PASS':
    problems.append(f'status is {status}, not PASS')
if not isinstance(speedup, (int, float)) or speedup < min_speedup:
    problems.append(f'speedup {speedup} is below the minimum {min_speedup}')

# The judge must be byte for byte the one the run started with.
recorded = root / 'clawo' / 'judge.sha256'
if recorded.is_file():
    want = {}
    for line in recorded.read_text().splitlines():
        digest, _, name = line.partition('  ')
        want[name] = digest
    changed = [
        n for n, d in want.items()
        if not (ws / n).is_file() or hashlib.sha256((ws / n).read_bytes()).hexdigest() != d
    ]
    added = [
        str(f.relative_to(ws))
        for top in ('bench', 'numerics', 'task')
        for f in (ws / top).rglob('*')
        if f.is_file() and '__pycache__' not in f.parts and str(f.relative_to(ws)) not in want
    ]
    if changed or added:
        problems.append(f'the judge changed since launch: {", ".join(sorted(changed + added)[:10])}')
else:
    problems.append(f'no {recorded}: cannot tell whether the judge is the one the run started with')

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
