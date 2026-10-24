<p align="center">
  <img src="docs/assets/researchboost-agent-logo.png" alt="ResearchBoost-Agent logo" width="480">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a>
</p>

<b><p align="center">AI that accelerates the research that advances AI.</p></b>

ResearchBoost-Agent turns AI capabilities into faster AI experimentation, starting with the training code researchers run every day. It autonomously profiles bottlenecks, implements optimizations, and validates speedups against a frozen evaluation protocol, turning the same compute budget into more room to explore.

<div align="center">
<table>
<tr><td align="center">
<p><strong>🚀 Project Blog & Wishlist</strong></p>
<p>Read the story behind ResearchBoost and our training speedups.<br>
Have a project you want accelerated? Submit it to our Wishlist.</p>
<a href="https://ydove0324.github.io/hx_resume/blog/researchboost/"><img src="https://img.shields.io/badge/Read_the_Blog-7C3AED?style=for-the-badge" height="24" alt="Read the project blog"></a>
&nbsp;
<a href="https://ydove0324.github.io/hx_resume/blog/researchboost/#wishlist"><img src="https://img.shields.io/badge/Submit_to_Wishlist-0891B2?style=for-the-badge" height="24" alt="Submit a project"></a>
</td></tr>
</table>
</div>

## Quick start

