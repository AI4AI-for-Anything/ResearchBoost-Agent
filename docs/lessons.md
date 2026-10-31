# Results and lessons across tasks

## Four tasks, four ceilings

| Task | Final | Where it stopped |
|---|---|---|
| RAE Stage-1 | 5.32× | The precision boundary: TF32 plus local bf16 (N2) gave most of the gain and passed the statistical gate; whole-step bf16 was excluded by the task statement |
| Self-Forcing | 2.08× | The ceiling without changing numerics is about 2.0–2.1×; 3× would need FP8, which the owner chose not to do |
| LLaVA-1.5 | 1.09× → 2.39× | The task statement: padding waste and full recomputation could not be touched under the original statement, and the large padding gain opened up only after the owner relaxed three constraints. After that, GEMM MFU reached 82%; 2.5× would require hiding all of the reduce-scatter |
| DMD2 | 1.72× | Noise floor plus memory: the baseline already used 69.6 of 95 GiB, with four OOMs; changes of 0.1–0.3% could not be resolved against the candidate's own run-to-run noise of about 0.3%, and the last 33 rounds produced no gain |

## General lessons

**Estimating the ceiling**
- When estimating the ceiling, count what the owner may allow you to change as changeable. LLaVA was first estimated at 1.75–1.9× on the assumption that default padding and recomputation were fixed, and those were exactly the two constraints that were relaxed later.
- A FLOP model (total matmul work per step ÷ measured MFU) predicted the number of retained layers and the speedup on LLaVA four times in a row within 0.35%. It tells you where a lever ends before you pull it.

**Memory is an account you can draw on in both directions**
- LLaVA's peak memory went 57.3 → 89.8 → 74.8 → 87.4 → 78.7 GiB: memory freed by one change was repeatedly spent on retaining more activation layers. Memory is not a one-way constraint.
- Time and memory are separate objectives: global balancing did nothing for time but cut peak memory by 14 GiB.

**Measurement**
- "Installed but not active" is indistinguishable from "useless" by timing alone; only counters and kernel names in the trace prove that a fast path was actually taken.
- On a shared machine, a baseline window slowed by someone else's short job inflates the speedup (measured 2.44×, against 2.03× from clean windows). Look at the per-window times before trusting a speedup.
- Timing noise sets the smallest gain you can resolve. Changes of 0.1–0.3% need interleaved A/B measurement, or timing of just the stage that changed.

**The kernel tier**
- An inference decode step (an MoE model with speculative decoding, 8 GPUs, inside CUDA graphs) was about 1,550 kernels of 3–16 us, three to four times its weight-read floor. In one profile, 39% of the kernel time was in grids covering less than half of the 148 SMs and 31% in kernels with a median under 5 us. Switch and backend sweeps gave about 15%, after which the agent declared a plateau with these classes untouched. The kernel table (`kernel-utilization-analysis`) shows this from a single trace. When most time sits in short or under-filled classes, the remaining lever is writing kernels: fusing the repeated chains, persistent kernels, a megakernel. A plateau is not established until those have been attempted.

**Third-party libraries changing state behind your back**
- Triton's file cache drew temporary file names from the global `random`, and xformers also consumed the global random stream; the RNG-fingerprint exact item rejected both. The fix is to replace only those modules' `random` with an independent `SystemRandom`.
- torch 2.1.2+cu121's native BF16 `F.linear` raises SIGFPE on a single input row (dmesg shows a divide error in libcublasLt). The baseline crashes too, so the fix pads to at least 16 rows, and must not special-case by stage.

**From the judge to a real run**
- The judge never saved a checkpoint, and the real training run crashed at its first save at step 1000. Before a long run, exercise the save path with `max_steps 3 + save_steps 2`.
- Calibrating the scorer is not calibrating the whole pipeline: on SQA, the official weights also scored 69.46 in our pipeline against a published 66.8, with the offset coming from the generation side. Compare three ways: the optimized model, the unmodified baseline and the official weights.
