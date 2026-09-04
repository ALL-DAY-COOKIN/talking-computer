#!/usr/bin/env bash
# talking-computer installer — idempotent. Run from anywhere: bash /path/to/talking-computer/install.sh
# What it does:
#   1. checks docker, python3, and an audio player
#   2. starts the Kokoro container (docker compose up -d) and waits for it
#   3. wires every agent it finds: Codex (`notify` in ~/.codex/config.toml) and
#      Claude Code (`Stop` hook in ~/.claude/settings.json)
#   4. installs the SPEAK rule into ~/.codex/AGENTS.md and/or ~/.claude/CLAUDE.md
#   5. the chosen voice says setup is done
# Flags: --agent codex|claude|both   which agent to wire (default: whichever is installed)
#        --hook-only                 wire the hook only; no Docker, no rule, no sound (guide phase 3)
#        --rule-only                 append the rule only; no Docker, no hook, no sound (guide phase 4)
#        (two-machine setups: see remote/README.md)
# With no flags it does everything in order and ends with the wake-up line.
# To pick a voice afterwards: python3 speak.py --audition, then --choose <id> <name>.
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REMOTE=0; DO_NOTIFY=1; DO_CONTRACT=1; DO_DOCKER=1; DO_TEST=1; AGENT=""
prev=""
for a in "$@"; do case "$a" in
  --remote) REMOTE=1;;
  --hook-only|--no-contract) DO_CONTRACT=0; DO_DOCKER=0; DO_TEST=0;;
  --rule-only|--contract-only) DO_NOTIFY=0; DO_DOCKER=0; DO_TEST=0;;
  codex|claude|both) [[ "$prev" == "--agent" ]] && AGENT="$a";;
esac; prev="$a"; done
# detect agents when not told
if [[ -z "$AGENT" ]]; then
  HAVE_CODEX=0; HAVE_CLAUDE=0
  { command -v codex >/dev/null || [[ -d "$CODEX_DIR" ]]; } && HAVE_CODEX=1
  { command -v claude >/dev/null || [[ -d "$CLAUDE_DIR" ]]; } && HAVE_CLAUDE=1
  if [[ $HAVE_CODEX -eq 1 && $HAVE_CLAUDE -eq 1 ]]; then AGENT=both
  elif [[ $HAVE_CLAUDE -eq 1 ]]; then AGENT=claude
  else AGENT=codex; fi
fi
DO_CODEX=0; DO_CLAUDE=0
[[ "$AGENT" == codex || "$AGENT" == both ]] && DO_CODEX=1
[[ "$AGENT" == claude || "$AGENT" == both ]] && DO_CLAUDE=1
REMOTE_URL="http://127.0.0.1:${SPEAK_LISTEN_PORT:-9876}"
say() { printf '\033[0;32m[talking-computer]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[talking-computer] %s\033[0m\n' "$*" >&2; exit 1; }

# 1. prerequisites
if [[ $DO_DOCKER -eq 0 ]]; then
  :
elif [[ $REMOTE -eq 1 ]]; then
  command -v python3 >/dev/null || die "python3 not found."
  say "remote mode: this machine forwards speech to $REMOTE_URL (ssh tunnel to the laptop)"
else
command -v docker >/dev/null || die "docker not found. Install Docker Desktop (Mac/Windows) or docker engine (Linux) and rerun."
docker compose version >/dev/null 2>&1 || die "'docker compose' v2 plugin missing."
command -v python3 >/dev/null || die "python3 not found."
if [[ "$(uname -s)" == "Darwin" ]]; then
  command -v afplay >/dev/null || die "afplay missing (should ship with macOS)."
elif [[ "$(uname -s)" == "Linux" ]]; then
  command -v paplay >/dev/null || command -v aplay >/dev/null || command -v ffplay >/dev/null \
    || say "WARNING: no audio player found. Install one: sudo apt install -y pulseaudio-utils   (or alsa-utils / ffmpeg)"
fi
say "prerequisites OK"
fi
say "agents to wire: $AGENT"

# 2. Kokoro container
if [[ $REMOTE -eq 0 && $DO_DOCKER -eq 1 ]]; then
say "what: starting the Kokoro text-to-speech container   why: it turns the summary text into audio, locally, on :8880"
( cd "$KIT_DIR" && docker compose up -d )
say "waiting for Kokoro on :8880 (first start downloads the model, can take a minute)..."
for _ in $(seq 1 90); do
  if curl -fsS http://127.0.0.1:8880/v1/models >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS http://127.0.0.1:8880/v1/models >/dev/null 2>&1 || die "Kokoro did not come up. Check: docker logs talking-computer-kokoro"
say "Kokoro is up"
say "first sound: the voice introduces itself (speakers on?)"
python3 "$KIT_DIR/speak.py" --hello
fi

