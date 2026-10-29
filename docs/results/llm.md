# LLM

[← All results](README.md) · [ResearchBoost-Agent](../../README.md#results)

3 projects · [NanoChat](#faster-nanochat) · [YOCO](#faster-yoco) · [LLM2Vec](#faster-llm2vec)

## Faster-NanoChat

Contributed by [@Bool1020](https://github.com/Bool1020).

**D24 (~1.384B) · Tensorwise FP8 training**

| Item | Result |
|---|---|
| Speedup | **1.0744×** |
| Hardware | 8 × H20 |
| Measurement scope | 3,358.4 → 3,126.0 ms/update |
| Validation | N1 statistical equivalence |

Steady-state timing after compilation and warmup; six-seed short-trajectory check passed.

[Code & project README ↗](https://github.com/AI4AI-for-Anything/Faster-NanoChat) · [Detailed evidence ↗](https://github.com/AI4AI-for-Anything/Faster-NanoChat/blob/main/docs/training.md)

## Faster-YOCO

**YOCO-3B pretraining · BF16, no FP8**

| Item | Result |
|---|---|
| Speedup | **2.12×** |
| Hardware | 8 × H100 80GB |
| Measurement scope | Training update speedup |
| Validation | Statistical equivalence |

A 20,000-update run achieved 1.91× end-to-end speedup (5,345 → 2,799 s), including startup and saves.

[Code & project README ↗](https://github.com/AI4AI-for-Anything/Faster-YOCO) · [Detailed evidence ↗](https://github.com/AI4AI-for-Anything/Faster-YOCO/blob/main/docs/judge.md)

## Faster-LLM2Vec

Contributed by [@Bool1020](https://github.com/Bool1020).

**Mistral-7B-Instruct-v0.2 · BF16, FlashAttention2, LoRA rank 16, gradient checkpointing**

| Item | Result |
|---|---|
| Speedup | **1.2900× MNTP / 1.6009× SimCSE** |
| Hardware | 1 × NVIDIA H20 |
| Measurement scope | MNTP: 7,978.9 → 6,183.0 ms/update; SimCSE: 12,683.0 → 7,922.4 ms/update |
| Validation | Historical N1 statistical equivalence checks; seeds 42, 43 and 44, 60 updates per seed |

These are independent steady-state training-update measurements, excluding startup, evaluation and checkpoint saving. MNTP uses batch 32 / sequence length 512; SimCSE uses batch 128 / sequence length 128 and a fixed public MNTP adapter. The campaigns retained 11 full-check PASS checkpoints over 37 MNTP rounds and 13 over 22 SimCSE rounds.

Full-schedule training, MTEB quality evaluation and the MNTP-to-SimCSE adapter handoff remain untested. The combined source has not been revalidated on a GPU; measured source revisions are preserved on the experiment-mntp and experiment-simcse branches.

[Code & project README ↗](https://github.com/AI4AI-for-Anything/Faster-LLM2Vec) · [Detailed evidence ↗](https://github.com/AI4AI-for-Anything/Faster-LLM2Vec/blob/main/docs/h20-results.md)
