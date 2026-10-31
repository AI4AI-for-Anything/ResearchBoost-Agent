#!/usr/bin/env python3
"""Kernel utilization and kernel-chain analysis of a GPU trace.

    kernel_util.py TRACE [--device N] [--start-ms A] [--end-ms B] [--peak-bw-gbs B] [--bytes-model FILE]
                         [--short-us 5] [--chain-kernel-us 20] [--chain-gap-us 10] [--min-chain 3]
                         [--max-chain 16] [--top 40]
                         [--out report.md] [--json report.json]

TRACE is a PyTorch profiler (Kineto) Chrome trace (.json / .json.gz, one rank) or an Nsight Systems SQLite export
(`nsys export --type sqlite`; use `--cuda-graph-trace=node` when recording so kernels inside CUDA graphs appear).

Per kernel class (same kernel name) it reports calls, time, median duration, grid size against the SM count
(SM coverage, waves), registers and shared memory, and flags:
  short        median duration below --short-us: fixed launch/prologue/drain cost dominates (launch-bound)
  under-filled median grid covers less than half of the SMs
  tail         1 < blocks/SM < 1.5: the last wave leaves most SMs idle
  bw-poor      with --bytes-model: achieved bandwidth below 30% of --peak-bw-gbs
It also mines repeated chains: kernel-name sequences of --min-chain..--max-chain back-to-back kernels on one
stream (each shorter than --chain-kernel-us, gaps at most --chain-gap-us) that recur at least twice; these are the
fusion candidates. Sub-sequences and rotations of a chain already listed are dropped.

A bytes model is a JSON list of {"match": "<regex on the kernel name>", "bytes": <bytes per call>,
"flops": <optional FLOPs per call>, "note": "..."}; the first matching entry applies. Without it the report cannot
say how far a kernel is from its bandwidth floor, only how it uses the SMs and how much time it spends per launch.
"""
import argparse
import collections
import gzip
import json
import math
import re
import sqlite3
import statistics
import sys
from pathlib import Path

# Nominal HBM bandwidth (bytes/s) by device-name substring; prefer --peak-bw-gbs with a measured value.
PEAK_BW = [("B300", 8.0e12), ("GB300", 8.0e12), ("B200", 8.0e12), ("GB200", 8.0e12), ("H200", 4.8e12),
           ("H100", 3.35e12), ("H20", 4.0e12), ("H800", 3.35e12), ("A100", 2.04e12), ("A800", 2.04e12),
           ("L40S", 0.864e12), ("MI355", 8.0e12), ("MI300X", 5.3e12)]


class Kernel:
    __slots__ = ("name", "start", "dur", "stream", "blocks", "threads", "regs", "smem", "graph")

    def __init__(self, name, start, dur, stream, blocks, threads, regs, smem, graph):
        self.name, self.start, self.dur, self.stream = name, start, dur, stream
        self.blocks, self.threads, self.regs, self.smem, self.graph = blocks, threads, regs, smem, graph


# ------------------------------------------------------------------------------------------------ loading
def load_kineto(path, device):
    op = gzip.open if str(path).endswith(".gz") else open
    with op(path, "rt") as f:
        d = json.load(f)
    ev = d["traceEvents"] if isinstance(d, dict) else d
    props = d.get("deviceProperties", []) if isinstance(d, dict) else []
    kernels, devs = [], collections.Counter()
    for e in ev:
        if e.get("ph") != "X" or e.get("cat") != "kernel":
            continue
        a = e.get("args", {})
        dev = a.get("device", 0)
        devs[dev] += e.get("dur", 0)
        g, b = a.get("grid", [1, 1, 1]), a.get("block", [1, 1, 1])
        kernels.append((dev, Kernel(e["name"], float(e["ts"]), float(e.get("dur", 0)), a.get("stream", 0),
                                    int(math.prod(g)), int(math.prod(b)), a.get("registers per thread"),
                                    a.get("shared memory"), a.get("graph id"))))
    if not kernels:
        sys.exit(f"no kernel events in {path}")
    dev = device if device is not None else devs.most_common(1)[0][0]
    info = next((p for p in props if p.get("id") == dev), props[0] if props else {})
    return [k for d_, k in kernels if d_ == dev], {"device": dev, "name": info.get("name", "?"),
                                                   "sms": info.get("numSms"), "peak_bw": None}


