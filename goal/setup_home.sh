#!/bin/bash
# Prepare $WORK/<task>/home for the sandboxed agent: the engine's configuration and model access, plus the skill
# cards named on the command line (default: all of ../skills). Records the engine in $WORK/<task>/engine, where
# clawo/run.sh reads it.
#   usage: [ENGINE=auto|codex|claude] setup_home.sh <task> [skill ...]
#
# ENGINE=auto (default) takes Codex when Codex model access is found, else Claude Code.
#
# Codex model access, the first one found:
#   - goal/codex.env (OPENAI_API_KEY, OPENAI_BASE_URL, optionally CODEX_MODEL): an OpenAI-compatible endpoint;
#   - CODEX_AUTH_JSON=<path to a Codex login's auth.json>: the ChatGPT login is copied into the task's home
#     (mode 600) and Codex uses its built-in provider. CODEX_MODEL is still honoured;
#   - OPENAI_API_KEY in this shell (OPENAI_BASE_URL defaults to https://api.openai.com/v1): written to
#     goal/codex.env (mode 600, git-ignored), because `clawo serve` does not see this shell's environment;
#   - this host's Codex login, $CODEX_HOME/auth.json (default ~/.codex), as with CODEX_AUTH_JSON.
# Claude Code model access, the first one found:
#   - goal/claude.env (ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN or CLAUDE_CODE_OAUTH_TOKEN; optionally
#     ANTHROPIC_BASE_URL, ANTHROPIC_MODEL);
#   - any of those variables in this shell: written to goal/claude.env (mode 600, git-ignored);
#   - this host's Claude Code login, $CLAUDE_CONFIG_DIR/.credentials.json (default ~/.claude; Linux keeps the login
#     in that file): copied into the task's home (mode 600).
#     A long-lived token for a headless host: `claude setup-token`, then export CLAUDE_CODE_OAUTH_TOKEN.
# A login copied into the task's home should be deleted with the home when the run is over.
set -euo pipefail
TASK=$1; shift
HERE=$(cd "$(dirname "$0")" && pwd)
T=${WORK:?set WORK}/$TASK
CODEX_ENVF=${CODEX_ENV:-$HERE/codex.env}
CLAUDE_ENVF=${CLAUDE_ENV:-$HERE/claude.env}
CLAUDE_VARS="ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN"

# Which model access exists for an engine: prints the source, or nothing.
codex_access() {
  if [ -f "$CODEX_ENVF" ]; then echo env
  elif [ -n "${CODEX_AUTH_JSON:-}" ]; then echo login
  elif [ -n "${OPENAI_API_KEY:-}" ]; then echo shell
  elif [ -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ]; then echo host-login
  fi
}
claude_access() {
  if [ -f "$CLAUDE_ENVF" ]; then echo env; return; fi
  for v in $CLAUDE_VARS; do [ -n "${!v:-}" ] && { echo shell; return; }; done
  if [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]; then echo host-login; fi
}
# Persist variables from this shell into a git-ignored env file the sandbox sources.
write_env() {
  local f=$1; shift
  (umask 077; for v in "$@"; do if [ -n "${!v:-}" ]; then printf '%s=%q\n' "$v" "${!v}"; fi; done > "$f")
  echo "wrote $f from this shell's environment"
}

ENGINE=${ENGINE:-auto}
if [ "$ENGINE" = auto ]; then
  if [ -n "$(codex_access)" ]; then ENGINE=codex
  elif [ -n "$(claude_access)" ]; then ENGINE=claude
  else
    echo "no model access found for Codex or Claude Code; see the header of $0"; exit 1
  fi
fi