# 3. Codex notify hook
if [[ $DO_CODEX -eq 1 && $DO_NOTIFY -eq 1 ]]; then
  say "what: adding one notify line to $CODEX_DIR/config.toml   why: so Codex hands each finished reply to speak.py"
  mkdir -p "$CODEX_DIR"
  CFG="$CODEX_DIR/config.toml"; touch "$CFG"
  if [[ $REMOTE -eq 1 ]]; then
    NOTIFY_LINE="notify = [\"env\", \"SPEAK_REMOTE_URL=$REMOTE_URL\", \"python3\", \"$KIT_DIR/speak.py\", \"--notify\"]"
  else
    NOTIFY_LINE="notify = [\"python3\", \"$KIT_DIR/speak.py\", \"--notify\"]"
  fi
  if grep -qE '^\s*notify\s*=' "$CFG"; then
    python3 - "$CFG" "$NOTIFY_LINE" <<'PY'
import re, sys
path, line = sys.argv[1], sys.argv[2]
src = open(path).read()
src = re.sub(r'^\s*notify\s*=.*$', line, src, count=1, flags=re.M)
open(path, 'w').write(src)
PY
    say "updated existing notify line in $CFG"
  else
    # root-level keys must come before any [table]; prepend.
    { echo "$NOTIFY_LINE"; cat "$CFG"; } > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    say "added notify line to $CFG"
  fi

fi

# 4. AGENTS.md contract
if [[ $DO_CODEX -eq 1 && $DO_CONTRACT -eq 1 ]]; then
  say "what: appending the SPEAK section to $CODEX_DIR/AGENTS.md   why: this is the rule that makes every reply end with a spoken block"
  mkdir -p "$CODEX_DIR"
  AG="$CODEX_DIR/AGENTS.md"; touch "$AG"
  if grep -q '===SPEAK===' "$AG"; then
    say "SPEAK contract already present in $AG"
  else
    { echo; cat "$KIT_DIR/AGENTS.md.snippet"; } >> "$AG"
    say "appended SPEAK contract to $AG"
  fi
fi

# 3b/4b. Claude Code: Stop hook + CLAUDE.md rule
if [[ $DO_CLAUDE -eq 1 ]]; then
  mkdir -p "$CLAUDE_DIR"
  if [[ $DO_NOTIFY -eq 1 ]]; then
    say "what: adding a Stop hook to $CLAUDE_DIR/settings.json   why: so Claude Code hands each finished reply to speak.py"
    SET="$CLAUDE_DIR/settings.json"; [[ -f "$SET" ]] || echo '{}' > "$SET"
    if [[ $REMOTE -eq 1 ]]; then HOOK_CMD="SPEAK_REMOTE_URL=$REMOTE_URL python3 $KIT_DIR/speak.py --stop-hook"
    else HOOK_CMD="python3 $KIT_DIR/speak.py --stop-hook"; fi
    python3 - "$SET" "$HOOK_CMD" <<'PYEOF'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(path))
except Exception:
    cfg = {}
stops = cfg.setdefault("hooks", {}).setdefault("Stop", [])
stops[:] = [s for s in stops if "speak.py --stop-hook" not in json.dumps(s)]
stops.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})
json.dump(cfg, open(path, "w"), indent=2)
PYEOF
    say "Stop hook set in $SET"
  fi
  if [[ $DO_CONTRACT -eq 1 ]]; then
    say "what: appending the SPEAK section to $CLAUDE_DIR/CLAUDE.md   why: this is the rule that makes every reply end with a spoken block"
    CM="$CLAUDE_DIR/CLAUDE.md"; touch "$CM"
    if grep -q '===SPEAK===' "$CM"; then say "SPEAK rule already present in $CM"
    else { echo; cat "$KIT_DIR/AGENTS.md.snippet"; } >> "$CM"; say "appended SPEAK rule to $CM"; fi
  fi
fi

# 5. test
if [[ $DO_TEST -eq 0 ]]; then say "done."; exit 0; fi
say "speaking a test line..."
if [[ $REMOTE -eq 1 ]]; then
  if curl -fsS -m 3 "$REMOTE_URL" >/dev/null 2>&1; then
    curl -s -m 60 -X POST --data-raw "Talking Computer is installed on the server. The tunnel to this laptop works." "$REMOTE_URL" >/dev/null
  else
    say "WARNING: nothing answering on $REMOTE_URL. Open the tunnel from the laptop first (see remote/ssh-config.snippet), then rerun."
  fi
else
  python3 "$KIT_DIR/speak.py" --wakeup
fi
say "done. Log: ~/.talking-computer/speak.log"
say "to pick a different voice: python3 $KIT_DIR/speak.py --audition   then: --choose <id> <name>"
