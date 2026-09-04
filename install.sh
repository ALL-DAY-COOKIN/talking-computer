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
#        --engine docker|native      voice engine (default: docker if available, else native)
#        --install-docker            install Docker Desktop / Docker Engine first (the guide
#                                    asks the user's permission before passing this)
#        --hook-only                 wire the hook only; no Docker, no rule, no sound (guide phase 3)
#        --rule-only                 append the rule only; no Docker, no hook, no sound (guide phase 4)
#        (two-machine setups: see remote/README.md)
# With no flags it does everything in order and ends with the wake-up line.
# To pick a voice afterwards: python3 speak.py --audition, then --choose <id> <name>.
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REMOTE=0; DO_NOTIFY=1; DO_CONTRACT=1; DO_DOCKER=1; DO_TEST=1; AGENT=""; ENGINE=""; INSTALL_DOCKER=0
prev=""
for a in "$@"; do case "$a" in
  --remote) REMOTE=1;;
  --install-docker) INSTALL_DOCKER=1;;
  docker|native) [[ "$prev" == "--engine" ]] && ENGINE="$a";;
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

docker_ready() { command -v docker >/dev/null && docker info >/dev/null 2>&1; }
mac_major() { [[ "$(uname -s)" == "Darwin" ]] && sw_vers -productVersion | cut -d. -f1 || echo 0; }

install_docker() {
  # Called only when the user has said yes. Installs, then waits for the daemon.
  case "$(uname -s)" in
    Darwin)
      if (( $(mac_major) < 14 )); then say "this Mac is on macOS $(sw_vers -productVersion); Docker Desktop needs 14 or newer. Using the native engine instead."; return 1; fi
      command -v brew >/dev/null || { say "Homebrew not found. Install Docker Desktop from https://docs.docker.com/desktop/setup/install/mac-install/ and rerun, or use the native engine."; return 1; }
      say "what: brew install --cask docker   why: this is Docker Desktop, the app that runs the voice container"
      brew install --cask docker >/dev/null || return 1
      say "opening Docker Desktop. It will ask you to accept its terms the first time; the install continues once it's running."
      open -a Docker || true
      ;;
    Linux)
      if command -v apt-get >/dev/null || command -v dnf >/dev/null; then
        say "Docker Engine needs administrator rights. Run these in your own terminal, then rerun install.sh:"
        say "   curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker \$USER && newgrp docker"
        return 1
      fi
      say "unsupported Linux flavor for automatic install; see https://docs.docker.com/engine/install/"; return 1
      ;;
    *) say "on Windows, install Docker Desktop with WSL2 from https://docs.docker.com/desktop/setup/install/windows-install/"; return 1;;
  esac
  for _ in $(seq 1 90); do docker_ready && return 0; sleep 2; done
  say "Docker installed but the daemon isn't answering yet. Open Docker Desktop, then rerun install.sh."; return 1
}

# 1. prerequisites + engine choice
if [[ $DO_DOCKER -eq 0 ]]; then
  :
elif [[ $REMOTE -eq 1 ]]; then
  command -v python3 >/dev/null || die "python3 not found."
  say "remote mode: this machine forwards speech to $REMOTE_URL (ssh tunnel to the laptop)"
else
  command -v python3 >/dev/null || die "python3 not found."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    command -v afplay >/dev/null || die "afplay missing (should ship with macOS)."
  elif [[ "$(uname -s)" == "Linux" ]]; then
    command -v paplay >/dev/null || command -v aplay >/dev/null || command -v ffplay >/dev/null \
      || say "WARNING: no audio player found. Install one: sudo apt install -y pulseaudio-utils   (or alsa-utils / ffmpeg)"
  fi
  if [[ -z "$ENGINE" ]]; then
    if docker_ready; then ENGINE=docker
    elif [[ $INSTALL_DOCKER -eq 1 ]] && install_docker; then ENGINE=docker
    elif command -v docker >/dev/null && ! docker info >/dev/null 2>&1; then
      die "Docker is installed but not running. Start Docker Desktop (or: sudo systemctl start docker) and rerun. Or: install.sh --engine native"
    else ENGINE=native; fi
  fi
  if [[ "$ENGINE" == docker ]]; then docker compose version >/dev/null 2>&1 || die "'docker compose' v2 plugin missing."; fi
  say "prerequisites OK   engine: $ENGINE"
fi
say "agents to wire: $AGENT"

# 2. voice engine
if [[ $REMOTE -eq 0 && $DO_DOCKER -eq 1 ]]; then
  if [[ "$ENGINE" == docker ]]; then
    say "what: starting the Kokoro text-to-speech container   why: it turns the summary text into audio, locally, on :8880"
    ( cd "$KIT_DIR" && docker compose up -d )
    say "waiting for Kokoro on :8880 (first start downloads the image, can take a few minutes)..."
    for _ in $(seq 1 90); do curl -fsS http://127.0.0.1:8880/v1/models >/dev/null 2>&1 && break; sleep 2; done
    curl -fsS http://127.0.0.1:8880/v1/models >/dev/null 2>&1 || die "Kokoro did not come up. Check: docker logs talking-computer-kokoro"
  else
    say "what: installing the Kokoro voice engine natively (no Docker)   why: same engine, runs straight from source with an isolated Python; on Apple Silicon it uses the Mac GPU"
    bash "$KIT_DIR/native/kokoro-native.sh" install
    bash "$KIT_DIR/native/kokoro-native.sh" start
    bash "$KIT_DIR/native/kokoro-native.sh" autostart >/dev/null 2>&1 || say "note: autostart not installed; run native/kokoro-native.sh start after a reboot"
  fi
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
