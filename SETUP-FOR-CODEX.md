# SETUP-FOR-CODEX.md — Talking Computer

You are Codex, and you are installing this for a person who wants to understand what is happening on their machine, not just see it happen. Your job is to install the Talking Computer in four phases, and at every phase: explain in plain words what you are about to change, ask "go ahead?", do it, prove it with something they can see or hear, then say what they now have and what is still missing.

Rules for this install:
- Plain words. No jargon without a one-clause explanation the first time.
- Never run a phase before the user says go.
- Every proof is something the user can read on screen or hear from the speakers.
- If a step fails, say what failed, what you think caused it, and what you are going to try, before trying it.
- Everything here stays on this laptop. Nothing is sent anywhere. Say that early.

## Before anything: the pre-flight

Tell the user, in one short paragraph, what the finished result is: every reply you give will end with a two-to-four sentence spoken summary, played through the laptop speakers by a small text-to-speech program running locally. Then list exactly what will change on the machine:

1. A Docker container named `talking-computer-kokoro` will run in the background, using about 1.5 GB of memory. It only listens on this laptop.
2. One line will be added to `~/.codex/config.toml` so Codex hands each finished reply to a small script.
3. A writing rule will be appended to `~/.codex/AGENTS.md` so every reply ends with a block that starts with `===SPEAK===`.
4. A log folder `~/.talking-computer/` will be created.

Nothing else is touched. Then check the prerequisites and report them in a short list: Docker installed and running (`docker info`), Python 3 present (`python3 --version`), and a way to play sound (macOS has `afplay` built in; Linux needs `paplay`, `aplay`, or `ffplay`). If Docker is not running, ask the user to start Docker Desktop and wait.

Last thing before phase 1: "Turn your speakers on and set the volume to a normal level. The first thing you'll hear is the voice introducing itself." Ask: go ahead with phase 1?

## Phase 1: the voice engine

**Explain:** "I'm starting Kokoro, a small open-source text-to-speech model, inside Docker. Docker is a way to run a program in its own sealed box. Kokoro will sit in the background and turn text into audio whenever asked. It only answers on this laptop, on port 8880."

**Do:** from this folder, `docker compose up -d`. The first start downloads the image, about 5 GB, which can take a few minutes. Tell the user that is expected and show the progress.

**Prove, part one:** `curl -s http://127.0.0.1:8880/v1/models` returns JSON. Say "that's the voice engine answering."

**Prove, part two, the first sound:** `python3 speak.py --hello`. The voice says: "Hello. I'm the voice your computer is about to get. If you can hear me, tell Codex yes." Ask the user if they heard it. If not, this is where you fix sound, not later: check volume and output device, and check `~/.talking-computer/speak.log` (on Linux the usual cause is no audio player installed). Do not move on until they say yes.

**Now they have:** a voice engine running, and they have heard it. **Still missing:** it's the default voice, and nothing speaks on its own yet.

## Phase 2: the audition

**Explain:** "Kokoro has about fifty voices. I'll play four of them reading the same sentence, the kind of sentence you'll actually hear from me later. Pick the one you want to live with. You can give it a name too; that name will show up when it introduces itself."

**Do:** `python3 speak.py --audition`. It prints a numbered list and plays voice 1 through 4, each saying "Voice N. The build finished, two tests failed, and I've got a fix ready when you are." Offer to replay any of them: `python3 speak.py --text "..." ` with `SPEAK_VOICE=<id>` in front.

**Choose:** `python3 speak.py --choose <voice id> <name>`, for example `--choose bm_george George`. If they don't want a name, leave it off; the voice's own nickname is used. The choice is saved in `~/.talking-computer/config.json` and becomes the default for everything after this.

**Prove:** `python3 speak.py --text "From now on, this is what I sound like."` in the chosen voice. Ask if that's the one.

**Now they have:** their voice. **Still missing:** Codex doesn't know to use it.

## Phase 3: connecting Codex to the voice

**Explain:** "Codex can run a program every time it finishes a reply. I'm adding one line to your Codex config that points at the script. The script looks for a block at the end of my reply that starts with three equals signs and the word SPEAK, and speaks only that part. If a reply has no such block, nothing happens."

**Do:** `bash install.sh --no-contract`. Then show the user the line it added: `grep notify ~/.codex/config.toml`.

**Prove:** simulate a finished reply without leaving this session:
```
SPEAK_FOREGROUND=1 python3 speak.py --notify '{"type":"agent-turn-complete","last-assistant-message":"Screen text here.\n\n===SPEAK=== The hook between Codex and the voice is connected, so every reply can now be spoken."}'
```
The user hears that sentence.

**Now they have:** the plumbing from Codex to the speakers. **Still missing:** Codex hasn't been told to write the spoken block.

## Phase 4: teaching Codex to write the spoken summary

**Explain:** "The last piece is a writing rule. Codex reads a file called AGENTS.md at the start of every session. I'm appending a section that says: end every reply with a short spoken summary, two to four sentences, in plain conversational language, no file names or code. It also explains why: so you can be away from the screen and still know what happened. You can read it, it's about a page."

**Do:** `bash install.sh --contract-only`. Then offer to show the section: `tail -60 ~/.codex/AGENTS.md`.

**Prove:** `grep -c '===SPEAK===' ~/.codex/AGENTS.md` is at least 1.

**Now they have:** everything. **Still missing:** this session started before the rule existed, so it does not apply here. The next new Codex session will.

## Wrap-up

Tell the user, in plain words:
- The four things now on the machine, in one line each.
- How to turn it off: `docker compose down` in this folder stops the voice; deleting the notify line from `config.toml` disconnects Codex; deleting the SPEAK section from `AGENTS.md` stops the summaries.
- Where to look if it goes quiet: `~/.talking-computer/speak.log`.
- That they need to start a fresh Codex session, and the first reply there should end with a spoken summary they can hear.

Then the wake-up: `python3 speak.py --wakeup`. The chosen voice says "Setup is done. I'm <name>. From now on, every time your agent finishes, I'll tell you what happened. Go start a new session and say hello." Let that be the last sound of the install.

Then present the options below as a menu and ask if they want any of them now. End your wrap-up reply with a `===SPEAK===` block yourself, as a preview of what every reply will sound like.

## Options and add-ons (present after the install, not before)

Offer these as a short list. Each is optional and reversible.

| Option | What it does | How |
|---|---|---|
| **Change the voice later** | Any of Kokoro's ~50 voices, not just the four from the audition. | List: `curl -s http://127.0.0.1:8880/v1/audio/voices`. Sample: `SPEAK_VOICE=<id> python3 speak.py --text "..."`. Keep: `python3 speak.py --choose <id> <name>`. |
| **Faster or slower** | Speech rate. | Edit `"speed"` in `~/.talking-computer/config.json`, e.g. 1.15. |
| **Hear it on another device** | The agent runs on this laptop but the voice plays on a different machine, or the reverse: the agent runs on a server and this laptop does the speaking. Uses an SSH tunnel. | Read `remote/README.md` and follow it. Only offer if the user actually works across two machines. |
| **Use the GPU** | On a laptop with an NVIDIA card, Kokoro runs faster on it. Not needed; the CPU version answers in about a second. | Swap the image tag in `docker-compose.yml` to `-gpu` and uncomment the deploy block. |
| **Turn it off temporarily** | Keep everything installed but silent. | `docker compose stop` in this folder. `docker compose start` brings it back. |
