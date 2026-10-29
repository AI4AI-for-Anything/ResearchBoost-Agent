# Goal mode: one `/goal` session runs a task unattended

One agent session, Codex or Claude Code, works from `GOAL.md` until it reaches the target, or until a profile shows the target cannot be reached within the rules. It runs in a sandbox that exposes only the task directory and the assigned GPUs, and its only criterion is the frozen judge's `bench.py check`. A separate supervisor (an agent or a person) formulates the task, launches the session and watches it: it intervenes on rules and facts only, never on optimization direction, and keeps its state in the task's `SUPERVISOR.md`. LLaVA and DMD2 were run this way on Codex, one session and 4 GPUs per task. The tools are in [`../goal`](../goal); the step-by-step procedure is in [run-a-task.md](run-a-task.md).

The session runs on [claw-orchestrator](https://github.com/Enderfga/claw-orchestrator) (`clawo`), which drives the engine directly rather than a terminal UI: Codex's app-server, or Claude Code in stream-json mode. The goal is a `/goal` on one thread (a Codex thread, or a Claude Code session): the agent works round after round on its own, `clawo` keeps the thread id on disk, reattaches it after a restart, resumes it after the model endpoint's usage limits, and, when the agent stops, runs the full check itself. That full check, not the agent's own opinion, is the verdict.

![One goal-mode round: profile → edit → time → full check → log](figures/goal-mode-loop.svg)

## Layout

```
$WORK/<task>/
  ws/                  the agent's workspace (a trusted project)
    GOAL.md            the task statement
    GOAL_LINE.txt      the /goal line typed at launch
    WORK_LOG.md        appended by the agent every round
    <code>/            upstream code; the agent edits it on its own branch
    bench/ numerics/ task/ targets/   the frozen judge, read-only in the sandbox
    runs/              the agent's outputs (check.json, profiles, timings); runs/clawo-final/ is the harness's final check
    FINAL.json         written by the agent when it stops: {"tree": …, "config": …}, the candidate to judge
  home/.codex/         config.toml, skills/, sessions/ (rollout jsonl)   (Codex)
  home/.claude/        skills/, projects/ (session jsonl), a copied login if any   (Claude Code)
  engine               codex or claude, written by setup_home.sh
  clawo/               the run: objective.txt, contract.json (the final check), judge.sha256, run_id
  logs/                watchdog logs
  sandbox.env          optional: sourced inside the sandbox before the command (PATH, HF_HOME, offline switches)
$ASSETS                environment, weights, data: read-only in the sandbox
$LOCAL/tmp             the sandbox's /tmp: task-private local disk
$WORK/<task>_formulation/   formulation material (ceiling estimate, acceptance evidence, prep scripts), invisible to the agent
```

## Model access

[`setup_home.sh`](../goal/setup_home.sh) takes the model access the host already has, so a host where `codex` or `claude` works needs no extra setup. For each engine, the first of these it finds (`ENGINE=auto`, the default, takes Codex when Codex access is found, else Claude Code):

| | Codex | Claude Code |
|---|---|---|
| 1 | `goal/codex.env`: `OPENAI_API_KEY`, `OPENAI_BASE_URL`, optionally `CODEX_MODEL` ([template](../goal/codex.env.example)) | `goal/claude.env`: `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_AUTH_TOKEN`, optionally `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` ([template](../goal/claude.env.example)) |
| 2 | `CODEX_AUTH_JSON=<a login's auth.json>` | the same variables in your shell, written to `goal/claude.env` |
| 3 | `OPENAI_API_KEY` in your shell, written to `goal/codex.env` | the host's login, `~/.claude/.credentials.json` (or under `CLAUDE_CONFIG_DIR`), copied into the task's home |
| 4 | the host's login, `~/.codex/auth.json` (or under `CODEX_HOME`), copied into the task's home | |

The env files are git-ignored and written with mode 600; a key passes into the sandbox only through the environment, never on a command line. For Codex, the endpoint and [`config.toml.example`](../goal/codex/config.toml.example) make the task's `config.toml`; with a login, Codex uses its built-in provider. On a headless host without a Claude Code login, `claude setup-token` gives a long-lived token for `CLAUDE_CODE_OAUTH_TOKEN`. Delete the task's home when the run is over if a login was copied into it.

## Sandbox ([`../goal/sandbox/sandbox.sh`](../goal/sandbox/sandbox.sh))

Built on bubblewrap (`SANDBOX_MODE=auto`, the default, picks the first that works: bubblewrap as is; bubblewrap with a user namespace, for a container that is not privileged; the direct mode):
- only the `/dev/nvidiaN` devices assigned to the task are bound, renumbered 0..N-1 inside;
- the home directory is covered by a tmpfs and only `$WORK/<task>` is exposed (writable); `/var/tmp` is covered too, so other tasks' local data is invisible;
- the judge directories (`ws/bench`, `ws/numerics`, `ws/task`, `ws/targets`) and `$ASSETS` are read-only; `PREP=1` opens them for writing during formulation;
- `/tmp` is replaced by `$LOCAL/tmp`;
- the host's `codex`, `claude` and `node` stay usable, even when installed under the hidden home (`~/.local`, `~/.nvm`, an npm prefix): they are linked from `$LOCAL/bin` and what they need is bound read-only;
- model access comes only from the env files and the task's home: `CLAUDE*`, `CODEX_*`, `ANTHROPIC_*` and `OPENAI_*` variables inherited from the host are dropped first. That matters when the agent preparing the task is itself Claude Code or Codex: its session exports variables such as `CLAUDE_CONFIG_DIR` or `CODEX_HOME` that would point the engine at that agent's own configuration. A host that needs some of its own environment for the engine (a proxy's CA, a config directory) re-exports it in `$WORK/<task>/sandbox.env`, which is sourced last;
- `IS_SANDBOX=1` is set, which Claude Code requires to skip permission prompts as root;
- the network is kept by default (`SANDBOX_NET=host`) because the agent has to reach the model endpoint. Training and judging must still run offline: put weights, data and wheels into `$ASSETS` beforehand and set `HF_HUB_OFFLINE=1` in `sandbox.env`. Formulation-only commands can run fully offline with `SANDBOX_NET=none`.

The direct mode, for hosts where no namespace can be created (no bubblewrap, or a container that forbids namespaces): the same home, `/tmp`, working directory, `sandbox.env` and model access, and only the listed GPUs through `CUDA_VISIBLE_DEVICES`, but nothing is hidden and nothing is read-only. The judge is then protected only by the final check, which refuses a verdict when any file under `bench/`, `numerics/` or `task/` changed since launch. `SANDBOX_MODE=bwrap` fails instead of falling back.

A few pitfalls inside containers:
- keep `$ASSETS` on local disk. The training code memory-maps the safetensors weights, and those small random reads from a shared network filesystem (Lustre here) ran at about 9 MB/s, so every timing run spent most of its time loading the model, while a plain `cp` of the same 87 GB took 73 s;
- in a container that is not privileged, bwrap running as root cannot create namespaces (`Creating new namespace failed: Operation not permitted`) even when user namespaces are allowed (`unshare -Ur true` works). The sandbox detects this and adds `--unshare-user --uid 0 --gid 0` itself;
- some containers cannot mount a fresh `/proc` in bwrap, and entering a new PID namespace with the host `/proc` makes CUDA context creation fail (error 304), so the sandbox does not create a PID namespace;
- without network (`SANDBOX_NET=none`) torchrun cannot use `--standalone`; pin `--master-addr 127.0.0.1` instead;
- in containers without access to performance counters `ncu` does not work; use `nsys` and `torch.profiler`.

## Run, resume, supervise ([`../goal/clawo`](../goal/clawo))

`clawo serve` runs on the GPU host, outside the sandbox (claw-orchestrator 7.13.0 or later; for Claude Code, a version whose `clawo goal --help` lists `--engine`). `run.sh` and `resume.sh` start it when it is not running ([`serve.sh`](../goal/clawo/serve.sh)). Everything else is a short script around it:

- [`run.sh`](../goal/clawo/run.sh) `<task> "<gpus>"` with `MIN_SPEEDUP=<the minimum in GOAL.md>`: starts the run on the engine `setup_home.sh` recorded (`ENGINE=` overrides it). The objective is `ws/GOAL_LINE.txt` without the leading `/goal`, plus one sentence asking the agent to name its candidate in `ws/FINAL.json` when it stops. The agent is started inside `sandbox.sh <task> "<gpus>"`. The final check is written by `run.sh`, never by the agent: [`judge.sh`](../goal/clawo/judge.sh) runs `bench.py check` on the candidate in `FINAL.json`, in the sandbox with the same GPUs, and [`accept.py`](../goal/clawo/accept.py) requires `status` PASS, `performance.speedup` ≥ `MIN_SPEEDUP`, and every file under `bench/`, `numerics/` and `task/` byte for byte as it was at launch. If the final check fails, the failure goes back to the same thread once (`MAX_REPAIRS`, default 1). Other knobs: `BENCH` (RAE uses `bench/run.py`), `CHECK_TIMEOUT_MIN` (default 360), `TOKEN_BUDGET`, `GOAL_TIMEOUT_MIN`.
- [`status.sh`](../goal/clawo/status.sh) `<task>`: the run's state, the goal's status, tokens, time, resume attempts and thread id, the number of WORK_LOG rounds, the latest check.
- [`steer.sh`](../goal/clawo/steer.sh) `<task> "<text>"`: a rule-level reminder, delivered into the running turn.
- [`resume.sh`](../goal/clawo/resume.sh) `<task>`: after a host or `clawo serve` restart; it starts `clawo serve` again. The goal continues on the same thread; nothing has to be typed.
- [`stop.sh`](../goal/clawo/stop.sh) `<task>`: interrupts the running turn and pauses the goal.
- [`watch.sh`](../goal/supervise/watch.sh) `<task> "<gpus>"`: the supervisor's background watchdog. It prints one `EVENT` line and exits when the run leaves `running`, the goal was resumed after a stall or a usage limit, WORK_LOG gains a round, the GPUs sit idle for 25 minutes, a full check passes, or disk runs low; the supervisor then takes a look.

What `clawo` handles that used to need hands on a terminal:
- **Usage limits and stalls.** When the endpoint answers "Selected model is at capacity" or a usage limit, or the goal is active with no turn running for 5 minutes, `clawo` sets the goal active again after a backoff (1 minute, doubling to 15), at most 20 times in a row. Each attempt is counted in `status.sh` and reported by `watch.sh`.
- **Restarts.** The thread id is in the run's checkpoint. After a restart, `resume.sh` reattaches it; an engine process that dies mid-run is reopened on the same thread by `clawo` itself. If the thread cannot be resumed, the run fails rather than starting the objective over.
- **Liveness.** The goal's status, token count and time are in the run's checkpoint (`status.sh`). There is no terminal to read.

On Claude Code, `clawo` reads the goal from the CLI's behaviour rather than from goal RPCs ([claw-orchestrator's workflow reference](https://github.com/Enderfga/claw-orchestrator/blob/main/skills/references/workflow.md#on-claude-code)). Two things differ for a task:
- Claude Code's `/goal` condition is judged by a separate model reading the session, which blocks every stop while the condition does not hold. Write `GOAL_LINE.txt` as a condition the agent can show it met from inside (a `check.json` it produced); after nine refused stops in a row the goal ends `blocked`, and the run goes on to the final check.
- A failed login ends the goal as `blocked` at once rather than being retried.

## Supervision rules

- Intervene on rules and facts only: gaps in the task statement, factual mistakes (for example the agent reading "must pass numerical validation" as "forbidden by the rules"), an incomplete final audit, a quick result used as evidence. **Never give optimization direction.**
- If a task "unexpectedly" stopped, **search the whole WORK_LOG for a stop note before restarting** (the note is not necessarily at the end), then check whether another session is operating on the same machine. If it is still unclear, ask the owner; do not restart on your own.
- Treat background events only as a trigger to take a look; check every number against the `check.json` on disk.
- Send reminders with `steer.sh`; they arrive in the turn that is running. After a restart, tell the agent what it missed only if it asks to rerun something it already ran: the full numbers, the report paths, and "do not rerun".
- To change a shell script that is running, write a new file and `mv` it into place (bash reads scripts by byte offset).
- Ports on shared machines: confirm the port is free before starting; the readiness check must confirm the listener is your own process (`ss -ltnp` shows `pid=`).

## Brief for formulation and supervision

When an agent formulates, launches and supervises a task, give it [`../goal/templates/FORMULATOR_BRIEF.md`](../goal/templates/FORMULATOR_BRIEF.md) as the shared brief, and add the task-specific parts in the prompt (upstream repository and commit, target, assigned GPUs). The brief covers: never showing the agent the answer, the data policy, the environment, the judge logic, the formulation acceptance checklist and the supervision rules.
