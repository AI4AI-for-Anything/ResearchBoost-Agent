# Contributing

## Contribute a case

1. Run the [Quick start](README.md#quick-start) on your own training code.
2. If you get a solid speedup or a non-trivial optimization trajectory, open a [case submission](https://github.com/AI4AI-for-Anything/ResearchBoost-Agent/issues/new?template=case-submission.yml).
3. We review it. Once it is labelled `accepted`, open a pull request that adds it to [Results](README.md#results).
4. When the pull request is merged, you appear among this repository's contributors.

### What we look for

- **A frozen judge PASS.** `bench.py check` passes (bitwise or statistical) on the original workload, and the judge's hash is the one recorded before optimization started.
- **A real gain or a trajectory worth reading.** A speedup that clears the judge's benefit gate, or rounds that teach something: what was tried, what the judge rejected and why.
- **Reproducibility.** A public repository and commands that reproduce the numbers. Extrapolated numbers are marked as estimates.

Labels: `needs-review` → `accepted` or `changes-requested`. Cases we consider for the benchmark also get `bench-candidate`. We may ask for logs or rerun the judge.

### The pull request

Change only the docs; your code stays in your repository.

- `README.md` and `README.zh-CN.md`: one row in the domain's table, and the counts above it.

  ```markdown
  | [Faster-Project](https://github.com/you/Faster-Project) by [@you](https://github.com/you) | One-line workload | **2.10×** |
  ```

- `docs/results/<domain>.md`: a section in the same layout as the others (speedup, hardware, measurement scope, validation, links).
- `docs/results/README.md`: the project in its domain row, and the counts.

For a domain not listed yet, add a new block in the same form. Commit with an email linked to your GitHub account; otherwise GitHub cannot credit you as a contributor.

## Other contributions

Bug reports, fixes and documentation are welcome as issues or pull requests. Questions: [Discord](https://discord.gg/5k7Rr9hut) or the [WeChat group](docs/assets/wechat-group.png).
