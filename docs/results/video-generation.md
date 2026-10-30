# Video Generation

[← All results](README.md) · [ResearchBoost-Agent](../../README.md#results)

2 projects · [Self-Forcing](#faster-selfforcing), [MiniMax-H3](#faster-minimax-h3)

## Faster-SelfForcing

**Self-Forcing video DMD training**

| Item | Result |
|---|---|
| Speedup | **2.08×** |
| Hardware | 2 × H200 |
| Measurement scope | Video DMD training |
| Validation | Statistical equivalence |



[Code & project README ↗](https://github.com/AI4AI-for-Anything/Faster-SelfForcing) · [Detailed evidence ↗](https://github.com/AI4AI-for-Anything/Faster-SelfForcing/blob/main/docs/training.md)

## Faster-MiniMax-H3

**MiniMax-H3 FL2VA LoRA fine-tuning** · contributed by [@2018cx](https://github.com/2018cx)

| Item | Result |
|---|---|
| Speedup | **1.8570×** (117.318886 → 63.176236 s / optimizer step) |
| Hardware | 8 × NVIDIA H20 |
| Measurement scope | BF16 FL2VA LoRA / ZeRO-3, batch 1 per rank, approximately 33,750 packed tokens per sample; two-update frozen reference/candidate/reference check |
| Validation | **PASS** — repaired Round 50; reference and optimized arms each ran 50 optimizer steps at seeds 424242, 424243 and 424244 (six arms total); all eight loss/gradient comparisons passed `|standardized mean difference| ≤ 2.0` |

The original Round 19 candidate measured **1.869055×** in the short speed check but was rejected by the separate trajectory gate: finite optimized-gradient spikes drove the step-25 full-LoRA-gradient comparison to **142,950.33** standardized units. Targeted replay diagnostics found that checkpoint inference and replay could select different compiled Q/K RMSNorm variants for identical inputs on five of eight ranks. The repair shares one detached compiled Q/K forward across both modes while preserving the compiled first-order derivative. Round 50 then passed the authoritative speed check at **1.8570097438×** and the fresh three-seed validation. This establishes short-trajectory agreement only, not full convergence or generated-output quality.

[Code & project README ↗](https://github.com/2018cx/Faster-MiniMax-H3) · [Related DiffSynth implementation ↗](https://github.com/2018cx/Faster-DiffSynth-H3) · [Performance and repair audit ↗](https://github.com/2018cx/Faster-MiniMax-H3/blob/main/docs/repair-results.md) · [Six-arm validation ↗](https://github.com/2018cx/Faster-MiniMax-H3/blob/main/docs/repaired-validation-results.md) · [Machine-readable evidence ↗](https://github.com/2018cx/Faster-MiniMax-H3/blob/main/docs/performance-data/repaired-validation.json)
