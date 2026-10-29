# goal

Tooling for running one `/goal` session (Codex or Claude Code) on a task, unattended, inside a sandbox on a shared GPU host, on [claw-orchestrator](https://github.com/Enderfga/claw-orchestrator) (`clawo serve` on the host, started by `run.sh` when it is not running). Read [../docs/goal-mode.md](../docs/goal-mode.md) for how a run works and [../docs/run-a-task.md](../docs/run-a-task.md) for the steps.

| File | Role |
|---|---|
| `init_task.sh` | `init_task.sh <task> <repo> [commit]`: lay out a new task from the owner's code (a git URL, a local repository or a plain directory): reference, candidate on branch `opt`, a frozen copy of `numerics/`, `sandbox.env`, and `$WORK/<task>_formulation/` outside the sandbox |
| `codex.env.example` | Codex model access, when the host's own is not the one to use: copy to `codex.env` (git-ignored) and set `OPENAI_API_KEY`, `OPENAI_BASE_URL`, optionally `CODEX_MODEL` |
| `claude.env.example` | Claude Code model access, likewise: copy to `claude.env` (git-ignored) and set `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_AUTH_TOKEN`, optionally `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` |
| `codex/config.toml.example` | Codex configuration template: provider from `OPENAI_BASE_URL`, key from the `OPENAI_API_KEY` variable, approval `never`, sandbox `danger-full-access` (the outer sandbox is the boundary) |
| `setup_home.sh` | `[ENGINE=codex\|claude] setup_home.sh <task> [skill ...]`: finds the model access the host already has (env file, key or token in the shell, or the host's login), writes the engine's configuration into `$WORK/<task>/home`, copies the skill cards, and records the engine for `run.sh` |
| `sandbox/sandbox.sh` | `sandbox.sh <task> "<gpus>" [command ...]`: bubblewrap sandbox with only the assigned GPUs, the home hidden except `$WORK/<task>` and the engine CLIs, judge and `$ASSETS` read-only, a private `/tmp`, model access only from the env files; host network by default (`SANDBOX_NET=none` for fully offline commands). Without bubblewrap, or where no namespace can be created, a direct mode (`SANDBOX_MODE`) |
| `clawo/run.sh` | `MIN_SPEEDUP=… run.sh <task> "<gpus>"`: start the run on claw-orchestrator — a `/goal` from `ws/GOAL_LINE.txt` on the recorded engine inside the sandbox, followed by the final full check |
| `clawo/serve.sh` | Start `clawo serve` when it is not running (used by `run.sh` and `resume.sh`) |
| `clawo/judge.sh`, `clawo/accept.py` | The final check `run.sh` writes into the run: `bench.py check` on the candidate in `ws/FINAL.json`, in the sandbox; then PASS, speedup ≥ `MIN_SPEEDUP`, and the judge unchanged since launch |
| `clawo/status.sh`, `steer.sh`, `resume.sh`, `stop.sh` | The run's state and the goal's progress; a rule-level reminder into the running turn; reattach after a restart (starting `clawo serve` again); interrupt and pause |
| `supervise/watch.sh` | Supervisor watchdog: exits with one `EVENT` line when the run stops, the goal was resumed, a new round appears, the GPUs sit idle, a full check passes, or disk runs low |
| `templates/FORMULATOR_BRIEF.md` | Brief for the agent that formulates, launches and supervises a task: no-answer rule, data policy, environment, judge logic, acceptance checklist, supervision rules |

Variables used by all scripts: `WORK` (one directory per task), `ASSETS` (the task's environment, weights and data; default `$WORK/<task>/assets`), `LOCAL` (task-private local disk; default `/var/tmp/goal/<task>`), `ENGINE` (`codex` or `claude`; default: what `setup_home.sh` recorded).
