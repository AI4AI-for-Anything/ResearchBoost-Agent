#!/bin/bash
# Prepare $WORK/<task>/home/.codex for the sandboxed agent: config.toml from codex/config.toml.example, plus the
# skill cards named on the command line (default: all of ../skills).
#   usage: setup_home.sh <task> [skill ...]
#
# Model access, one of:
#   - goal/codex.env (OPENAI_API_KEY, OPENAI_BASE_URL, optionally CODEX_MODEL): an OpenAI-compatible endpoint;
#   - CODEX_AUTH_JSON=<path to a Codex login's auth.json> and no codex.env: the ChatGPT login is copied into the
#     task's home (mode 600) and Codex uses its built-in provider. CODEX_MODEL is still honoured.
set -euo pipefail
TASK=$1; shift
HERE=$(cd "$(dirname "$0")" && pwd)
T=${WORK:?set WORK}/$TASK
ENVF=${CODEX_ENV:-$HERE/codex.env}
C=$T/home/.codex; mkdir -p "$C/skills"
if [ -f "$ENVF" ]; then
  MODE=endpoint
  set -a; . "$ENVF"; set +a
  : "${OPENAI_API_KEY:?set OPENAI_API_KEY in $ENVF}" "${OPENAI_BASE_URL:?set OPENAI_BASE_URL in $ENVF}"
elif [ -n "${CODEX_AUTH_JSON:-}" ]; then
  MODE=login
  [ -f "$CODEX_AUTH_JSON" ] || { echo "CODEX_AUTH_JSON=$CODEX_AUTH_JSON does not exist"; exit 1; }
  install -m 600 "$CODEX_AUTH_JSON" "$C/auth.json"
else
  echo "missing $ENVF: cp $HERE/codex.env.example $HERE/codex.env and fill it in, or set CODEX_AUTH_JSON"
  exit 1
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
SKILLS=$HERE/../skills
for s in ${@:-$(ls "$SKILLS")}; do
  [ -f "$SKILLS/$s/SKILL.md" ] && cp -r "$SKILLS/$s" "$C/skills/"
done
echo "wrote $C/config.toml ($MODE); skills: $(ls "$C/skills" | tr '\n' ' ')"
