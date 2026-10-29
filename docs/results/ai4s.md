# AI for Science

[← All results](README.md) · [ResearchBoost-Agent](../../README.md#results)

1 project · [ProteinMPNN](#faster-proteinmpnn)

## Faster-ProteinMPNN

Contributed by [@micky-li-hd](https://github.com/micky-li-hd).

**ProteinMPNN v_48_020 training · full public dataset**

| Item | Result |
|---|---|
| Speedup | **2.25×** |
| Hardware | 1 × A100 SXM4 40GB |
| Measurement scope | 450.65 → 200.52 s/epoch, mean of epochs 2–6 |
| Validation | Validation perplexity 5.884 vs 5.934 / 5.897 after six epochs |

Six of the recipe's 150 epochs (8,970 updates) per arm, run reference → candidate → reference with cold compiler caches. Whole-process time, including compilation, data loading, validation and checkpoint writing, went from 3,316.2 to 2,154.9 s (1.54×). Final validation accuracy is 0.447 for the candidate and 0.445 / 0.446 for the references; all 472 checkpoint tensors are finite in every run.

[Code & project README ↗](https://github.com/micky-li-hd/Faster-ProteinMPNN) · [Detailed evidence ↗](https://github.com/micky-li-hd/Faster-ProteinMPNN/blob/main/six_epoch_evidence.json)
