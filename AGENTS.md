# AGENTS.md

This repository describes how an optimization task is prepared, run and judged; it is not a codebase to optimize. To run a task, follow [docs/run-a-task.md](docs/run-a-task.md). For background, read in order:

1. [docs/methodology.md](docs/methodology.md): the process from scoping to final validation.
2. [docs/judge.md](docs/judge.md): what counts as success, and when the judge may or may not change.
3. [docs/goal-mode.md](docs/goal-mode.md): how a run works (one Codex `/goal` session in a sandbox, run by claw-orchestrator, watched by a supervisor).
4. The skill cards in [skills/](skills) that match the task.
5. One worked example: [tasks/dmd2/GOAL.md](tasks/dmd2/GOAL.md).

## Hard rules

- **The frozen judge is the only verdict.** Do not write your own timing scripts or report speed any other way. Never weaken a gate to let a candidate through. If a gate rejects something you believe is correct, stop and ask the owner.
- **Numerics.** The baseline precision is the upstream precision. Precision tiers are defined in [`train-opt-numerics-validation`](skills/train-opt-numerics-validation/SKILL.md); anything above N2 is rejected.
- **Same code path.** Do not read the judge's environment variables. Do not behave differently while being timed or judged. Timing and trajectory runs must exercise the same configuration.
- **Data.** Use public code, weights and data. Private data stays on the infrastructure it belongs to: do not copy, stream, presign or list it out.
- **Shared machines.** Use only the GPUs and directories assigned to you. Never touch other users' processes or files. Use absolute paths in any `rm -rf`.
- **No answer leakage.** When you formulate a task for another agent, do not include known results, switch names or speedups from other tasks.
- **Secrets.** Model credentials live only in `goal/codex.env` (git-ignored); never write them into a task workspace, a log or a commit.

## Starting a new task

```
tasks/<new>/
  GOAL.md                  # adapt from tasks/dmd2/GOAL.md
  GOAL_LINE.txt            # the /goal line typed at launch
  bench/                   # check / time / profile entry points; baseline-candidate-baseline timing
  bench/<task>_adapter.py  # build, objects, step, invariants, canonical
  numerics/                # copy ../../numerics and freeze it
  task/formulation.json    # frozen input fingerprints, evaluator hash
  formulation/prep/        # environment, assets, baseline records, acceptance; README lists each script
```

Before handing the task to an optimizer:

- Record the baseline twice and confirm the two recordings are bitwise identical.
- Freeze δ.
- Run the negative self-tests and the control arm; each must fail the gate it targets.
- Hash the judge.
