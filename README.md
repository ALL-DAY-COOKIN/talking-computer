# Talking Computer

Your coding agent finishes a task and tells you out loud what happened.

Talking Computer makes Codex or Claude Code end every reply with a short spoken summary, played through your speakers by a small text-to-speech engine that runs locally in Docker. Nothing leaves your machine. You can be in the kitchen, on a walk, or holding a kid, and still hear what changed, why, and what's next, like a colleague giving you the two-sentence version on the way to the coffee machine. The screen keeps the full detail for when you sit back down.

## Install

```
git clone https://github.com/trheard/talking-computer && cd talking-computer
codex "Install this."        # or:  claude "Install this."
```

Either agent finds the instructions in this folder and walks you through it in four short phases and explains each one before touching anything. The first thing you hear is the voice introducing itself. Then four voices audition for the job and you pick one and name it. The last thing you hear is that voice saying setup is done. About ten minutes, most of it the one-time image download.

Prefer to do it by hand? `bash install.sh` does the same steps without the conversation.

## What you get

- **A voice with a name.** Four Kokoro voices audition reading a real sentence. Pick one, name it, and it introduces itself that way from then on.
- **A briefing, not a log line.** A writing rule teaches the agent to end each reply with two to four plain spoken sentences: the outcome, the reason, and what's next. No file paths, no code.
- **Local and private.** Kokoro runs in Docker on your machine and only listens on localhost. No accounts, no API keys, no cloud.
- **Off in one command.** `docker compose stop` silences it; `docker compose start` brings it back.

## How it works

```
agent finishes a reply
  -> its last paragraph is "===SPEAK=== <2-4 spoken sentences>"   (AGENTS.md rule)
  -> the agent's turn-finished hook runs speak.py                  (notify line, or Stop hook)
  -> speak.py pulls that line and asks Kokoro on :8880 for audio   (docker-compose.yml)
  -> plays it in your chosen voice                                 (your speakers)
```

## Files

| File | Purpose |
|---|---|
| `SETUP.md` | The guided install, written for the agent to run with you |
| `AGENTS.md`, `CLAUDE.md` | Tell whichever agent opens this folder to read `SETUP.md` |
| `install.sh` | Idempotent installer: container, config, rule, wake-up line |
| `docker-compose.yml` | Kokoro-FastAPI, CPU image, loopback only |
| `speak.py` | Extract, synthesize, play. Also hello, audition, choose, wake-up, and the Codex notify entry point |
| `AGENTS.md.snippet` | The writing rule, appended to `~/.codex/AGENTS.md` and/or `~/.claude/CLAUDE.md` |
| `codex-config.snippet.toml` | The Codex hook: one notify line for `~/.codex/config.toml` |
| `claude-settings.snippet.json` | The Claude Code hook: one Stop entry for `~/.claude/settings.json` |
| `remote/` | Add-on: hear the voice on a different device over SSH |

## Add-ons

Offered by the agent at the end of the install, all optional and reversible: change the voice later, adjust speed, use the GPU, or hear the voice on another device. Details in the last section of `SETUP.md`.

## Requirements

- Docker (Desktop on macOS or Windows, engine on Linux)
- Python 3.9 or newer, no packages to install
- A way to play sound: macOS has `afplay` built in; Linux needs `paplay`, `aplay`, or `ffplay`
- About 5 GB of disk for the image and 1.5 GB of RAM while it runs

## Uninstall

`docker compose down` in this folder, delete the `notify` line from `~/.codex/config.toml` and/or the Stop hook from `~/.claude/settings.json`, remove the section that starts with "Voice summary marker" from `~/.codex/AGENTS.md` and/or `~/.claude/CLAUDE.md`, and delete `~/.talking-computer/`.

## Credits

Voice by [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), served by [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI). MIT licensed.
