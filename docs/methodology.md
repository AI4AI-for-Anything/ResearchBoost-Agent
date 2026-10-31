# Methodology: one optimization task from start to finish

This page is the overall process. Each step has its own page: the verdict in [judge.md](judge.md), how a goal-mode run works in [goal-mode.md](goal-mode.md), the concrete steps in [run-a-task.md](run-a-task.md), lessons across tasks in [lessons.md](lessons.md), and the priors used to choose what to try in [`../skills/`](../skills).

## 0. Decide what must not change

Before any work starts, write the boundaries down with the owner. The owner decides all of the following; the agent never does:

- **Workload**: upstream commit, configuration, per-GPU batch. Size it by the per-GPU load of the target deployment, not by scaling up to fill the local GPUs ([`train-opt-measurement`](../skills/train-opt-measurement/SKILL.md), "Per-GPU load follows the target deployment"). Hyperparameters stay as upstream.
- **Precision**: the baseline precision is the upstream precision. No whole-step switch to bf16, FP8 or INT8. Local precision changes go up to N2 at most and must pass the statistical gate (tiers are defined in [`train-opt-numerics-validation`](../skills/train-opt-numerics-validation/SKILL.md)).
- **Semantics**: training semantics and the order in which random numbers are drawn stay the same. Relaxing one of these (as LLaVA later did for "how the samples of one step are assigned" and "how the loss is normalized") is an owner decision written into the task statement, not a change to the judge.

## 1. Formulate the task

A separate agent or a person formulates the task; the optimizing agent never sees this process.

1. Run upstream unchanged on the target machine and record the environment fingerprint (library versions, GPU UUIDs, the math modes actually in effect).
2. Write the bench with three entry points, `time`, `profile` and `check`; all timing goes through it. Timing runs baseline → candidate → baseline in independent processes, and each timing window is accepted or rejected on its own.
3. Write the numerics adapter: a thin layer for build, objects, step, invariants and canonical; everything else comes from the [`numerics`](../numerics) component. The component is copied into the task directory and frozen; a task may make small environment-specific changes (for example syntax for an older Python), never to the verdict logic.
4. Record the baseline: record the bitwise cases twice in deterministic mode and confirm the baseline reproduces itself bit for bit; then record paired-seed trajectories, compute δ and freeze it.
5. **Negative self-tests**: deliberately build candidates that must fail (change the setup, drop one gradient term, skip the re-decode before the discriminator step, alter the random stream) and confirm every failure path actually fires. Add a control arm that changes only the learning rate; the statistical gate must reject it as INCORRECT.
6. Freeze: hash the judge code, thresholds, δ and baseline records. They are read-only to the optimizing agent.
7. Write `GOAL.md`: the goal, the single criterion, the per-round procedure, the constraints and the environment. Use [`../tasks/dmd2/GOAL.md`](../tasks/dmd2/GOAL.md) as the template. **Do not include known answers, switch names or other tasks' speedups.**

## 2. Optimize (at most 30 minutes per round)

Each round has four steps; the wall clock starts when the GPU lock is taken:

1. Profile the current best version and account layer by layer: stage → module → op → kernel. Sort hotspots into three kinds: existing fast paths that were missed, configuration or backend problems, and genuinely new opportunities ([`train-opt-tiered-profiling`](../skills/train-opt-tiered-profiling/SKILL.md)). At the kernel tier, run the kernel utilization analysis ([`kernel-utilization-analysis`](../skills/kernel-utilization-analysis/SKILL.md)): grid size against the SM count, short launch-bound kernels, achieved against peak bandwidth, and repeated chains of small kernels. It names the inefficient kernels and kernel chains; a plateau is declared only after the large ones have had an attempt.
2. Attack one hotspot, or one class of bottleneck. Every change sits behind its own switch, off by default ([`train-opt-action-ladder`](../skills/train-opt-action-ladder/SKILL.md)).
3. Screen with `time`, adding `check --quick` when needed; run the full `check` only once the accumulated changes reach the target.
4. Log the round in WORK_LOG: profile findings, the change, the `time` result, the `check` result. Failed and no-gain rounds are logged too.

## 3. Wrap-up and real validation

- The judge only shows that this layer is sound. Finish with a full training or evaluation run on the real workload, for example 16 epochs plus rFID for RAE, or one epoch plus four benchmarks for LLaVA, compared against official or baseline results.
- Real runs often expose problems the judge cannot see:
  - one-time costs: LLaVA's token-length grouping takes seconds on the fixture but 66 minutes per rank on the 665k real records;
  - code paths the judge never exercises: the judge never saves a checkpoint, and the first real run crashed at the step-1000 save;
  - shape-dependent library bugs: for example a BF16 GEMM with a single input row raises SIGFPE.
- Results go into the task repository (code and documentation); lessons about the method go back into this repository, into the skill cards and [lessons.md](lessons.md).
