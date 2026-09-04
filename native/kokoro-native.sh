#!/usr/bin/env bash
# The voice engine WITHOUT Docker: Kokoro via ONNX in an isolated Python, same API on
# http://127.0.0.1:8880 as the container, so speak.py doesn't care which is running.
# Pure prebuilt wheels (about 150 MB) plus two model files (about 340 MB). No compilers,
# no system packages. Runs on the CPU: a sentence in about a second on Apple Silicon.
#
#   native/kokoro-native.sh install     venv + kokoro-onnx + model files (one time, a few minutes)
#   native/kokoro-native.sh start       run in the background (pid + log in ~/.talking-computer/)
#   native/kokoro-native.sh stop | status
#   native/kokoro-native.sh autostart   start at login (launchd on macOS, systemd --user on Linux)
set -euo pipefail
TC_HOME="${TC_HOME:-$HOME/.talking-computer}"
ENGINE="$TC_HOME/engine"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${KOKORO_PORT:-8880}"
PID_FILE="$TC_HOME/kokoro.pid"; LOG="$TC_HOME/kokoro.log"
MODEL_BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
say() { printf '\033[0;32m[talking-computer]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[talking-computer] %s\033[0m\n' "$*" >&2; exit 1; }
OS="$(uname -s)"

ensure_uv() {
  command -v uv >/dev/null && return
  say "what: installing uv, a small Python package manager, into ~/.local/bin   why: it builds an isolated environment so nothing touches your system Python"
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null || die "uv did not install. See https://docs.astral.sh/uv/"
}

fetch() {  # fetch URL DEST ; skip if present and non-trivial
  local url=$1 dest=$2
  if [[ -s "$dest" ]] && (( $(stat -c %s "$dest" 2>/dev/null || stat -f %z "$dest") > 1000000 )); then return; fi
  curl -fL --retry 3 -o "$dest.part" "$url" && mv "$dest.part" "$dest"
}

cmd_install() {
  mkdir -p "$ENGINE/models"
  ensure_uv
  say "what: creating an isolated Python 3.12 environment in $ENGINE   why: nothing is installed into your system Python"
  [[ -x "$ENGINE/.venv/bin/python" ]] || (cd "$ENGINE" && uv venv --python 3.12 -q)
  say "what: installing kokoro-onnx and its runtime, about 150 MB of prebuilt packages   why: this is the voice model runtime"
  (cd "$ENGINE" && uv pip install -q kokoro-onnx numpy)
  say "what: downloading the Kokoro model and voice pack, about 340 MB   why: the actual voice"
  fetch "$MODEL_BASE/kokoro-v1.0.onnx" "$ENGINE/models/kokoro-v1.0.onnx"
  fetch "$MODEL_BASE/voices-v1.0.bin"  "$ENGINE/models/voices-v1.0.bin"
  cp "$HERE/kokoro_server.py" "$ENGINE/kokoro_server.py"
  say "native engine installed in $ENGINE"
}

running() { curl -fsS -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; }

cmd_start() {
  [[ -x "$ENGINE/.venv/bin/python" && -s "$ENGINE/models/kokoro-v1.0.onnx" ]] || die "not installed yet. Run: $0 install"
  if running; then say "already running on :$PORT"; return; fi
  cp -f "$HERE/kokoro_server.py" "$ENGINE/kokoro_server.py"
  KOKORO_PORT=$PORT nohup "$ENGINE/.venv/bin/python" "$ENGINE/kokoro_server.py" >"$LOG" 2>&1 &
  echo $! > "$PID_FILE"
  for _ in $(seq 1 45); do running && break; sleep 1; done
  running && say "Kokoro (native) is up on :$PORT   log: $LOG" || die "did not come up. Check $LOG"
}

cmd_stop() {
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true; rm -f "$PID_FILE"; say "stopped"
  else say "not running"; fi
}
cmd_status() { if running; then say "running on :$PORT"; else say "not running"; exit 1; fi; }

cmd_autostart() {
  [[ -x "$ENGINE/.venv/bin/python" ]] || die "install first"
  if [[ "$OS" == "Darwin" ]]; then
    P="$HOME/Library/LaunchAgents/com.talking-computer.kokoro.plist"
    cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.talking-computer.kokoro</string>
  <key>ProgramArguments</key><array><string>$ENGINE/.venv/bin/python</string><string>$ENGINE/kokoro_server.py</string></array>
  <key>EnvironmentVariables</key><dict><key>KOKORO_PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string><key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
    cmd_stop >/dev/null 2>&1 || true
    launchctl unload "$P" 2>/dev/null || true; launchctl load "$P"; say "autostart installed (launchd)"
  elif [[ "$OS" == "Linux" ]] && command -v systemctl >/dev/null; then
    U="$HOME/.config/systemd/user/talking-computer-kokoro.service"; mkdir -p "$(dirname "$U")"
    cat > "$U" <<SD
[Unit]
Description=Talking Computer voice engine (Kokoro, native)
[Service]
ExecStart=$ENGINE/.venv/bin/python $ENGINE/kokoro_server.py
Environment=KOKORO_PORT=$PORT
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
SD
    cmd_stop >/dev/null 2>&1 || true
    systemctl --user daemon-reload; systemctl --user enable --now talking-computer-kokoro.service; say "autostart installed (systemd --user)"
  else
    die "autostart not supported on this OS; run '$0 start' after login"
  fi
}

case "${1:-}" in
  install) cmd_install;; start) cmd_start;; stop) cmd_stop;; status) cmd_status;; autostart) cmd_autostart;;
  *) sed -n '2,10p' "$0"; exit 1;;
esac
