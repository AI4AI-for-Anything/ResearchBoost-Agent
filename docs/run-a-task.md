# Run a task

Step-by-step instructions for the agent (or person) that prepares a task, starts the optimizing session (Codex or Claude Code) and supervises it. These steps are for the tasks in [`tasks/`](../tasks); for the owner's own code, start from [`goal/init_task.sh`](../goal/init_task.sh) and section 0.5 of [`goal/templates/FORMULATOR_BRIEF.md`](../goal/templates/FORMULATOR_BRIEF.md), which the [README quick start](../README.md#quick-start) hands to the agent. Background: [goal-mode.md](goal-mode.md) (how a run works), [judge.md](judge.md) (the verdict), [methodology.md](methodology.md) (the whole process).

## 1. Variables

| Variable | Meaning |
|---|---|
| `WORK` | One directory per task: `$WORK/<task>/{ws,home,logs}`. Workspace names used here: `llava`, `dmd`, `rae`, `self-forcing`. |
| `ASSETS` | The task's Python environment, weights and data. Read-only inside the sandbox. Default `$WORK/<task>/assets`. |
| `LOCAL` | Task-private local disk; `$LOCAL/tmp` is the sandbox's `/tmp`. Default `/var/tmp/goal/<task>`. |
| `SANDBOX` | Path of `goal/sandbox/sandbox.sh`, needed by the prep scripts that start sandboxed stages. |
| `HF_ENDPOINT` | Optional Hugging Face mirror for the download scripts (default `https://huggingface.co`). |
| `ENGINE` | `codex` or `claude`: who runs the goal. `setup_home.sh` picks one by default (Codex when Codex model access is found) and records it for `run.sh`. |
| `SANDBOX_MODE` | `auto` (default): bubblewrap where it works, else the direct mode; `bwrap` refuses the fallback. See [goal-mode.md](goal-mode.md#sandbox-goalsandboxsandboxsh). |

The host needs the `codex` or `claude` CLI; the sandbox finds them on PATH, also under the home directory it hides (`TOOLS` can point at a directory holding them instead). `bwrap` (bubblewrap) isolates the agent when the host has it. The run is driven by [claw-orchestrator](https://github.com/Enderfga/claw-orchestrator) on the same host (`npm install -g @enderfga/claw-orchestrator`; 7.13.0 or later for Codex, a version whose `clawo goal --help` lists `--engine` for Claude Code); `run.sh` and `resume.sh` start `clawo serve` when it is not running (log in `$WORK/clawo-serve.log`). `run.sh` passes `ASSETS`, `LOCAL`, `CODEX_ENV`, `CLAUDE_ENV`, `TOOLS`, `SANDBOX_MODE`, `SANDBOX_NET` and `BWRAP` on to the sandbox when they are set, because `clawo serve` does not share your shell's environment.

## 2. Set up the task workspace

Take `<task>` from `tasks/` and follow its `GOAL.md` for the upstream commit and the candidate directory name.

```bash
T=$WORK/<task>; mkdir -p $T/ws $T/logs
git clone <upstream> $T/ws/targets/reference && git -C $T/ws/targets/reference checkout <commit>
git clone $T/ws/targets/reference $T/ws/<code> && git -C $T/ws/<code> checkout -b opt
cp -r tasks/<task>/bench tasks/<task>/numerics tasks/<task>/task $T/ws/
cp tasks/<task>/GOAL.md $T/ws/        # and GOAL_LINE.txt: the /goal line typed at launch
cp -r tasks/<task>/formulation/prep $T/prep   # formulation only; moved out before launch (step 4)
```

Build the environment and the assets with the task's prep scripts. Each prep directory has a README listing its scripts and the variables they need; for DMD2, for example:

```bash
export ASSETS=... MINICONDA=...
bash $T/prep/fetch_assets.sh && bash $T/prep/install_env.sh && bash $T/prep/build_fixture.sh
```

Write `$T/sandbox.env` (sourced inside the sandbox before every command): put `$ASSETS/env/bin` first on `PATH` and set `HF_HOME`, `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`, so training and judging never touch the network.

Then the agent's home: the engine's configuration, model access and skill cards. `setup_home.sh` finds the model access the host already has (`goal/codex.env` or `goal/claude.env`, the API key or token in your shell, or the host's Codex / Claude Code login; the order is in its header).

```bash
goal/setup_home.sh <task>                   # all cards in skills/, or name them:
goal/setup_home.sh <task> train-opt-tiered-profiling train-opt-measurement train-opt-numerics-validation
ENGINE=claude goal/setup_home.sh <task>     # run the goal on Claude Code
```

Baseline records, baseline trajectories and frozen input digests are machine-specific and not stored in this repository. Re-create them inside the sandbox with `PREP=1`: record the baseline twice and confirm the two recordings are bitwise identical, record the baseline trajectories, freeze δ, and rewrite `task/formulation.json` (the prep README names the script for each step: `formulate.sh` and `freeze_inputs.py` for LLaVA, `bench.py record` and `freeze_traj.sh` for DMD2).

<a id="3-verify-the-judge-on-the-reference"></a>

## 3. Verify the judge on the baseline

Run inside the sandbox, from the workspace (`ws/` is the working directory there). RAE's bench is `bench/run.py` instead of `bench/bench.py`.

Check a copy of the reference (the `reference` path in `bench/bench.json`), never the reference itself. A check links the task's assets into the tree it checks (for Self-Forcing, `wan_models/`, `checkpoints/` and a prompt file), and every later copy of the reference (the full check's own reference run, the acceptance trees) would turn those links into plain files, which the bench then refuses.

```bash
S=goal/sandbox/sandbox.sh
cp -r $T/ws/targets/reference $T/ws/targets/verify
PREP=1 $S <task> "0 1 2 3" python bench/bench.py check --tree targets/verify --out runs/verify/quick --quick
PREP=1 $S <task> "0 1 2 3" python bench/bench.py check --tree targets/verify --out runs/verify/full
```

Expected in `runs/verify/*/check.json`:
- quick: `status` PASS, bitwise (gates 0 and 2);
- full: `status` UNAVAILABLE with verdict `no_benefit` and a measured speedup close to 1.00×. The unmodified baseline is not faster than itself, and gate 1 rejects it before any precision gate.

Then run the task's acceptance script (`accept.sh` for DMD2, `acceptance.sh` and `control_arm.sh` for LLaVA, `accept_quick.sh` for Self-Forcing). Every known-bad tree must fail the gate it targets, the control arm (learning rate × 1.02) must be INCORRECT at the statistical gate, and `python -m numerics selftest` must pass. Do not launch until all of them match.

## 4. Launch

Move the formulation material where the sandbox cannot see it, then start the run with the minimum speedup from `GOAL.md` (on the engine `setup_home.sh` recorded; `ENGINE=` overrides it):

```bash
mv $WORK/<task>/prep $WORK/<task>_formulation
MIN_SPEEDUP=2.0 goal/clawo/run.sh <task> "0 1 2 3"
```

`run.sh` writes the objective and the final check under `$WORK/<task>/clawo/`, starts the agent in the sandbox on a `/goal` built from `ws/GOAL_LINE.txt`, and records the run id. Check with `goal/clawo/status.sh <task>` that the goal is `active` and, after a few minutes, that the agent read `GOAL.md` and started with a profile (`ws/runs/`, `ws/WORK_LOG.md`).

Supervise from the host:

```bash
goal/supervise/watch.sh <task> "0 1 2 3" &          # exits with one EVENT line when something needs a look
goal/clawo/status.sh <task>                          # goal status, tokens, time, resume attempts, rounds, last check
goal/clawo/steer.sh <task> "Log this round in WORK_LOG.md before starting the next one."
```

A usage limit or a stalled goal is resumed by `clawo` on its own (see [goal-mode.md](goal-mode.md#run-resume-supervise-goalclawo)). After a host restart, run `goal/clawo/resume.sh <task>`: it starts `clawo serve` again, and the goal continues on the same thread. When the agent stops, `clawo` runs the full check on the candidate the agent named in `ws/FINAL.json`; `status.sh` then shows the run as `completed` (accepted) or `failed`, and the verdict is in `ws/runs/clawo-final/latest/check.json`.

Supervision rules are in [goal-mode.md](goal-mode.md#supervision-rules): intervene on rules and facts only, never on optimization direction.

## 5. Where results land

| Path | Content |
|---|---|
| `$WORK/<task>/ws/WORK_LOG.md` | One entry per round: profile findings, the change, `time` result, `check` result |
| `$WORK/<task>/ws/runs/<round>/.../check.json` | The verdict: `status`, `correctness`, `performance.speedup`, fingerprints, `cost.gpu_hours` |
| `$WORK/<task>/ws/<code>/` branch `opt` | The candidate, one commit per change; the final switch file is named in the WORK_LOG summary |
| `$WORK/<task>/clawo/` | The run: objective, final-check contract, judge digests at launch, run id |
| `$WORK/<task>/ws/runs/clawo-final/` | The harness's final full check; `latest/check.json` is the verdict |
| `$WORK/<task>/logs/` | Watchdog output |
| `$WORK/<task>/home/.codex/sessions/` | Codex rollouts of the run's thread (Claude Code: `home/.claude/projects/`) |

A result counts only if a full `check` (not `--quick`) says PASS. Before publishing it, run the real workload end to end (see [methodology.md](methodology.md#3-wrap-up-and-real-validation)).
