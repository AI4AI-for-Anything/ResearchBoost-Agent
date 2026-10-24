# Formulation and supervision brief (for the agent in charge of one task)

You are responsible for **formulating a training-optimization task, launching a Codex goal on it, and supervising it**. This file is the brief shared by all tasks; the task-specific parts (upstream repository and commit, target and minimum, assigned GPUs) are in your prompt. Read [`../../docs/run-a-task.md`](../../docs/run-a-task.md) and [`../../docs/judge.md`](../../docs/judge.md) first.

## 0. Hard rules

- **Never show Codex the answer.** Codex may see only: the upstream code, the judge you write (`bench/`, `numerics/`), `GOAL.md`, the frozen reference artifacts, and the skill cards placed in its home. Do not put other tasks' results, candidate code, WORK_LOGs, switch names or speedups into the workspace, and do not give concrete optimization advice in `GOAL.md` or in supervision messages.
- **Shared machines.** Use only the GPUs and directories assigned to you; do not touch other users' directories or processes. When running on GPUs outside the sandbox during formulation, restrict yourself to your GPUs with `CUDA_VISIBLE_DEVICES`.
- **Delete only what you created.** Every `rm -rf` uses an absolute path, and nothing outside `$WORK/<task>` and `$LOCAL` is ever deleted.
- **Data.** Use public code, public weights and public data only. Private data stays on the infrastructure it belongs to: do not copy it out, stream it out, create presigned links, or carry out file lists or per-file results.
- Do not name colleagues in reports or documents.
- Wait for long operations with a background loop that checks for the condition, not with a foreground sleep.
- Commit with the identity the repository owner specifies, set only in the candidate repository's local configuration.

## 1. Environment

- Variables: `WORK` (one directory per task: `$WORK/<task>/{ws,home,logs}`), `ASSETS` (this task's environment, weights and data, read-only in the sandbox), `LOCAL` (task-private local disk; `$LOCAL/tmp` is the sandbox's `/tmp`). Environment, weights and data go into `$ASSETS`; write the downloads and the environment build as scripts in the task's `prep/`, so they can be rerun after the machine is rebuilt.
- Sandbox: [`../sandbox/sandbox.sh`](../sandbox/sandbox.sh) `<task> "<gpus>" [command ...]`; without a command it starts the Codex TUI (for a look by hand; runs go through `clawo`). Inside the sandbox:
  - only the assigned GPUs are visible (renumbered 0..N-1);
  - the home directory is hidden except `$WORK/<task>` (writable); `$ASSETS` is read-only;
  - by default (without `PREP=1`) `ws/bench`, `ws/numerics`, `ws/task` and `ws/targets` are read-only; use `PREP=1` during formulation;
  - if `$WORK/<task>/sandbox.env` exists, it is sourced before the command (set PATH, `HF_HOME`, `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1` and so on there);
  - the network is kept by default (Codex has to reach the model endpoint). Training and judging must run offline: put weights, data and wheels into `$ASSETS` beforehand.
- Model: the owner fills in `OPENAI_API_KEY` and `OPENAI_BASE_URL` (optionally `CODEX_MODEL`) in `goal/codex.env`. [`../setup_home.sh`](../setup_home.sh) `<task> [skill ...]` writes `$WORK/<task>/home/.codex/config.toml` from it (approval never, sandbox danger-full-access: the outer bwrap is the boundary) and places the skill cards in `$HOME/.codex/skills/`.
- Check: `sandbox.sh <task> "<gpus>" codex exec --skip-git-repo-check "Reply with exactly: PONG" < /dev/null` should return PONG.

## 2. The judge: follow the frozen judge's logic exactly

