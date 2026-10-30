"""Record a correctness case: every step becomes a table of named tensors plus exact invariants.

Names (the judge's only interface):
  loss/<name>                              returned by Adapter.step                    (forward class)
  out/<model>.<submodule>#<call>           outputs of modules matching capture_outputs (forward class)
  grad/<optimizer>#<call>/<model>.<param>  gradient seen by optimizer.step            (backward class)
  delta/<optimizer>#<call>/<model>.<param> parameter change made by that step         (backward class)
  optim/<optimizer>/<model>.<param>/<key>  optimizer state after the step             (backward class)
  ema/<ema>.<tensor>                       EMA state after the step                   (backward class)
  buffer/<model>.<buffer>                  model buffers after the step               (backward class)
Exact per step: phase, RNG fingerprints before/after, call counters, adapter invariants, learning rates,
and (multi-rank) which tensors are identical across ranks.
"""
from collections import defaultdict
from contextlib import nullcontext
import fnmatch
import hashlib
import json
from pathlib import Path
import random

import torch
from torch.utils._python_dispatch import TorchDispatchMode

FWD_KINDS = ('loss', 'out')
PARAM_KINDS = ('grad', 'delta', 'optim', 'ema', 'buffer')


def tensor_sha(t):
    t = t.detach().contiguous().cpu().reshape(-1)
    return hashlib.sha256(t.view(torch.uint8).numpy().tobytes() if t.numel() else b'').hexdigest()


def rng_fingerprint():
    h = hashlib.sha256(torch.get_rng_state().numpy().tobytes())
    if torch.cuda.is_available() and torch.cuda.is_initialized():
        for state in torch.cuda.get_rng_state_all():
            h.update(state.numpy().tobytes())
    h.update(repr(random.getstate()).encode())
    try:
        import numpy as np
        kind, keys, pos, has_gauss, cached = np.random.get_state()
        h.update(keys.tobytes() + repr((kind, pos, has_gauss, cached)).encode())
    except ImportError:
        pass
    return h.hexdigest()[:24]


_MASK63 = (1 << 63) - 1


def _mix(x):
    """splitmix64-style integer mixing on int64 tensors (wrap-around arithmetic, identical on any device)."""
    x = x ^ (x >> 31)
    x = x * 0x7FB5D329728EA185
    x = x ^ (x >> 27)
    x = x * 0x01C3F7A2F84F3A35
    return x ^ (x >> 33)


def countsketch(t, k, name):
    """Linear k-dim CountSketch of t. Bucket and sign of element i come from an integer hash of
    (name, numel, i), so reference, candidate and fp64 runs share the sketch on any device.
    ||S(a) - S(b)|| estimates ||a - b|| with relative std ~ sqrt(2/k)."""
    flat = t.detach().reshape(-1)
    n = flat.numel()
    salt = int(hashlib.sha256(f'{name}|{n}'.encode()).hexdigest()[:15], 16) & _MASK63
    out = torch.zeros(k, dtype=torch.float64, device=flat.device)
    chunk = 1 << 24
    for start in range(0, n, chunk):
        m = min(chunk, n - start)
        h = _mix(torch.arange(start, start + m, dtype=torch.int64, device=flat.device) ^ salt)
        idx = (h & _MASK63) % k
        sign = ((h >> 7) & 1).to(torch.float64) * 2 - 1
        out.index_add_(0, idx, flat[start:start + m].double() * sign)
    return out.cpu()


