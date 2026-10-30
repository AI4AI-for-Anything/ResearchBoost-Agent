#!/bin/bash
# Run a command (default: the agent's TUI) for one optimization task inside a sandbox on a shared GPU host.
#   sandbox.sh <task> "<gpu indices>" [command ...]
#   task: a directory under $WORK (e.g. llava, dmd); GPUs: host indices, e.g. "0 1 2 3".
#
# Variables:
#   WORK          directory holding one directory per task: $WORK/<task>/{ws,home,logs}   (required)
#   ASSETS        the task's environment, weights and data, read-only inside   (default $WORK/<task>/assets)
#   LOCAL         task-private local disk; $LOCAL/tmp becomes the sandbox's /tmp   (default /var/tmp/goal/<task>)
#   CODEX_ENV     model access for Codex: OPENAI_API_KEY, OPENAI_BASE_URL, CODEX_MODEL   (default ../codex.env)
#   CLAUDE_ENV    model access for Claude Code: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN, ...   (default ../claude.env)
#   SANDBOX_MODE  auto (default): bubblewrap, adding a user namespace where the container needs one, and without
#                 bubblewrap the direct mode; bwrap: bubblewrap or fail; direct: no namespaces (see below)
#   SANDBOX_NET   host (default): keep the host network, which the agent needs to reach the model endpoint;
#                 none: own network namespace, fully offline (formulation commands only, the agent cannot run)
#   TOOLS         optional directory with node/codex/claude binaries, bound read-only and put first on PATH;
#                 without it, the host's codex, claude and node are found on PATH and made visible
#   PREP=1        formulation mode: ws/{bench,numerics,task,targets} stay writable
#   RO_PATHS      host paths bound read-only (bubblewrap) before the task's own mounts: on a shared host, the
#                 shared filesystems and the local disk other users' data lives on (the task's own $WORK/<task>,
#                 $ASSETS and $LOCAL beneath them keep their modes), e.g. RO_PATHS="/fsx /opt/dlami/nvme"
#   BWRAP         bubblewrap binary (default: bwrap on PATH)
#
# What the sandbox sees (bubblewrap):
#   - only the listed GPUs (other /dev/nvidiaN are not bound; inside they are cuda:0..N-1);
#   - the home directory is hidden; only $WORK/<task> (read-write), $TOOLS and the engine CLIs (read-only) are visible;
#   - /tmp = $LOCAL/tmp; /var/tmp is hidden, so other tasks' local data is not visible; $ASSETS is read-only;
#   - read-only inside the workspace (unless PREP=1): ws/bench ws/numerics ws/task ws/targets;
#   - HOME=$WORK/<task>/home (agent config and skills in $HOME/.codex or $HOME/.claude, see setup_home.sh);
#   - model access only from the env files: inherited CLAUDE*, CODEX_*, ANTHROPIC_* and OPENAI_* variables are
#     dropped. A host whose engine needs more of its own environment (a config directory, a proxy's CA)
#     re-exports it in $WORK/<task>/sandbox.env, which is sourced last.
# No PID namespace: in some containers bwrap cannot mount a fresh /proc, and with the host /proc in a new PID
# namespace the CUDA driver fails to create a context (cudaErrorOperatingSystem 304).
#
# Direct mode, for hosts where no namespace can be created (no bubblewrap, or a container that forbids them):
# the same HOME, TMPDIR, working directory and sandbox.env, and only the listed GPUs through CUDA_VISIBLE_DEVICES.
# Nothing is hidden and nothing is read-only; the judge is protected only by the final check, which refuses a
# verdict when any file under bench/, numerics/ or task/ changed since launch (goal/clawo/accept.py).
set -euo pipefail
TASK=$1; GPUS=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
T=${WORK:?set WORK}/$TASK
A=${ASSETS:-$T/assets}
L=${LOCAL:-/var/tmp/goal/$TASK}
[ -d "$T/ws" ] || { echo "no workspace $T/ws"; exit 1; }
mkdir -p "$L/tmp" "$A" "$T/home"
B=${BWRAP:-bwrap}

ENVFILES=("${CODEX_ENV:-$HERE/../codex.env}" "${CLAUDE_ENV:-$HERE/../claude.env}")
# Model access comes from the env files only. The agent that set the task up may itself be Claude Code or Codex,
# and its session exports variables (CLAUDE_CONFIG_DIR, CLAUDECODE, CODEX_HOME, ...) that would point the engine
# at that agent's own config, hidden inside, instead of the task's home.
for v in $(compgen -e | grep -E '^(CLAUDE|CODEX_|ANTHROPIC_|OPENAI_)' || true); do unset "$v"; done
# model access: exported here and inherited by the sandboxed command (not put on the command line, where any user
# could read a key in the process list)
for f in "${ENVFILES[@]}"; do
  if [ -f "$f" ]; then set -a; . "$f"; set +a; fi
