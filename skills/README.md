# skills

Priors for an optimizing agent. Copy the relevant cards into the agent's skill directory (for Codex:
`$CODEX_HOME/skills/<name>/SKILL.md`) and name them in `GOAL.md`. These are priors from earlier tasks;
re-verify them on yours before treating them as facts. The verdict is always the task's own `bench.py check`.

| Card | Read when |
|---|---|
| `train-opt-tiered-profiling` | before choosing a hotspot: stage → module → op → kernel accounting, bottleneck classes, the three hotspot kinds |
| `kernel-utilization-analysis` | at the kernel tier of every profile and before declaring a plateau: grid vs SM count, short (launch-bound) kernels, achieved vs peak bandwidth, repeated chains of small kernels; `scripts/kernel_util.py` reads Kineto and Nsight Systems traces |
| `train-opt-measurement` | before timing anything: valid-run signatures, per-window acceptance, interleaving, fingerprints, GPU-hour accounting |
| `train-opt-action-ladder` | deciding what to try: L0 switches → L1 libraries → L2 search → L3 rewrites → L4 kernels, symptom → first suspect |
| `train-opt-numerics-validation` | changing precision or kernels: N0–N5 tiers, thresholds, fp64 arbitration, deterministic stand-ins |
| `train-opt-fusion-patterns` | fusing memory-bound work between GEMMs, bit-exact reductions |
| `train-opt-fsdp-multi-forward` | several forwards per step under FSDP/DDP |
| `sglang-diffusion-benchmark-profile` | diffusion models: reproducible benchmark and profile workflow, existing fast paths to check first |
| `sglang-diffusion-performance` | diffusion models: performance techniques (attention backends, compile, caching, parallelism) |

The two `sglang-diffusion-*` cards are adapted from [SGLang](https://github.com/sgl-project/sglang/tree/main/python/sglang/multimodal_gen/.agents/skills) (Apache-2.0).