def math_mode():
    """Process-wide numeric mode switches that change results without changing any dtype."""
    b, mode = torch.backends, {}
    for label, get in (('matmul.allow_tf32', lambda: b.cuda.matmul.allow_tf32),
                       ('cudnn.allow_tf32', lambda: b.cudnn.allow_tf32),
                       ('float32_matmul_precision', torch.get_float32_matmul_precision),
                       ('matmul.fp16_reduced_precision_reduction',
                        lambda: b.cuda.matmul.allow_fp16_reduced_precision_reduction),
                       ('matmul.bf16_reduced_precision_reduction',
                        lambda: b.cuda.matmul.allow_bf16_reduced_precision_reduction),
                       ('sdp.flash', b.cuda.flash_sdp_enabled), ('sdp.mem_efficient', b.cuda.mem_efficient_sdp_enabled),
                       ('sdp.math', b.cuda.math_sdp_enabled), ('cudnn.deterministic', lambda: b.cudnn.deterministic),
                       ('deterministic_algorithms', torch.are_deterministic_algorithms_enabled)):
        try:
            mode[label] = get()
        except (AttributeError, RuntimeError):
            continue
    return mode


def set_math_mode(name):
    """Fix the run's math mode before the adapter builds anything ('default' leaves torch's defaults)."""
    if name == 'tf32':
        torch.backends.cuda.matmul.allow_tf32 = True
        torch.backends.cudnn.allow_tf32 = True
    elif name != 'default':
        raise ValueError(f'unknown math mode {name!r}')


def set_deterministic():
    """Deterministic kernels where torch has them, so two runs of the same code take the same numeric path and
    a bitwise (N0) comparison means something. Call before the first CUDA/cuBLAS use."""
    import os
    os.environ.setdefault('CUBLAS_WORKSPACE_CONFIG', ':4096:8')
    torch.use_deterministic_algorithms(True, warn_only=True)
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False


def seed_everything(seed):
    """Every case starts from seeded RNG streams, including ones the task never seeds itself."""
    random.seed(seed)
    torch.manual_seed(seed)
    try:
        import numpy as np
        np.random.seed(seed % 2**32)
    except ImportError:
        pass


def describe(kind, t):
    floating = t.is_floating_point() or t.is_complex()
    return {'kind': kind, 'dtype': str(t.dtype).replace('torch.', ''), 'shape': list(t.shape), 'sha256': tensor_sha(t),
            'norm': float(t.detach().double().norm()) if floating else None,
            'finite': bool(torch.isfinite(t).all()) if floating else True}


# A traced step runs under a TorchDispatchMode, and torch.compile'd regions fall back to eager inside it: the
# traced step does not exercise compiled code, so it cannot support a bitwise (N0) claim (see judge.compare).
class DtypeTrace(TorchDispatchMode):
    """Counts (op, output dtype) pairs in eager code. Compiled graphs are opaque to it; T0 must also diff
    the generated code / kernel inventory for compiled paths."""

    def __init__(self):
        super().__init__()
        self.counts = defaultdict(int)

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        out = func(*args, **(kwargs or {}))
        for item in (out if isinstance(out, (tuple, list)) else (out,)):
            if isinstance(item, torch.Tensor) and item.is_floating_point():
                self.counts[f'{func}:{str(item.dtype).replace("torch.", "")}'] += 1
        return out


def first_tensor(value):
    if isinstance(value, torch.Tensor):
        return value
    if isinstance(value, (tuple, list)):
        for item in value:
            found = first_tensor(item)
            if found is not None:
                return found
    if isinstance(value, dict):
        for item in value.values():
            found = first_tensor(item)
            if found is not None:
                return found
    return None


def dist_info():
    if torch.distributed.is_available() and torch.distributed.is_initialized():
        return torch.distributed.get_rank(), torch.distributed.get_world_size()
    return 0, 1


