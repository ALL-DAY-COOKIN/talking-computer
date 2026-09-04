#!/usr/bin/env bash
# Run the Kokoro voice engine WITHOUT Docker, from the Kokoro-FastAPI source,
# using uv. Same API on http://127.0.0.1:8880 as the container, so speak.py
# doesn't care which one is running. On Apple Silicon it uses the Mac GPU (MPS).
#
#   native/kokoro-native.sh install    clone + create venv + install deps + download model (one time, ~5 min)
#   native/kokoro-native.sh start      start in the background (pid + log in ~/.talking-computer/)
#   native/kokoro-native.sh stop
#   native/kokoro-native.sh status
#   native/kokoro-native.sh autostart  keep it running across logins (launchd on macOS, systemd --user on Linux)
set -euo pipefail
TC_HOME="${TC_HOME:-$HOME/.talking-computer}"
SRC="$TC_HOME/kokoro-fastapi"
TAG="v0.8.1"
PORT=${KOKORO_PORT:-8880}
PID_FILE="$TC_HOME/kokoro.pid"
LOG="$TC_HOME/kokoro.log"
say() { printf '\033[0;32m[talking-computer]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[talking-computer] %s\033[0m\n' "$*" >&2; exit 1; }
OS="$(uname -s)"; ARCH="$(uname -m)"

ensure_uv() {
  if command -v uv >/dev/null; then return; fi
  say "what: installing uv (a fast Python package manager, one small binary in ~/.local/bin)   why: it builds Kokoro's isolated environment without touching your system Python"
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null || die "uv did not install. See https://docs.astral.sh/uv/"
}

ensure_espeak() {
  if command -v espeak-ng >/dev/null; then return; fi
  if [[ "$OS" == "Darwin" ]] && command -v brew >/dev/null; then
    say "what: installing espeak-ng with Homebrew   why: Kokoro uses it to pronounce unusual words"
    brew install espeak-ng >/dev/null
  elif [[ "$OS" == "Linux" ]] && command -v apt-get >/dev/null; then
    say "espeak-ng missing. Run:  sudo apt-get install -y espeak-ng   then rerun. (Kokoro uses it to pronounce unusual words.)"
  else
    say "WARNING: espeak-ng not found; most text still works, rare words may be skipped."
  fi
}

env_for_run() {
  export PYTHONPATH="$SRC:$SRC/api" MODEL_DIR=src/models VOICES_DIR=src/voices/v1_0 WEB_PLAYER_PATH="$SRC/web"
  if [[ "$OS" == "Darwin" && "$ARCH" == "arm64" ]]; then
    export USE_GPU=true DEVICE_TYPE=mps PYTORCH_ENABLE_MPS_FALLBACK=1
  else
    export USE_GPU=false
  fi
  if [[ "$OS" == "Darwin" ]] && command -v brew >/dev/null; then
    export ESPEAK_DATA_PATH="$(brew --prefix 2>/dev/null)/share/espeak-ng-data"
  elif [[ -d /usr/lib/x86_64-linux-gnu/espeak-ng-data ]]; then
    export ESPEAK_DATA_PATH=/usr/lib/x86_64-linux-gnu/espeak-ng-data
  elif [[ -d /usr/lib/aarch64-linux-gnu/espeak-ng-data ]]; then
    export ESPEAK_DATA_PATH=/usr/lib/aarch64-linux-gnu/espeak-ng-data
  fi
}

cmd_install() {
  mkdir -p "$TC_HOME"
  command -v git >/dev/null || die "git not found."
  ensure_uv; ensure_espeak
  if [[ ! -d "$SRC/.git" ]]; then
    say "what: cloning Kokoro-FastAPI $TAG into $SRC   why: this is the voice engine's source code"
    git clone -q --depth 1 --branch "$TAG" https://github.com/remsky/Kokoro-FastAPI.git "$SRC"
  fi
  cd "$SRC"
  say "what: creating an isolated Python 3.12 environment inside that folder   why: nothing is installed into your system Python"
  [[ -d .venv ]] || uv venv --python 3.12 -q
  say "what: installing Kokoro and its dependencies (PyTorch is the big one, a few hundred MB)   why: this is the model runtime"
  if [[ "$OS" == "Darwin" ]]; then uv pip install -q -e . ; else uv pip install -q -e ".[cpu]"; fi
  env_for_run
  say "what: downloading the Kokoro voice model (about 330 MB)   why: the actual voice"
  uv run --no-sync python docker/scripts/download_model.py --output api/src/models/v1_0 >/dev/null
  say "native engine installed"
}

cmd_start() {
  [[ -d "$SRC/.venv" ]] || die "not installed yet. Run: $0 install"
  if cmd_status_quiet; then say "already running on :$PORT"; return; fi
  cd "$SRC"; env_for_run
  nohup uv run --no-sync uvicorn api.src.main:app --host 127.0.0.1 --port $PORT >"$LOG" 2>&1 &
  echo $! > "$PID_FILE"
  for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
  cmd_status_quiet && say "Kokoro (native) is up on :$PORT   log: $LOG" || die "did not come up. Check $LOG"
}

cmd_stop() {
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    pkill -P "$(cat "$PID_FILE")" 2>/dev/null || true; kill "$(cat "$PID_FILE")" 2>/dev/null || true; rm -f "$PID_FILE"; say "stopped"
  else
    say "not running"
  fi
}

cmd_status_quiet() { curl -fsS -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; }
cmd_status() { if cmd_status_quiet; then say "running on :$PORT"; else say "not running"; exit 1; fi; }

cmd_autostart() {
  [[ -d "$SRC/.venv" ]] || die "install first"
  ME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  if [[ "$OS" == "Darwin" ]]; then
    P="$HOME/Library/LaunchAgents/com.talking-computer.kokoro.plist"
    cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.talking-computer.kokoro</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$ME</string><string>run-foreground</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string><key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
    launchctl unload "$P" 2>/dev/null || true; launchctl load "$P"; say "autostart installed (launchd)"
  else
    U="$HOME/.config/systemd/user/talking-computer-kokoro.service"; mkdir -p "$(dirname "$U")"
    cat > "$U" <<SD
[Unit]
Description=Talking Computer voice engine (Kokoro, native)
[Service]
ExecStart=/bin/bash $ME run-foreground
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
SD
    systemctl --user daemon-reload; systemctl --user enable --now talking-computer-kokoro.service; say "autostart installed (systemd --user)"
  fi
}

cmd_run_foreground() { cd "$SRC"; env_for_run; exec uv run --no-sync uvicorn api.src.main:app --host 127.0.0.1 --port $PORT; }

case "${1:-}" in
  install) cmd_install;; start) cmd_start;; stop) cmd_stop;; status) cmd_status;;
  autostart) cmd_autostart;; run-foreground) cmd_run_foreground;;
  *) sed -n '2,12p' "$0"; exit 1;;
esac