def load_nsys(path, device):
    c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    names = dict(c.execute("SELECT id, value FROM StringIds"))
    devs = c.execute("SELECT deviceId, SUM(end - start) FROM CUPTI_ACTIVITY_KIND_KERNEL GROUP BY deviceId "
                     "ORDER BY 2 DESC").fetchall()
    if not devs:
        sys.exit(f"no kernels in {path}")
    dev = device if device is not None else devs[0][0]
    cols = {r[1] for r in c.execute("PRAGMA table_info(CUPTI_ACTIVITY_KIND_KERNEL)")}
    name_col = "demangledName" if "demangledName" in cols else "shortName"
    graph_col = "graphId" if "graphId" in cols else "NULL"
    rows = c.execute(f"SELECT start, end, streamId, {name_col}, gridX * gridY * gridZ, blockX * blockY * blockZ, "
                     f"registersPerThread, staticSharedMemory + dynamicSharedMemory, {graph_col} "
                     f"FROM CUPTI_ACTIVITY_KIND_KERNEL WHERE deviceId = ? ORDER BY start", (dev,))
    kernels = [Kernel(names.get(n, str(n)), s / 1e3, (e - s) / 1e3, st, gb, tb, r, sm, g)
               for s, e, st, n, gb, tb, r, sm, g in rows]
    info = {"device": dev, "name": "?", "sms": None, "peak_bw": None}
    try:
        r = c.execute("SELECT name, smCount, memoryBandwidth FROM TARGET_INFO_GPU WHERE id = ?", (dev,)).fetchone()
        if r:
            info.update(name=r[0], sms=r[1], peak_bw=float(r[2]) if r[2] else None)
    except sqlite3.Error:
        pass
    try:
        # graphs traced as a whole (nsys --cuda-graph-trace=graph): their kernels are absent from the kernel table
        iv = c.execute("SELECT start, end FROM CUPTI_ACTIVITY_KIND_GRAPH_TRACE WHERE deviceId = ?", (dev,)).fetchall()
        if iv:
            info["graph_level"] = [(s_ / 1e3, e_ / 1e3) for s_, e_ in iv]
    except sqlite3.Error:
        pass
    return kernels, info


# ------------------------------------------------------------------------------------------------ analysis
def _fmt(x, spec):
    return "" if x is None else format(x, spec)


def short_name(n, width=96):
    n = n.replace("|", "/")
    return n if len(n) <= width else n[: width - 3] + "..."


def pct(x, q):
    if not x:
        return 0.0
    s = sorted(x)
    return s[min(len(s) - 1, int(q * (len(s) - 1) + 0.5))]


def union_busy(kernels):
    iv = sorted((k.start, k.start + k.dur) for k in kernels)
    busy, cs, ce = 0.0, None, None
    for s, e in iv:
        if cs is None or s > ce:
            if cs is not None:
                busy += ce - cs
            cs, ce = s, e
        else:
            ce = max(ce, e)
    return busy + (ce - cs if cs is not None else 0.0)


def bytes_model(path):
    if not path:
        return []
    return [(re.compile(m["match"]), m) for m in json.loads(Path(path).read_text())]