class Recorder:
    def __init__(self, adapter, out_dir, golden=False, dtype_trace=False, sketch_dim=0, losses_only=False):
        """sketch_dim > 0 stores tensors larger than sketch_dim as CountSketches (exact norm and hash kept).
        losses_only records a training trajectory: per-step losses only, no hooks, no tensors."""
        self.adapter, self.out = adapter, Path(out_dir)
        self.golden, self.dtype_trace, self.sketch_dim = golden, dtype_trace, sketch_dim
        self.losses_only = losses_only
        self.out.mkdir(parents=True, exist_ok=True)

    def run(self, case):
        """case: {'name', 'seed', 'steps', 'phases': [phase per step] or 'phase', 'state': optional path}."""
        a = self.adapter
        name, steps = case['name'], int(case['steps'])
        phases = case.get('phases') or [case.get('phase', a.phases()[0])] * steps
        if len(phases) != steps:
            raise ValueError(f'case {name}: {len(phases)} phases for {steps} steps')
        seed_everything(case.get('seed', 0))
        a.configure(case)
        a.build(case.get('seed', 0), golden=self.golden)
        if case.get('state'):
            a.load_state(case['state'])
        rank, world = dist_info()
        if self.losses_only:
            return self._trajectory(a, case, name, steps, phases, rank, world)
        objs = a.objects()
        names = {}
        for m, module in objs.models.items():
            for pn, p in module.named_parameters():
                names.setdefault(id(p), f'{m}.{pn}')
        counters = defaultdict(int)
        pending, lrs, handles = {}, {}, []

        def count_forward(model):
            def hook(*_):
                counters[f'forward/{model}'] += 1
            return hook

        def capture(full):
            def hook(_module, _inputs, output):
                t = first_tensor(output)
                if t is not None:
                    call = counters[f'out_calls/{full}']
                    pending[f'out/{full}#{call}'] = t.detach().clone()
                counters[f'out_calls/{full}'] += 1
            return hook

        for m, module in objs.models.items():
            if objs.count_forwards:
                handles.append(module.register_forward_hook(count_forward(m)))
            for sub, child in module.named_modules():
                full = f'{m}.{sub}' if sub else m
                if any(fnmatch.fnmatch(full, pattern) for pattern in objs.capture_outputs):
                    handles.append(child.register_forward_hook(capture(full)))

        before = {}

        def pre_step(o):
            def hook(opt, *_):
                call = counters[f'optimizer_step/{o}']
                for gi, group in enumerate(opt.param_groups):
                    lrs[f'lr/{o}#{call}/group{gi}'] = float(group['lr'])
                    for pi, p in enumerate(group['params']):
                        pname = names.get(id(p), f'{o}.group{gi}.param{pi}')
                        if p.grad is not None:
                            pending[f'grad/{o}#{call}/{pname}'] = p.grad.detach().clone()
                        before[(o, pname)] = p.detach().clone()
            return hook

        def post_step(o):
            def hook(opt, *_):
                call = counters[f'optimizer_step/{o}']
                for gi, group in enumerate(opt.param_groups):
                    for pi, p in enumerate(group['params']):
                        pname = names.get(id(p), f'{o}.group{gi}.param{pi}')
                        pending[f'delta/{o}#{call}/{pname}'] = p.detach() - before.pop((o, pname))
                counters[f'optimizer_step/{o}'] += 1
            return hook

        for o, opt in objs.optimizers.items():
            handles.append(opt.register_step_pre_hook(pre_step(o)))
            handles.append(opt.register_step_post_hook(post_step(o)))

        manifest = {'schema': 'numerics-record@1', 'adapter': a.name, 'case': case, 'golden': self.golden,
                    'rank': rank, 'world_size': world, 'torch': torch.__version__,
                    'sync': dict(objs.sync), 'sketch_dim': self.sketch_dim, 'steps': [], 'dtype_ops': None}
        try:
            for i in range(steps):
                a.set_phase(phases[i], i)
                rng_before = rng_fingerprint()
                batch = a.batch(i, rank)
                pending.clear()
                lrs.clear()
                counted = dict(counters)
                trace = DtypeTrace() if self.dtype_trace and i == 0 else None
                with trace if trace is not None else nullcontext():
                    losses = a.step(i, batch)
                if torch.cuda.is_available() and torch.cuda.is_initialized():
                    torch.cuda.synchronize()
                if trace is not None:
                    manifest['dtype_ops'] = dict(sorted(trace.counts.items()))
                tensors = dict(pending)
                for key, value in (losses or {}).items():
                    tensors[f'loss/{key}'] = torch.as_tensor(value).detach().clone()
                for o, opt in objs.optimizers.items():
                    for p, state in opt.state.items():
                        pname = names.get(id(p), f'{o}.param{id(p)}')
                        for sk, sv in state.items():
                            if isinstance(sv, torch.Tensor):
                                tensors[f'optim/{o}/{pname}/{sk}'] = sv.detach().clone()
                for e, module in objs.ema.items():
                    for tn, tv in module.state_dict().items():
                        tensors[f'ema/{e}.{tn}'] = tv.detach().clone()
                for m, module in objs.models.items():
                    for bn, bv in module.named_buffers():
                        tensors[f'buffer/{m}.{bn}'] = bv.detach().clone()
                mapped = {}
                for tname, tv in tensors.items():
                    for cname, cv in a.canonical(tname.split('/', 1)[0], tname, tv).items():
                        mapped[cname] = cv.detach()
                described = {n: describe(n.split('/', 1)[0], t) for n, t in sorted(mapped.items())}
                stored = {}
                for n, t in mapped.items():
                    sketch = self.sketch_dim and t.is_floating_point() and t.numel() > self.sketch_dim
                    stored[n] = countsketch(t, self.sketch_dim, n) if sketch else t.cpu()
                    described[n]['stored'] = 'sketch' if sketch else 'full'
                entry = {'step': i, 'phase': phases[i], 'rng_before': rng_before, 'rng_after': rng_fingerprint(),
                         'counters': {k: v - counted.get(k, 0) for k, v in sorted(counters.items())
                                      if v - counted.get(k, 0) and not k.startswith('out_calls/')},
                         'invariants': {**{k: v for k, v in sorted(a.invariants().items())}, **dict(sorted(lrs.items()))},
                         'math_mode': math_mode(), 'dtype_traced': trace is not None, 'tensors': described}
                if world > 1:
                    shas = {n: d['sha256'] for n, d in entry['tensors'].items() if d['kind'] in PARAM_KINDS}
                    gathered = [None] * world
                    torch.distributed.all_gather_object(gathered, shas)
                    entry['xrank_equal'] = {n: len({g.get(n) for g in gathered}) == 1 for n in shas}
                torch.save(stored, self.out / f'{name}.r{rank}.s{i}.pt')
                manifest['steps'].append(entry)
                # The step's clones (gradients, updates, optimizer state, EMA) live on the device; drop them before
                # the next step runs, which may need that memory (a large model's optimizer state alone can be
                # tens of GB per GPU).
                pending.clear()
                tensors.clear()
                mapped.clear()
                stored.clear()
        finally:
            for handle in handles:
                handle.remove()
        (self.out / f'{name}.r{rank}.json').write_text(json.dumps(manifest, indent=1) + '\n')
        return manifest

    def _trajectory(self, a, case, name, steps, phases, rank, world):
        held = []
        for i in range(steps):
            a.set_phase(phases[i], i)
            losses = a.step(i, a.batch(i, rank))
            # keep device tensors; converting every step would add a host sync per step
            held.append({k: torch.as_tensor(v).detach().clone() for k, v in (losses or {}).items()})
        manifest = {'schema': 'numerics-trajectory@1', 'adapter': a.name, 'case': case, 'rank': rank,
                    'world_size': world, 'torch': torch.__version__, 'math_mode': math_mode(),
                    'steps': [{'step': i, 'phase': phases[i], 'losses': {k: float(v.double()) for k, v in h.items()}}
                              for i, h in enumerate(held)]}
        (self.out / f'{name}.r{rank}.json').write_text(json.dumps(manifest, indent=1) + '\n')
        return manifest
