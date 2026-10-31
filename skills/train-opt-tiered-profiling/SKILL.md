---
name: train-opt-tiered-profiling
description: Tiered profiling (end to end → stage → module/op → kernel), identifying the bottleneck type, and sorting hotspots into three kinds (a missed existing fast path / a configuration or backend problem / a genuinely new opportunity). Read before choosing what to optimize.
---

# Tiered profiling

Use when: before optimizing any training task, and after every accepted change.

## Split by training phase first, then by the parts of one step

When training has several phases (for example GAN reconstruction → discriminator updates → adversarial, or warmup → steady state), **profile each phase separately**, recording one steady-state window per phase:
- The structure of a step differs between phases (with or without a discriminator step, with or without double backward for the adversarial loss), so hotspots cannot be extrapolated from one phase to another.
- When aggregating, a hotspot's weight = its time per step in that phase × that phase's share of the steps in full training. List hotspots that appear in every phase separately from those that appear in only one.
- A timing configuration whose schedule is compressed to cover every phase is for timing and profiling only, never for quality validation.

## The parts of one training step

| Part | First-level timing (always on, no syncs) | Second level (on demand) |
|---|---|---|
| startup, compilation, worker spawn | one-off wall clock; the first step recorded separately | kept out of the steady-state profile |
| storage reads | wall clock of `next(it)` in the main process | OS runtime, file access |
| decoding, augmentation | segment timers inside workers | CPU sampling, GIL hold time |
| H2D | CUDA events around `.to(device)` | pseudo-asynchronous copies from pageable memory |
| frozen-module forward | CUDA events | GPU projection time per NVTX range |
| trainable-model forward | CUDA events, split per block if needed | top kernels, number of short kernels |
| loss (including perceptual losses, discriminator and other auxiliary terms) | CUDA events | swarms of small kernels, implicit syncs |
| backward | CUDA events | top backward kernels, recomputation share |
| gradient sync | wall clock of the sync segment, compute/communication overlap ratio | NCCL overlap, straggling ranks |
| optimizer, EMA | CUDA events | a kernel count of about parameter tensors × a constant means a for-loop implementation |
| logging and host syncs | wall clock | `cudaStreamSynchronize` and DtoH inside the step |
| eval, sampling, checkpointing | wall clock, blocking and background parts separately | profiled separately |

Instrumentation rules:

- Record one pair of CUDA events per part on the current stream, without synchronizing; read the times every N steps at a point that synchronizes anyway (such as logging).
- Never insert `torch.cuda.synchronize()` between parts for timing. With it, the CPU no longer queues ahead and H2D no longer overlaps compute; you are measuring a different pipeline.
- The length of a CPU-side NVTX range is not GPU time. Attribute kernels to NVTX ranges through CUDA correlation IDs; overlapping intervals cannot simply be added.
- Record steady state only: skip warmup with a capture range, record 3–5 full steps, one file per rank on multiple GPUs.
- When a range contains several components, add one more NVTX or record_function level inside it and re-record before attributing; do not charge the whole range to one component. The top-k ranking must include memcpy/memset and list call counts.
- When attributing time to a part needs syncs at part boundaries, label it "attribution mode". Numbers from that mode cannot be compared with unsynchronized timings.
- **Do not attribute backward with a module's full backward hook.** On in-place activations, views and compiled regions, the hook's range crosses module boundaries and its label picks up upstream backward nodes. A LeakyReLU backward label containing CompiledFunctionBackward, LayerNorm and Bmm has been observed. Instead, use autograd sequence numbers to map backward kernels back to forward ops:
  - `torch.autograd.profiler.emit_nvtx()` or torch.profiler records a `seq` for every forward op, and the backward node (`XxxBackward`) carries the same number (written `stashed seq` in NVTX);
  - then attribute by the module range the forward op ran in. Mark module ranges with NVTX or record_function only around compiled regions, never inside them;
  - a compiled region counts as one unit (`CompiledFunction` / `CompiledFunctionBackward`) attributed to its enclosing module, not split further.
- **Choosing a direction does not need perfect backward attribution.** These three are usually enough to price a direction:
  - forward attribution;
  - GEMM shapes: one shape usually maps to exactly one Linear or convolution;
  - per-phase totals.

  Send uncertain directions straight to a sweep. If an observation tool is still not working after one round, stop and use these instead; do not spend several rounds on tooling.