Copy the generic judge code ([`../../numerics`](../../numerics)) **as is; do not rewrite it**. The only task-specific part is an adapter (a subclass of `numerics.adapter.Adapter`: build the real training objects → restore state → feed fixed inputs → call the task's own code to run **one real training step**; gradients, parameter updates, optimizer state, EMA, buffers, counters, RNG, dtypes and cross-rank relations are all captured by the generic hooks in record). For `bench.py`, follow the tasks' `bench/` directories ([`../../tasks/dmd2/bench`](../../tasks/dmd2/bench) is the most complete). The overall rule: no speedup means rejection; bitwise identical means acceptance; when bitwise is not possible, compare statistics of training trajectories a few hundred steps long.

Gate by gate (stop at the first failure):

0. **Structure**: everything in the candidate's `main()` outside the per-step loop body, and `parse_args()`, must match the reference AST (the adapter reproduces that setup); the first few batches from the data loader must be bitwise identical to the reference. Failure → ERROR / INCORRECT.
1. **Benefit**: reference → candidate → reference, each a fresh process running the real entry point with a cold compile cache; every run's fingerprint (command, switches, math mode, GPUs, library versions) must match the first reference run, otherwise ERROR (not comparable). A speedup that does not exceed `max(1.02, 1 + 2 × relative gap between the two reference runs)` → UNAVAILABLE (no_benefit, rejected outright, precision not evaluated). A run whose window range exceeds the threshold → INVALID, remeasure.
2. **Bitwise**: record short cases in deterministic mode (one case per training phase, 1–2 steps each).
   - **Every exact item must hold, otherwise INCORRECT**: phase, RNG fingerprint before and after each step, call counts, the invariants the adapter declares (including the learning rate), tensor names and shapes, all values finite, cross-rank pattern (according to the adapter's sync declaration).
   - All recorded tensors (`loss/`, `out/`, `grad/`, `delta/`, `optim/`, `ema/`, `buffer/`) bitwise identical → **PASS (N0)**.
   - The reference must be bitwise identical to itself across two runs in deterministic mode (verified during formulation).
3. **Statistical**: only when not bitwise identical. With deterministic kernels, run paired short training trajectories with the frozen seeds (a compressed schedule that covers every training phase, tens to a few hundred steps).
   - Endpoint = the mean of one loss over a window at the end of each phase (averaged across ranks).
   - δ = 2 × the reference's own seed-to-seed standard deviation (6 reference seeds, **frozen before any candidate is seen**, `numerics traj-freeze --k 2`).
   - Mean paired difference m and paired t-test p: start with 3 seeds; any endpoint with |m| > δ and p < 0.05 → INCORRECT, all endpoints |m| ≤ δ → PASS, otherwise extend to 6; at 6 seeds any endpoint with |m| > δ → INCORRECT.
4. **Tier**: N0 = everything bitwise identical with the same dtypes and math modes; N2 = the dtype or math mode of any tensor or op output changed (TF32, low-precision reductions, SDPA backend); N1 otherwise; N3 and above go to a human.
5. Per-tensor tolerance gates and fp64 arbitration are **diagnostic output only** and do not enter the verdict.
6. Pitfalls: dtype tracing (a TorchDispatchMode) makes compile fall back to eager, so formal recordings never enable dtype tracing; with nondeterministic kernels two runs with the same seed can differ by 5σ, so trajectories must be recorded in deterministic mode; record each reference seed in its own process (recording them in one process underestimates σ).

## 3. Formulation (finished and frozen before Codex starts)

Workspace `$WORK/<task>/ws/`:
- `targets/reference/`: the upstream commit, unchanged (a git repository; record HEAD).
- `<candidate directory>/`: a clone of the same commit on branch `opt`, where Codex makes its changes.
- `bench/bench.py`: subcommands `check [--quick] [--skip-timing]`, `time`, `profile`, `baseline`. Switch files have the format `{"environment": {...}}`. The bench takes the GPU lock itself (`/tmp/<task>_gpu.lock` in the sandbox; `GOAL.md` tells Codex to wrap other GPU commands in `flock`), uses a new compile cache directory per run, checks that the GPUs are idle, kills the process group on timeout, records fingerprints, and checks the hashes of the frozen inputs and the source digest at both the start and the end.
- `task/`: the frozen reference artifacts (reference timings, short recordings, reference trajectories, `formulation.json`), readable by Codex.
- `numerics/`: the frozen copy of the generic comparison code.

Acceptance (everything must match before Codex is launched):
- (a) the unmodified candidate → bitwise PASS (`check --quick`), and the full `check` reports no_benefit;
- (b) a changed entry point or setup → ERROR;
- (c) a change known to alter semantics (drop one loss term's gradient, skip a step) → INCORRECT;
- (d) a mathematically equivalent reordering → passes the statistical gate;
- (e) control arm: a copy of the reference with only the learning rate multiplied by 1.02 → INCORRECT at the statistical gate;
- `numerics selftest` passes; the two reference timings differ very little (preferably <1%).

Write the baseline numbers (per-phase times, memory, top profile hotspots) into `task/baseline.md`.

Workload = **the upstream training recipe, unchanged**. With fewer GPUs than upstream, keep **the per-GPU load identical to upstream** (per-GPU batch, sequence length, precision, parallelism strategy and ZeRO stage as upstream), use gradient accumulation to match the global batch if needed, and state this in `GOAL.md`. Timing uses a small fixed batch of data (a fixture), not full training. Precision floor: the baseline is the upstream recipe's precision; do not lower training to FP8/INT8; do not remove fp32 master weights or optimizer state (if upstream has them); local precision changes are allowed but must pass gates 2 and 3.

Keep formulation scripts and acceptance evidence where the sandbox cannot see them (for example `$WORK/<task>_formulation/`), not under `$WORK/<task>`.

## 4. GOAL.md and launch

Use [`../../tasks/dmd2/GOAL.md`](../../tasks/dmd2/GOAL.md) as the template for `GOAL.md`. It must contain:
- **The goal** and **the single criterion**: `status == PASS` and `performance.speedup ≥ target` from `python bench/bench.py check --tree <candidate> --config <switch file> --out <dir>`; if a profile shows the target cannot be reached within the rules, `≥ minimum` is also acceptable for wrapping up, with an explanation in the WORK_LOG of why the remaining hotspots cannot be addressed.
- How each gate decides, and roughly how long each command takes (screen with `time` and `check --quick` day to day; run the full check once confident).
- **Every round starts with a profile before any change**, and **timing only through bench.py**.
- **Pace: at most 30 minutes per round** (counted from taking the GPU lock: profile → change one hotspot → re-time with `time` → log the round in WORK_LOG; failures and no-gain rounds are logged too). The full check does not count towards a round.
- Every round appends to `WORK_LOG.md`: profile findings, the change, the time result, the check result (if run).
- Constraints: training semantics must not change (data and order, batch, learning rate and optimizer, loss, optimizer steps per step); the code must not behave differently depending on whether it is being timed or judged; read-only paths, no new packages; the precision floor.
- The environment, the list of skills ("priors summarized from other training-optimization tasks; re-verify them on this task before treating them as conclusions"), and the wrap-up requirements (commit each change separately on branch `opt` of the candidate repository; a summary at the end of the WORK_LOG: final switch file, final check path and result, breakdown of the gains, directions that did not work and why).

Launch: write the `/goal` line into `ws/GOAL_LINE.txt` (see [`../../tasks/dmd2/GOAL_LINE.txt`](../../tasks/dmd2/GOAL_LINE.txt)), make sure `clawo serve` is running on the host, then run `MIN_SPEEDUP=<minimum> ` [`../clawo/run.sh`](../clawo/run.sh) `<task> "<gpus>"`. The final full check is part of the run: when Codex stops, `clawo` judges the candidate the agent names in `ws/FINAL.json`. Afterwards confirm with [`../clawo/status.sh`](../clawo/status.sh) that the goal is active and that Codex starts reading `GOAL.md` and working (profile commands appear under `ws/runs/`).

## 5. Supervision

- Run [`../supervise/watch.sh`](../supervise/watch.sh) `<task> "<gpus>"` in the background and take a look at every `EVENT` line. Check:
  - the run is `running` and the goal `active` in `status.sh`, its token count and time are growing, and the resume count is not climbing (a climbing count means the endpoint keeps refusing);
  - `WORK_LOG.md` has an entry per round, and the pace, profile-first and bench.py-only rules are followed;
  - GPUs are used only on your cards, with no leftover processes, and there is enough disk;
  - no attempts to change read-only paths, bypass the bench, or behave differently depending on whether it is being timed.
- A usage limit or "at capacity" from the model endpoint, or a goal that sits idle, is resumed by `clawo` on its own within a bound; `watch.sh` reports each resume. After the machine restarts, start `clawo serve` again and run [`../clawo/resume.sh`](../clawo/resume.sh) `<task>`: the goal continues on the same thread.
- Intervene only with **rule-level** reminders sent through [`../clawo/steer.sh`](../clawo/steer.sh) `<task> "<text>"` ("this round is over 30 minutes, please wrap up and log it", "please profile before changing anything", "do not write your own timing script"). **Never give concrete optimization advice, and never reveal other tasks' methods or numbers.** You fix broken infrastructure (sandbox, disk, drivers, model endpoint) and tell Codex once it is fixed.
- Maintain the state in `$WORK/<task>/SUPERVISOR.md`: current best speedup, number of rounds, problems and your interventions, written so that someone else can take over directly.
- When Codex stops, `clawo` runs the full check on the candidate in `ws/FINAL.json`; read `ws/runs/clawo-final/latest/check.json`, confirm there were no violations, then end supervision.
- Supervise until the goal is reached, Codex stops by itself after several rounds without progress, or the time budget runs out. If it is still making progress at the deadline, report the state and let the owner decide whether to stop.

## 6. Report

When done (or blocked on something the owner must decide), report briefly: workspace path, upstream commit, workload (how the GPU count was matched to upstream), baseline numbers and top hotspots, acceptance results, the `GOAL.md` target, Codex launch time and the `clawo` run id, key events during supervision, and the final result. When blocked, say exactly where and what the owner needs to decide.
