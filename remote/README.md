# remote/ — hear the voice on a different device

This is an add-on. Skip it unless the agent and the speakers are on different machines.

Two shapes it covers:

1. **Agent on a server, speakers on this laptop** (most common). The laptop runs Kokoro and a tiny listener. An SSH reverse tunnel carries the server's port 9876 back to the laptop. The server installs with `bash install.sh --remote` and needs no Docker or audio.
2. **Agent on this laptop, speakers elsewhere.** Same pieces, mirrored: the other device runs Kokoro and the listener, and this laptop forwards to it. Set `SPEAK_REMOTE_URL` to that device's listener address in the notify line.

```
server: agent reply -> notify -> speak.py posts the line to 127.0.0.1:9876
                                            | ssh -R 9876:127.0.0.1:9876
laptop: listener on :9876 -> Kokoro :8880 -> speakers
```

## Instructions for Codex (shape 1)

Follow the same rhythm as the main guide: explain, ask, do, prove, summarize.

**On the laptop (speakers):**
1. Explain: "A small listener will wait on this laptop for text to speak. It only listens locally; the server reaches it through the SSH connection you already use." Ask, then run `bash remote/install-listener.sh`. It installs `speak.py --listen` as a login service: launchd on macOS, a systemd user unit on Linux. `--dry-run` shows the unit first if the user wants to see it.
2. Prove: `curl http://127.0.0.1:9876` prints "Talking Computer listener alive".
3. Explain the tunnel: "Every time you ssh to the server, this line carries a channel back to the listener." Add the `Host` block from `remote/ssh-config.snippet` to `~/.ssh/config`, editing HostName and User. For a tunnel that outlives the login, `remote/tunnel.sh user@server` (uses autossh if installed).

**On the server (agent):**
1. Copy or clone this folder.
2. `bash install.sh --remote`. It writes the notify line with `SPEAK_REMOTE_URL=http://127.0.0.1:9876` and appends the contract. No Docker.
3. Prove, with the tunnel open: `curl http://127.0.0.1:9876` on the server prints the "alive" line, and `curl -X POST --data-raw "tunnel test" http://127.0.0.1:9876` is heard on the laptop.

If step 3 is silent: the tunnel is not open (log in again or run tunnel.sh), or the listener is down (`launchctl list | grep speak` on macOS, `systemctl --user status talking-computer-listener` on Linux).

## Files

| File | Purpose |
|---|---|
| `ssh-config.snippet` | Laptop-side Host block that carries the tunnel on every login |
| `tunnel.sh` | Standalone reconnecting tunnel |
| `install-listener.sh` | Laptop-side login service for the listener (`--dry-run`, `--remove`) |