done
export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# The engine CLIs. The home directory is hidden inside, and that is where codex, claude and node often live
# (~/.local/bin, ~/.nvm, ~/.npm-global): link each one found on PATH from a task-local bin directory, and bind
# what its real path needs (the directory two levels above it: the claude install, the node version, the codex
# package) read-only.
P=/usr/local/bin:/usr/bin:/bin
ro=()
if [ -n "${TOOLS:-}" ]; then
  ro+=("$TOOLS"); P=$TOOLS/bin:$TOOLS:$P
else
  mkdir -p "$L/bin"
  for b in codex claude node; do
    p=$(command -v "$b" 2>/dev/null) || continue
    real=$(readlink -f "$p")
    ln -sfn "$real" "$L/bin/$b"
    case $real in "$HOME"/*) ro+=("$(dirname "$(dirname "$real")")") ;; esac
  done
  ro+=("$L/bin"); P=$L/bin:$P
fi

[ $# -gt 0 ] || set -- "${AGENT_TUI:-codex}"
INNER='[ -f "$WORK/'"$TASK"'/sandbox.env" ] && . "$WORK/'"$TASK"'/sandbox.env"; exec "$@"'

mode=${SANDBOX_MODE:-auto}
userns=()
if [ "$mode" = auto ]; then
  if ! command -v "$B" >/dev/null 2>&1; then
    mode=direct
  elif "$B" --dev-bind / / true 2>/dev/null; then
    mode=bwrap
  elif "$B" --unshare-user --uid 0 --gid 0 --dev-bind / / true 2>/dev/null; then
    # a container that is not privileged: bwrap as root cannot create namespaces without a user namespace
    mode=bwrap; userns=(--unshare-user --uid 0 --gid 0)
  else
    mode=direct
  fi
fi

if [ "$mode" = direct ]; then
  echo "sandbox.sh: direct mode (no namespaces): $TASK sees the whole host; the judge is guarded by its hashes only" >&2
  vis=$(echo $GPUS | tr ' ' ',')
  cd "$T/ws"
  exec env HOME="$T/home" TMPDIR="$L/tmp" WORK="$WORK" ASSETS="$A" PATH="$P:$PATH" CUDA_VISIBLE_DEVICES="$vis" \
    bash -c "$INNER" bash "$@"
fi
[ "$mode" = bwrap ] || { echo "SANDBOX_MODE must be auto, bwrap or direct"; exit 1; }

# Mounts apply in order: the directories that cover others (home, /var/tmp, /tmp) first, then the task's own,
# so a $WORK or $ASSETS under one of them is not hidden by it.
ro_first=()
for d in ${RO_PATHS:-}; do [ -e "$d" ] && ro_first+=(--ro-bind "$d" "$d"); done
args=(${userns[@]+"${userns[@]}"} --die-with-parent --dev-bind / / --dev /dev ${ro_first[@]+"${ro_first[@]}"}
      --tmpfs "$HOME" --tmpfs /var/tmp --bind "$L/tmp" /tmp
      --bind "$T" "$T" --ro-bind "$A" "$A")
case ${SANDBOX_NET:-host} in
  host) ;;
  none) args+=(--unshare-net) ;;
  *) echo "SANDBOX_NET must be host or none"; exit 1 ;;
esac
for d in nvidiactl nvidia-uvm nvidia-uvm-tools nvidia-modeset nvidia-caps; do
  [ -e /dev/$d ] && args+=(--dev-bind /dev/$d /dev/$d)
done
for g in $GPUS; do args+=(--dev-bind /dev/nvidia$g /dev/nvidia$g); done
if [ "${PREP:-0}" != 1 ]; then
  for p in bench numerics task targets; do [ -e "$T/ws/$p" ] && args+=(--ro-bind "$T/ws/$p" "$T/ws/$p"); done
fi
for d in ${ro[@]+"${ro[@]}"}; do args+=(--ro-bind "$d" "$d"); done
[ -f "$T/sandbox.env" ] && args+=(--ro-bind "$T/sandbox.env" "$T/sandbox.env")
# Claude Code refuses to skip permission prompts as root unless it is told it runs in a sandbox, which it does here.
exec "$B" "${args[@]}" --chdir "$T/ws" --setenv HOME "$T/home" --setenv TMPDIR /tmp \
  --setenv WORK "$WORK" --setenv ASSETS "$A" --setenv PATH "$P" --setenv IS_SANDBOX 1 \
  bash -c "$INNER" bash "$@"
