#!/usr/bin/env bash
# Install `speak.py --listen` as a login service ON THE LAPTOP so the listener
# is always up: launchd on macOS, systemd --user on Linux.
#   remote/install-listener.sh            # install + start
#   remote/install-listener.sh --remove   # uninstall
#   remote/install-listener.sh --dry-run  # print the unit, change nothing
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$(command -v python3)"
PORT="${SPEAK_LISTEN_PORT:-9876}"
VOICE="${SPEAK_VOICE:-am_eric}"
MODE="${1:-install}"
OS="$(uname -s)"

if [[ "$OS" == "Darwin" ]]; then
  LABEL="com.talking-computer.listener"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  UNIT=$(cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$PY</string><string>$KIT_DIR/speak.py</string><string>--listen</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>SPEAK_LISTEN_PORT</key><string>$PORT</string>
    <key>SPEAK_VOICE</key><string>$VOICE</string>
    <key>SPEAK_KOKORO_URL</key><string>${SPEAK_KOKORO_URL:-http://127.0.0.1:8880}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/.talking-computer/listener.out</string>
  <key>StandardErrorPath</key><string>$HOME/.talking-computer/listener.err</string>
</dict></plist>
PL
)
  case "$MODE" in
    --dry-run) echo "$UNIT";;
    --remove) launchctl unload "$PLIST" 2>/dev/null || true; rm -f "$PLIST"; echo "[talking-computer] listener removed";;
    *) mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.talking-computer"; echo "$UNIT" > "$PLIST"
       launchctl unload "$PLIST" 2>/dev/null || true; launchctl load "$PLIST"
       echo "[talking-computer] listener installed via launchd ($PLIST)";;
  esac
elif [[ "$OS" == "Linux" ]]; then
  UNIT_PATH="$HOME/.config/systemd/user/talking-computer-listener.service"
  UNIT=$(cat <<SD
[Unit]
Description=Talking Computer listener (Kokoro TTS on :$PORT)
After=default.target

[Service]
ExecStart=$PY $KIT_DIR/speak.py --listen
Environment=SPEAK_LISTEN_PORT=$PORT
Environment=SPEAK_VOICE=$VOICE
Environment=SPEAK_KOKORO_URL=${SPEAK_KOKORO_URL:-http://127.0.0.1:8880}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
SD
)
  case "$MODE" in
    --dry-run) echo "$UNIT";;
    --remove) systemctl --user disable --now talking-computer-listener.service 2>/dev/null || true; rm -f "$UNIT_PATH"; echo "[talking-computer] listener removed";;
    *) mkdir -p "$(dirname "$UNIT_PATH")"; echo "$UNIT" > "$UNIT_PATH"
       systemctl --user daemon-reload; systemctl --user enable --now talking-computer-listener.service
       echo "[talking-computer] listener installed via systemd --user";;
  esac
else
  echo "Windows: run 'python speak.py --listen' from a Startup shortcut, or use Task Scheduler." >&2
  exit 1
fi
