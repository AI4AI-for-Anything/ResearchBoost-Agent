# goal

Tooling for running one Codex `/goal` session on a task, unattended, inside a sandbox on a shared GPU host, on [claw-orchestrator](https://github.com/Enderfga/claw-orchestrator) (`clawo serve` running on the host). Read [../docs/goal-mode.md](../docs/goal-mode.md) for how a run works and [../docs/run-a-task.md](../docs/run-a-task.md) for the steps.

| File | Role |
|---|---|
| `codex.env.example` | Model access: copy to `codex.env` (git-ignored) and set `OPENAI_API_KEY`, `OPENAI_BASE_URL`, optionally `CODEX_MODEL` |
| `codex/config.toml.example` | Codex configuration template: provider from `OPENAI_BASE_URL`, key from the `OPENAI_API_KEY` variable, approval `never`, sandbox `danger-full-access` (the bubblewrap sandbox is the boundary) |
| `setup_home.sh` | `setup_home.sh <task> [skill ...]`: writes `$WORK/<task>/home/.codex/config.toml` and copies the skill cards; with `CODEX_AUTH_JSON` and no `codex.env`, uses a ChatGPT login instead of an endpoint |
| `sandbox/sandbox.sh` | `sandbox.sh <task> "<gpus>" [command ...]`: bubblewrap sandbox with only the assigned GPUs, the home hidden except `$WORK/<task>`, judge and `$ASSETS` read-only, a private `/tmp`; host network by default (`SANDBOX_NET=none` for fully offline commands) |
| `clawo/run.sh` | `MIN_SPEEDUP=… run.sh <task> "<gpus>"`: start the run on claw-orchestrator — a Codex `/goal` from `ws/GOAL_LINE.txt` inside the sandbox, followed by the final full check |
| `clawo/judge.sh`, `clawo/accept.py` | The final check `run.sh` writes into the run: `bench.py check` on the candidate in `ws/FINAL.json`, in the sandbox; then PASS, speedup ≥ `MIN_SPEEDUP`, and the judge unchanged since launch |
| `clawo/status.sh`, `steer.sh`, `resume.sh`, `stop.sh` | The run's state and the goal's progress; a rule-level reminder into the running turn; reattach after a restart; interrupt and pause |
| `supervise/watch.sh` | Supervisor watchdog: exits with one `EVENT` line when the run stops, the goal was resumed, a new round appears, the GPUs sit idle, a full check passes, or disk runs low |
| `templates/FORMULATOR_BRIEF.md` | Brief for the agent that formulates, launches and supervises a task: no-answer rule, data policy, environment, judge logic, acceptance checklist, supervision rules |

Variables used by all scripts: `WORK` (one directory per task), `ASSETS` (the task's environment, weights and data; default `$WORK/<task>/assets`), `LOCAL` (task-private local disk; default `/var/tmp/goal/<task>`).