def classes(kernels, sms, peak_bw, model, short_us):
    by = collections.defaultdict(list)
    for k in kernels:
        by[k.name].append(k)
    total = sum(k.dur for k in kernels) or 1.0
    out = []
    for name, ks in by.items():
        durs = [k.dur for k in ks]
        blocks = [k.blocks for k in ks]
        med_blocks = statistics.median(blocks)
        cov = statistics.mean(min(1.0, b / sms) for b in blocks) if sms else None
        waves = med_blocks / sms if sms else None
        row = {"name": name, "calls": len(ks), "total_us": sum(durs), "share": sum(durs) / total,
               "median_us": statistics.median(durs), "p90_us": pct(durs, 0.9), "mean_us": statistics.mean(durs),
               "blocks": med_blocks, "threads": statistics.median(k.threads for k in ks),
               "sm_coverage": cov, "waves": waves, "regs": ks[0].regs, "smem": ks[0].smem,
               "in_graph": sum(1 for k in ks if k.graph not in (None, 0)) / len(ks)}
        flags = []
        if row["median_us"] < short_us:
            flags.append("short")
        if cov is not None and cov < 0.5:
            flags.append("under-filled")
        if waves is not None and 1.0 < waves < 1.5:
            flags.append("tail")
        if row["mean_us"] > 2.0 * row["median_us"] and row["calls"] >= 5:
            flags.append("skewed")
        m = next((m for rx, m in model if rx.search(name)), None)
        if m:
            row["bytes"] = m.get("bytes")
            row["flops"] = m.get("flops")
            if row["bytes"]:
                bw = row["bytes"] / (row["median_us"] * 1e-6)
                row["gbs"] = bw / 1e9
                if peak_bw:
                    row["bw_frac"] = bw / peak_bw
                    if row["bw_frac"] < 0.3:
                        flags.append("bw-poor")
        row["flags"] = flags
        out.append(row)
    out.sort(key=lambda r: -r["total_us"])
    return out


def streams(kernels):
    by = collections.defaultdict(list)
    for k in kernels:
        by[k.stream].append(k)
    rows = []
    for s, ks in by.items():
        ks.sort(key=lambda k: k.start)
        gaps = [b.start - (a.start + a.dur) for a, b in zip(ks, ks[1:])]
        pos = [g for g in gaps if g > 0]
        rows.append({"stream": s, "kernels": len(ks), "busy_us": sum(k.dur for k in ks),
                     "gap_us": sum(pos), "gaps_over_1us": sum(1 for g in pos if g > 1.0),
                     "median_gap_us": statistics.median(pos) if pos else 0.0})
    rows.sort(key=lambda r: -r["busy_us"])
    return rows, by


def chains(by_stream, cls_index, kernel_us, gap_us, lmin, lmax, top):
    """Repeated sequences of back-to-back short kernels on one stream, best first, de-duplicated by coverage."""
    cand = []
    for s, ks in by_stream.items():
        n = len(ks)
        ids = [cls_index[k.name] for k in ks]
        # run[i]: how many kernels from i on are short and separated by at most gap_us
        run = [0] * n
        for i in range(n - 1, -1, -1):
            if ks[i].dur >= kernel_us:
                run[i] = 0
            elif i == n - 1 or ks[i + 1].start - (ks[i].start + ks[i].dur) > gap_us:
                run[i] = 1
            else:
                run[i] = 1 + run[i + 1]
        for L in range(lmax, lmin - 1, -1):
            seen = collections.defaultdict(list)
            for i in range(n - L + 1):
                if run[i] >= L:
                    occ = seen[tuple(ids[i:i + L])]
                    if not occ or occ[-1] + L <= i:
                        occ.append(i)
            for key, occ in seen.items():
                if len(occ) < 2:
                    continue
                spans = [ks[i + L - 1].start + ks[i + L - 1].dur - ks[i].start for i in occ]
                sums = [sum(k.dur for k in ks[i:i + L]) for i in occ]
                cand.append({"stream": s, "ids": key, "len": L, "occ": occ, "occurrences": len(occ),
                             "span_us": statistics.mean(spans), "total_us": sum(spans),
                             "kernel_us": statistics.mean(sums)})
    # a candidate whose kernels are mostly inside already kept chains (a sub-sequence or a rotation of a
    # periodic pattern) adds nothing
    cand.sort(key=lambda c: -c["total_us"])
    covered = collections.defaultdict(set)
    kept = []
    for c in cand:
        idx = {i + j for i in c["occ"] for j in range(c["len"])}
        if len(idx & covered[c["stream"]]) > 0.5 * len(idx):
            continue
        covered[c["stream"]] |= idx
        kept.append(c)
        if len(kept) >= top:
            break
    for c in kept:
        del c["occ"]
    return kept


