#!/usr/bin/env bash
# Keep a standalone speak tunnel up from the LAPTOP to the server, independent
# of any interactive ssh session. Use this if you don't want to rely on the
# ssh-config RemoteForward (e.g. you run Codex in tmux and log out).
#   remote/tunnel.sh user@server            # foreground, reconnects forever
# Uses autossh when installed (brew install autossh / apt install autossh),
# otherwise a plain retry loop.
set -u
TARGET="${1:?usage: tunnel.sh user@server}"
PORT="${SPEAK_LISTEN_PORT:-9876}"
OPTS=(-N -R "${PORT}:127.0.0.1:${PORT}" -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes)
if command -v autossh >/dev/null; then
  exec autossh -M 0 "${OPTS[@]}" "$TARGET"
fi
while true; do
  ssh "${OPTS[@]}" "$TARGET"
  echo "[talking-computer] tunnel dropped, retrying in 5s" >&2
  sleep 5
done
