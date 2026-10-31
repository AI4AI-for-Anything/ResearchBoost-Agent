---
name: kernel-utilization-analysis
description: Kernel tier of every profile - per kernel class, grid size against the SM count, launch-bound (short) kernels, achieved bandwidth against peak, and repeated chains of small kernels (fusion candidates). Read before choosing a hotspot, and before declaring that no lever is left.
---

# Kernel utilization analysis

Use when: at the kernel tier of every profile (after stage → module → op attribution, see
`train-opt-tiered-profiling`); whenever a step consists of many short kernels (decode, small-batch training,
optimizer and EMA loops); and always before declaring a plateau. Switches and library choices run out long before
kernels do. A stop is premature while the table below shows large under-filled, short or bandwidth-poor classes
that no attempt has addressed.

## Procedure

1. **Capture one steady-state window** that includes every kernel:
   - torch.profiler (Kineto) traces record kernels inside CUDA graphs (`graph id` in the kernel args);
   - Nsight Systems needs `--cuda-graph-trace=node`, otherwise graphs appear as one opaque execution each.
     The script warns when kernels are missing for this reason. Export with
     `nsys export --type sqlite`;
   - one rank is enough on a symmetric job; pick the rank least affected by waits (see pitfalls).
2. **Run the kernel table**:

   ```
   python <this card's directory>/scripts/kernel_util.py <trace.json.gz | trace.sqlite> \
       --out kernels.md [--json kernels.json] [--start-ms A --end-ms B] [--peak-bw-gbs <measured>] \
       [--bytes-model bytes.json]
   ```

   Per kernel class it reports calls, total and median time, blocks, **SM coverage** (grid blocks over the SM
   count), **waves**, registers, shared memory, and flags:

   | flag | meaning | typical levers |
   |---|---|---|
   | `short` | median < 5 us: launch, prologue and drain dominate | fuse with neighbours; persistent kernel; CUDA graphs / PDL if still eager |
   | `under-filled` | grid covers < 50% of the SMs | split-K / stream-K, smaller tiles, more CTAs per token, fuse with independent work |
   | `tail` | 1-1.5 waves: the last wave leaves most SMs idle | change the tile count, persistent scheduling |
   | `skewed` | mean > 2x median | the kernel waits (a collective on a lagging rank, a PDL predecessor); use the median, look for stragglers |
   | `bw-poor` | < 30% of peak bandwidth (needs a bytes model) | a better kernel for the shape, wider loads, fewer passes over the data |

   It also mines **repeated kernel chains**: the same sequence of back-to-back short kernels recurring on a stream
   (per layer, per step). Each chain row shows occurrences, span, mean SM coverage of its members, how many members
   are flagged, and its share of kernel time. Sub-sequences and rotations of a listed chain are dropped.
3. **Write a bytes model for the top classes** (a JSON list of `{"match": "<regex on the kernel name>", "bytes":
   <bytes per call>, "flops": <optional>}`). Compute the bytes from the shapes: weights at their stored precision and
   tensor-parallel shard, activations in and out, KV or recurrent state read, scales. Kernels inside CUDA graphs
   carry no shapes in the trace; take them from the model configuration or from one eager profile of the same step.
   With the model, the table gains achieved GB/s and % of peak, and the header states the **bandwidth floor** of the
   window (bytes moved at peak bandwidth) and how far the measured time is above it. Use a locally measured peak
   when you have one (the nominal number overstates what a kernel can reach).
4. **Price the fusion candidates**: for each top chain, the fused cost is roughly
   max(chain bytes / peak bandwidth, one kernel's fixed cost of a few us). The gain is the chain's span minus that,
   times its occurrences. A chain whose members are mostly `short` or `under-filled` is the clearest target.
5. **Confirm the top 1-3 kernels with Nsight Compute** where hardware counters are accessible:
   `ncu --kernel-name regex:<name> --launch-skip N --launch-count 1 --metrics
   gpu__time_duration.sum,dram__bytes.sum,sm__throughput.avg.pct_of_peak_sustained_elapsed,launch__grid_size,launch__waves_per_multiprocessor`.
   Without counter access, mark these numbers unavailable; do not substitute estimates.
6. **Log the tables** (classes, chains, floor) in the round's notes. Re-run after every kernel change: the table is
   how a kernel attempt shows whether it filled the SMs, moved closer to the floor, or only moved time elsewhere.

## Reading the result

- **Busy time far above the bandwidth floor, top classes `short` / `under-filled`**: the step is latency- and
  launch-bound. The lever is fewer, fuller kernels: fuse chains, write persistent kernels, and for a decode step a
  megakernel over the per-layer chains. More switch sweeps will not move it.
- **Top classes near peak bandwidth or near peak FLOP/s**: the kernels are efficient. Gains must come from doing
  less work (algorithmic change, less data moved, lower precision only where the task's rules allow it).
- **GEMMs with small M** (decode, small micro-batches) that use a fraction of the SMs read their weights at a
  fraction of the bandwidth. Split-K or stream-K kernels that use every SM, or fusing the GEMM with its
  neighbours, are the usual answer. Keep the stored weight format and scales.
- **Communication kernels** with `skewed` durations mostly measure waiting. Check stragglers before optimizing the
  collective itself. A collective fused into its producer or consumer removes a launch and a wait.

## Pitfalls

- Profilers inflate host time (torch.profiler roughly doubles CPU-side cost; nsys adds a few percent). Use the
  trace for the kernel-side picture and `bench` timing for speed.
- Programmatic dependent launch and multiple streams make kernels overlap. A chain's summed kernel time can exceed
  its span (negative gap share); compare spans, not sums.
- SM coverage assumes one resident block per SM. A kernel can be under-filled by design (a persistent kernel
  launches exactly one grid per SM, small reductions launch a handful of blocks). The flag says where to look,
  not that the kernel is wrong.
- Kineto's `blocks per SM` is grid blocks divided by the SM count, not occupancy. Occupancy limits (registers,
  shared memory) are in the kernel's `occupancy` args.
- Kernel names group template instantiations exactly. The same operator with two tile shapes shows up as two
  classes, which is usually what you want when choosing a tile.
- A bytes model is an estimate. Give its source (shapes, dtype, shard) next to each entry, and keep it with the
  round's notes so later rounds use the same accounting.