# ------------------------------------------------------------------------------------------------ report
def report(src, info, kernels, cls, strm, ch, args, peak_bw):
    t0 = min(k.start for k in kernels)
    t1 = max(k.start + k.dur for k in kernels)
    window = t1 - t0
    busy = union_busy(kernels)
    ksum = sum(k.dur for k in kernels)
    sms = info["sms"]
    bw_text = f"{peak_bw / 1e12:.2f} TB/s" if peak_bw else "unknown (pass --peak-bw-gbs)"
    L = [f"# Kernel utilization ({Path(src).name})", "",
         f"- device {info['device']} ({info['name']}), SMs: {sms}, peak bandwidth used for ratios: {bw_text}",
         f"- window {window / 1e3:.3f} ms, {len(kernels)} kernels ({len(kernels) / (window / 1e3):.0f} per ms), "
         f"{len(cls)} kernel classes, {len(strm)} streams",
         f"- GPU busy (union of kernels): {busy / 1e3:.3f} ms = {100 * busy / window:.1f}% of the window; "
         f"sum of kernel durations {ksum / 1e3:.3f} ms"]
    if info.get("graph_level"):
        inside = [(max(s_, t0), min(e_, t1)) for s_, e_ in info["graph_level"] if e_ > t0 and s_ < t1]
        cover = union_busy([Kernel("", s_, e_ - s_, 0, 0, 0, None, None, None) for s_, e_ in inside])
        L.append(f"- **warning**: {len(inside)} CUDA graph executions inside the window (covering {cover / 1e3:.3f} ms) "
                 "were traced at graph level; the kernels inside them are missing from every table below. Record with "
                 "`nsys profile --cuda-graph-trace=node`.")
    for flag in ("short", "under-filled", "tail", "skewed", "bw-poor"):
        t = sum(r["total_us"] for r in cls if flag in r["flags"])
        n = sum(r["calls"] for r in cls if flag in r["flags"])
        if t:
            L.append(f"- kernel time in `{flag}` classes: {t / 1e3:.3f} ms ({100 * t / ksum:.1f}%), {n} launches")
    model_rows = [r for r in cls if r.get("bytes")]
    if model_rows:
        b = sum(r["bytes"] * r["calls"] for r in model_rows)
        t = sum(r["total_us"] for r in model_rows)
        L.append(f"- bytes model covers {100 * t / ksum:.1f}% of kernel time: {b / 1e9:.3f} GB moved in "
                 f"{t / 1e3:.3f} ms" + (f", floor at peak {b / peak_bw * 1e3:.3f} ms ({t / 1e3 / (b / peak_bw * 1e3):.1f}x "
                                       "above it)" if peak_bw else ""))
    L += ["", "## Kernel classes (by total time)", "",
          "| kernel | calls | total ms | % | median us | p90 us | blocks | SM cov | waves | regs | smem KB | "
          "GB/s | % peak BW | flags |",
          "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|"]
    for r in cls[: args.top]:
        cells = [f"`{short_name(r['name'])}`", r["calls"], f"{r['total_us'] / 1e3:.3f}", f"{100 * r['share']:.1f}",
                 f"{r['median_us']:.1f}", f"{r['p90_us']:.1f}", f"{r['blocks']:.0f}", _fmt(r["sm_coverage"], ".2f"),
                 _fmt(r["waves"], ".2f"), _fmt(r["regs"], "d"), _fmt(r["smem"] and r["smem"] / 1024, ".1f"),
                 _fmt(r.get("gbs"), ".0f"), _fmt(r.get("bw_frac") and 100 * r["bw_frac"], ".1f"),
                 " ".join(r["flags"])]
        L.append("| " + " | ".join(str(c) for c in cells) + " |")
    names = {i: r["name"] for i, r in enumerate(cls)}
    L += ["", "## Repeated kernel chains (fusion candidates)", "",
          f"Back-to-back kernels on one stream (each shorter than {args.chain_kernel_us:g} us, gaps at most "
          f"{args.chain_gap_us:g} us) that recur as the same sequence. `span` runs from the first kernel's start to the "
          "last kernel's end; `gap share` is the part of the span between kernels (negative: the members overlap in "
          "time, e.g. programmatic dependent launch); `SM cov` is the mean grid coverage "
          "of the members; `flagged` counts members in short or under-filled classes.", "",
          "| # | stream | kernels | occurrences | span us | kernel us | gap share | SM cov | flagged | total ms | "
          "% of kernel time | members |",
          "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|"]
    for i, c in enumerate(ch, 1):
        members = " -> ".join(f"`{short_name(names[j], 40)}`" for j in c["ids"])
        gap = 1 - c["kernel_us"] / c["span_us"] if c["span_us"] else 0
        covs = [cls[j]["sm_coverage"] for j in c["ids"] if cls[j]["sm_coverage"] is not None]
        flagged = sum(1 for j in c["ids"] if {"short", "under-filled"} & set(cls[j]["flags"]))
        L.append(f"| {i} | {c['stream']} | {c['len']} | {c['occurrences']} | {c['span_us']:.1f} | "
                 f"{c['kernel_us']:.1f} | {100 * gap:.0f}% | {_fmt(covs and statistics.mean(covs), '.2f')} | "
                 f"{flagged}/{c['len']} | {c['total_us'] / 1e3:.3f} | {100 * c['total_us'] / ksum:.1f} | {members} |")
    L += ["", "## Streams", "", "| stream | kernels | busy ms | gaps ms | gaps > 1 us | median gap us |",
          "|---:|---:|---:|---:|---:|---:|"]
    for r in strm[:8]:
        L.append(f"| {r['stream']} | {r['kernels']} | {r['busy_us'] / 1e3:.3f} | {r['gap_us'] / 1e3:.3f} | "
                 f"{r['gaps_over_1us']} | {r['median_gap_us']:.1f} |")
    L += ["", "Flags: `short` median < {0:g} us; `under-filled` grid covers < 50% of the SMs; `tail` 1-1.5 "
          "waves at one block per SM; `skewed` mean > 2x median (waiting inside the kernel, e.g. a collective on "
          "a lagging rank or a PDL wait; use the median); `bw-poor` < 30% of peak bandwidth (bytes model).".format(args.short_us),
          "SM coverage and waves assume one resident block per SM; persistent kernels launch one grid per SM by design."]
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--device", type=int, default=None)
    ap.add_argument("--start-ms", type=float, default=None, help="window start, ms after the first kernel")
    ap.add_argument("--end-ms", type=float, default=None, help="window end, ms after the first kernel")
    ap.add_argument("--peak-bw-gbs", type=float, default=None)
    ap.add_argument("--bytes-model", default=None)
    ap.add_argument("--short-us", type=float, default=5.0)
    ap.add_argument("--chain-kernel-us", type=float, default=20.0)
    ap.add_argument("--chain-gap-us", type=float, default=10.0)
    ap.add_argument("--min-chain", type=int, default=3)
    ap.add_argument("--max-chain", type=int, default=16)
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--out", default=None)
    ap.add_argument("--json", default=None)
    a = ap.parse_args()
    src = Path(a.trace)
    kernels, info = (load_nsys if src.suffix in (".sqlite", ".db") else load_kineto)(src, a.device)
    if a.start_ms is not None or a.end_ms is not None:
        t0 = min(k.start for k in kernels)
        lo = t0 + 1e3 * (a.start_ms or 0.0)
        hi = t0 + 1e3 * a.end_ms if a.end_ms is not None else float("inf")
        kernels = [k for k in kernels if lo <= k.start and k.start + k.dur <= hi]
    if not kernels:
        sys.exit("no kernels in the selected window")
    peak_bw = a.peak_bw_gbs * 1e9 if a.peak_bw_gbs else info.get("peak_bw") or next(
        (bw for key, bw in PEAK_BW if key in str(info.get("name", ""))), None)
    cls = classes(kernels, info["sms"], peak_bw, bytes_model(a.bytes_model), a.short_us)
    strm, by_stream = streams(kernels)
    index = {r["name"]: i for i, r in enumerate(cls)}
    ch = chains(by_stream, index, a.chain_kernel_us, a.chain_gap_us, a.min_chain, a.max_chain, a.top)
    text = report(src, info, kernels, cls, strm, ch, a, peak_bw)
    if a.out:
        Path(a.out).write_text(text)
    else:
        sys.stdout.write(text)
    if a.json:
        names = {i: r["name"] for i, r in enumerate(cls)}
        Path(a.json).write_text(json.dumps({"device": info, "peak_bw": peak_bw, "classes": cls, "streams": strm,
                                            "chains": [dict(c, members=[names[j] for j in c["ids"]]) for c in ch]},
                                           indent=1, default=str))


if __name__ == "__main__":
    main()