- **Fine-grained observation is the measurement program's job.** To map kernels back to op shapes, strides, modules and forward/backward sequence numbers, or to see compiler-generated code, use the detailed mode the measurement program provides (PyTorch profiler with record_shapes/with_stack/profile_memory, plus the compile debug output of the same run). That observation must be shown not to change the code path: a plain trace and a detailed trace of the same code must have the same kernel kinds and counts per step. Interceptors such as a TorchDispatchMode make compiled regions fall back to eager and cannot be used to observe compiled training. If the measurement program lacks such a mode, hand it back to the owner to add; do not write your own observation tool.

## Three kinds of hotspot

In the profile summary, tag every hotspot with its kind:

1. **An existing fast path was missed**: the fused kernel is absent from the trace while the small ops it replaces are present; or a guard, alignment or dtype condition failed and the slow path was taken.
2. **Configuration or backend problem**: a switch not set, the wrong backend, the wrong layout, compilation or graphs not in effect.
3. **A genuinely new opportunity**: existing paths and configuration have all been checked, and it is still slow.

Fix the first two with L0/L1, starting with enabling conditions, guards, backends and layouts. Only the third kind may go to L3/L4, and only with an evidence pack: the baseline timing record, one representative trace, the exact shapes/dtypes/strides/topology, and the classification.

## Identifying the bottleneck type: by ablation, not by nvidia-smi

nvidia-smi's utilization only says whether some kernel ran during the sampling period; 100% does not mean the compute is saturated.

| Type | First-level signal | Confirming ablation |
|---|---|---|
| Data | `next(it)` takes more than 5–10% of the step | reuse one cached real batch; the step gets clearly faster |
| Host / launch | the sum of GPU projection times is far below wall clock, and it is not waiting on data; or, inside CUDA graphs, most kernel time is in `short` or `under-filled` classes of the kernel table (`kernel-utilization-analysis`) | a larger batch makes time grow sublinearly; CUDA graphs or reduce-overhead are clearly faster; fusing a repeated chain shortens its span |
| Host syncs | long blocking periods in some CPU segment | sync debug mode warns; removing `.item()` makes it faster |
| Bandwidth | top kernels are norms, elementwise ops, layout moves | clearly faster after compilation; measured bandwidth close to HBM peak |
| Compute | very little idle; top kernels are GEMM or attention | compilation brings almost nothing; TFLOP/s close to measured peak |
| Communication | long sync segment, low overlap | compare with a single-GPU run at the same per-GPU batch |
| Stragglers | uneven step times across ranks | turn off automatic GC and collect manually; bind NUMA |

Hard rule: **what looks like communication is checked for stragglers first.** Automatic GC fires at different times on different ranks, and a GIL-holding Python loop on one rank is amplified by all-reduce into every rank waiting.

## Accounting conventions

- Count only the FLOPs the trainable model needs for utilization, and report frozen modules separately. Otherwise a real speedup such as caching a frozen module's outputs shows up as a drop in utilization.
- Use the locally measured peak. The power cap pushes clocks below nominal, and the denser a compute path, the lower it is pushed.
- Also report J/sample. A configuration at 100% GPU utilization can use several times the energy of an efficient one.

## Kernel level

Start the kernel tier with the whole-trace kernel table and chain list of [`kernel-utilization-analysis`](../kernel-utilization-analysis/SKILL.md) (`scripts/kernel_util.py`): it shows, per kernel class, how much of the GPU the grid uses, how much time goes to short launch-bound kernels, how far each class is from peak bandwidth (with a bytes model), and which chains of small kernels repeat. Then confirm the top 1–3 with Nsight Compute:

- Look at only 1–3 kernels among the stage-level hotspots, filtered by kernel name and invocation index; do not replay the whole model.
- With a large process memory, replaying each kernel is very slow. A reduced-depth copy can be used, but check that kernel signatures (names, shapes, launch configurations) match the full model, and state the coverage in the report.
- Hardware counters may need administrator permissions. Without them, mark the data unavailable; do not substitute other numbers.
- With ncu attached to only one rank, replay does not see NCCL contention; deduplicating by launch configuration misses kernels that share a configuration.

Profile data is for finding a direction, not for ranking candidates.