SKILLS_SRC=$HERE/../skills
case $ENGINE in
codex)
  C=$T/home/.codex
  [ -L "$C/skills" ] && rm "$C/skills"   # the link a Claude Code setup of this task left
  mkdir -p "$C/skills"
  case $(codex_access) in
    shell) OPENAI_BASE_URL=${OPENAI_BASE_URL:-https://api.openai.com/v1}
           write_env "$CODEX_ENVF" OPENAI_API_KEY OPENAI_BASE_URL CODEX_MODEL; MODE=endpoint ;;
    env) MODE=endpoint ;;
    login) MODE=login ;;
    host-login) CODEX_AUTH_JSON=${CODEX_HOME:-$HOME/.codex}/auth.json; MODE=login ;;
    *) echo "no Codex model access: cp $HERE/codex.env.example $CODEX_ENVF and fill it in, or log in with codex"
       exit 1 ;;
  esac
  if [ $MODE = endpoint ]; then
    set -a; . "$CODEX_ENVF"; set +a
    : "${OPENAI_API_KEY:?set OPENAI_API_KEY in $CODEX_ENVF}" "${OPENAI_BASE_URL:?set OPENAI_BASE_URL in $CODEX_ENVF}"
  else
    [ -f "$CODEX_AUTH_JSON" ] || { echo "CODEX_AUTH_JSON=$CODEX_AUTH_JSON does not exist"; exit 1; }
    install -m 600 "$CODEX_AUTH_JSON" "$C/auth.json"
  fi
  python3 - "$HERE/codex/config.toml.example" "$C/config.toml" "$T/ws" "$MODE" <<'PY'
import os, sys
src, dst, ws, mode = sys.argv[1:]
text = open(src).read()
model = os.environ.get('CODEX_MODEL', '').strip()
if model:
    text = text.replace('{CODEX_MODEL}', model)
else:
    text = '\n'.join(l for l in text.split('\n') if '{CODEX_MODEL}' not in l)
if mode == 'login':
    # Codex's built-in provider with the copied login: drop the custom endpoint.
    out, skip = [], False
    for l in text.split('\n'):
        if l.startswith('[model_providers.'):
            skip = True
            continue
        if skip and l.startswith('['):
            skip = False
        if skip or l.startswith('model_provider '):
            continue
        out.append(l)
    text = '\n'.join(out)
else:
    text = text.replace('{OPENAI_BASE_URL}', os.environ['OPENAI_BASE_URL'])
text = text.replace('{WORKSPACE}', ws)
open(dst, 'w').write(text)
PY
  DONE="wrote $C/config.toml ($MODE)"
  ;;
claude)
  C=$T/home/.claude; mkdir -p "$C/skills"
  case $(claude_access) in
    shell) write_env "$CLAUDE_ENVF" $CLAUDE_VARS ANTHROPIC_BASE_URL ANTHROPIC_MODEL; MODE="env" ;;
    env) MODE="env" ;;
    host-login) install -m 600 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" "$C/.credentials.json"; MODE=login ;;
    *) echo "no Claude Code model access: cp $HERE/claude.env.example $CLAUDE_ENVF and fill it in, or log in with claude"
       exit 1 ;;
  esac
  # A fresh home would otherwise start with onboarding and ask to trust the workspace.
  [ -f "$T/home/.claude.json" ] || python3 - "$T/home/.claude.json" "$T/ws" <<'PY'
import json, sys
dst, ws = sys.argv[1:]
json.dump({'hasCompletedOnboarding': True, 'projects': {ws: {'hasTrustDialogAccepted': True}}}, open(dst, 'w'))
PY
  # Task material names ~/.codex/skills; on Claude Code the same cards are its own skills.
  mkdir -p "$T/home/.codex"
  [ -d "$T/home/.codex/skills" ] && [ ! -L "$T/home/.codex/skills" ] || ln -sfn ../.claude/skills "$T/home/.codex/skills"
  DONE="wrote $C ($MODE)"
  ;;
*) echo "ENGINE must be auto, codex or claude"; exit 1 ;;
esac

for s in ${@:-$(ls "$SKILLS_SRC")}; do
  [ -f "$SKILLS_SRC/$s/SKILL.md" ] && cp -r "$SKILLS_SRC/$s" "$C/skills/"
done
echo "$ENGINE" > "$T/engine"
echo "$DONE; engine $ENGINE; skills: $(ls "$C/skills" | tr '\n' ' ')"