Runs are driven by [claw-orchestrator](https://github.com/Enderfga/claw-orchestrator) on the GPU host:

```bash
npm install -g @enderfga/claw-orchestrator   # 7.13.0 or later
clawo serve                                   # keep it running
```

Give the agent access to a model endpoint:

```bash
cp goal/codex.env.example goal/codex.env
# edit goal/codex.env: set OPENAI_API_KEY and OPENAI_BASE_URL (optionally CODEX_MODEL)
```

Then point your agent at [docs/run-a-task.md](docs/run-a-task.md).

## How a run works

![Goal mode: formulate and freeze the judge, then one agent iterates in a sandbox: profile, edit, time, full check, log](docs/figures/goal-mode-loop.svg)

1. **Frame the task.** The owner fixes what may not change: the upstream workload and per-GPU load, the baseline precision, the training semantics. A formulating agent builds the judge for this task (`bench/` plus a frozen copy of [`numerics/`](numerics)), records the baseline, freezes δ, proves with known-bad candidates that every gate fires, and writes `GOAL.md`.
2. **Run goal mode.** One Codex `/goal` session gets the workspace, the GPUs and the skill cards inside a bubblewrap sandbox. Every round it profiles the current best version, changes one hotspot behind a switch, measures with `bench.py time`, and logs the round in `WORK_LOG.md`. [claw-orchestrator](https://github.com/Enderfga/claw-orchestrator) runs the session: it keeps the Codex thread across restarts and usage limits, and when Codex stops it runs the full check itself. A supervisor watches from outside and intervenes only on rules and facts, never on optimization direction. See [docs/goal-mode.md](docs/goal-mode.md).
3. **Accept only what the judge accepts.** `bench.py check` is the only verdict. A full-check PASS is then confirmed with a real end-to-end training or evaluation run.

## Results

Every number below was printed by that task's frozen judge, or comes from a full training or evaluation run of the accepted candidate.

| Task | Upstream | Hardware during optimization | Judge verdict | Speedup | Code |
|---|---|---|---|---|---|
| RAE Stage-1 training (decoder + GAN) | bytetriper/RAE @a4d18c4 | 2 × H200 | PASS, statistically equivalent | **5.32×** step time; full 16-epoch run on 8 × H20: rFID 0.541 vs 0.569 for the public checkpoint | [Faster-RAE](https://github.com/AI4AI-for-Anything/Faster-RAE) |
| Self-Forcing video DMD training | guandeh17/Self-Forcing @33593df | 2 × H200 | PASS, statistically equivalent | **2.08×** | [Faster-SelfForcing](https://github.com/AI4AI-for-Anything/Faster-SelfForcing) |
| LLaVA-1.5-7B stage-2 fine-tuning | haotian-liu/LLaVA @c121f04 | 4 × H20 | PASS, statistically equivalent | **2.39×**; real 1-epoch run: four benchmarks within −0.50 to +0.44 of the official weights | [Faster-LLaVA](https://github.com/AI4AI-for-Anything/Faster-LLaVA) |
| DMD2 one-step SD1.5 distillation + GAN | tianweiy/DMD2 @8d8fa55 | 4 × H20 | PASS, statistically equivalent | **1.72×**; FID-30k 8.70 vs 8.65 on 8 × H20 | [Faster-DMD](https://github.com/AI4AI-for-Anything/Faster-DMD) |

## The judge

A candidate counts only if the task's frozen judge accepts it. The judge runs these gates in order and stops at the first one that fails:

0. **Structure**: the training entry points the judge drives are unchanged (AST compare), data loading is bitwise identical, and exact items match: phase, call counts, RNG fingerprints, learning rate, cross-rank sync.
1. **Benefit**: baseline → candidate → baseline timing in independent processes. A speedup that does not exceed `max(1.02, 1 + 2 × baseline spread)` is rejected as no benefit; precision is not evaluated.
2. **Bitwise**: every tensor recorded in short deterministic cases matches the baseline bit for bit → accept.
3. **Statistical**: otherwise, paired-seed training trajectories; every endpoint must stay within δ, twice the baseline's own seed-to-seed standard deviation, frozen before any candidate is seen.

The judge is frozen and hashed before optimization starts and is never relaxed to let a candidate through. Details: [docs/judge.md](docs/judge.md).

## Starting a new task

Read [AGENTS.md](AGENTS.md) and [docs/methodology.md](docs/methodology.md), give the formulating agent [`goal/templates/FORMULATOR_BRIEF.md`](goal/templates/FORMULATOR_BRIEF.md), and use [`tasks/dmd2`](tasks/dmd2) as the template: `GOAL.md`, a `bench/` with `check` / `time` / `profile`, a task adapter for [`numerics/`](numerics), and the prep scripts that rebuild the environment and freeze the baseline.

## Repository layout

| Path | Contents |
|---|---|
| [`docs/`](docs) | [Methodology](docs/methodology.md), [the judge](docs/judge.md), [goal mode](docs/goal-mode.md), [running a task](docs/run-a-task.md), [lessons from four tasks](docs/lessons.md) |
| [`goal/`](goal) | Running one Codex `/goal` session on claw-orchestrator: bubblewrap sandbox, Codex config template and model-access file, run / status / steer / resume scripts and the final check, the watchdog, the brief for the formulating and supervising agent |
| [`numerics/`](numerics) | The equivalence component every task judge copies and freezes: recording, bitwise and tiered comparison, paired-seed trajectories, the task adapter base class, a self-test |
| [`skills/`](skills) | Eight skill cards read before choosing what to try: `train-opt-*` (profiling, measurement, action ladder, numerics validation, fusion patterns, FSDP multi-forward) and `sglang-diffusion-*` (diffusion benchmarking and performance) |
| [`tasks/`](tasks) | Per task: the `GOAL.md` the agent saw, the frozen judge code, archived judge records, supervision notes and the prep scripts |

## Acknowledgements

We thank the [SGLang](https://github.com/sgl-project/sglang) project. Part of the kernel-optimization skills in this repository are ported from SGLang: [`skills/sglang-diffusion-benchmark-profile`](skills/sglang-diffusion-benchmark-profile) and [`skills/sglang-diffusion-performance`](skills/sglang-diffusion-performance) are adapted from the skills in [`python/sglang/multimodal_gen/.agents/skills`](https://github.com/sgl-project/sglang/tree/main/python/sglang/multimodal_gen/.agents/skills), released under the Apache-2.0 license.
