# External case: ProteinMPNN training acceleration

[Faster-ProteinMPNN](https://github.com/micky-li-hd/Faster-ProteinMPNN) is an independently contributed infrastructure acceleration case inspired by ResearchBoost-Agent. It includes pinned reference and candidate training sources, dependency versions, an equal-workload reproduction script, checksums and machine-readable result/audit records.

## Status

This is an **exploratory external case, not a ResearchBoost accepted result**. It has not obtained the frozen judge's four-gate PASS and is not included in the certified Results table. No judge or acceptance criterion is changed by this contribution.

## Observed experiment

- Upstream: dauparas/ProteinMPNN at `8907e6671bfbfc92303b5f79c4b5e6ce47cdef57`.
- Hardware/runtime: one A100 SXM4 40 GB, Python 3.12.11, PyTorch 2.5.1+cu121.
- Workload: official full public dataset, v_48_020 per-epoch settings, bounded to six complete epochs from scratch; 8,970 updates per arm.
- Order: reference, candidate, reference, sequential independent processes with isolated cold compiler caches.

| Observed scope | Reference 1 | Candidate | Reference 2 | Reference mean / candidate |
| --- | ---: | ---: | ---: | ---: |
| Whole-process seconds | 3316.216 | 2154.895 | 3316.182 | 1.54x |
| Mean native epoch seconds, epochs 2–6 | 449.46 | 200.52 | 451.84 | 2.25x |
| Final validation perplexity | 5.934 | 5.884 | 5.897 | — |
| Final validation accuracy | 0.445 | 0.447 | 0.446 | — |

Whole-process timing includes cold compilation, loading, validation and checkpoint writing. Native epoch timing is a narrower log scope. These descriptive ratios are not frozen-judge verdicts or a confidence interval.

All three completed-run audits checked 472 finite checkpoint tensors. Similar final metrics do not establish statistical equivalence, held-out biological quality or 150-epoch convergence. Both `quality_accepted` and `four_gate_certified` remain false.

## Implementation and reproduction

The candidate combines grouped data transfers, inverse decoding-order comparisons for neighbor visibility, removal of activation checkpoint recomputation, and dynamic-shape compilation. It preserves the native model, loss and optimizer; both arms use the same explicit worker-seeding wrapper. Memory/compute tradeoffs and compiler-version dependence are documented.

See the case repository's [README](https://github.com/micky-li-hd/Faster-ProteinMPNN#reproduce), [six-epoch records](https://github.com/micky-li-hd/Faster-ProteinMPNN/blob/main/six_epoch_evidence.json), and [recipe](https://github.com/micky-li-hd/Faster-ProteinMPNN/blob/main/six_epoch_recipe.json). Full training data and weights are not redistributed. The case repository retains the upstream MIT license.

The case is shared for reproducibility and future formal task integration. Promotion to an accepted ResearchBoost result would require the existing formulation, negative controls, frozen-judge checks and end-to-end quality requirements; this contribution does not waive them.
