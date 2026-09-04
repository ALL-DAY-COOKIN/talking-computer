# SETUP.md — Talking Computer

You are the coding agent running this install: Codex or Claude Code. You are installing this for a person who wants to understand what is happening on their machine, not just watch it happen.

There is one command, `./tc`, run from this folder, one phase at a time. Each phase prints tagged lines. **Read the tags. Do not improvise commands, do not run Docker yourself, do not investigate permissions.**

| Tag | What you do |
|---|---|
| `SAY` | Tell the user this, in your own words, before or after the step as it reads. Plain language. |
| `OK` / `WARN` / `FAIL` | Report it in one line. On `FAIL`, read the `NEXT` line; it always says what to do. |
| `HANDOFF` | Your sandbox can't do this step. Give the user the exact command to paste into their own Terminal, say in one line what it does, wait for them to say "done", then **rerun the same `./tc` command**. This is normal. |
| `NEXT` | The one command to run next. Nothing else. |

Rhythm for every phase: say what's about to happen, ask "go ahead?", run the one command, relay what it printed, ask the question it tells you to ask. Never run a phase before the user says go.

## Phase 0: `./tc preflight`

Run it first. It opens with the line to say ("Basically, I'm going to give your computer a voice"), lists the four things that will change on the machine, checks Python, audio, disk and Docker, and prints exactly one `NEXT`.

If Docker isn't installed it asks the user to choose: **A**, install Docker for them (`./tc engine --install-docker`), or **B**, run the voice engine natively with no Docker (`./tc engine --native`). Relay the two options as written and run the one they pick. On a Mac older than macOS 14 it picks B for them.

## Phase 1: `./tc engine`

Starts the voice engine and plays the hello line: "Hello. I'm the voice your computer is about to get. If you can hear me, say yes."

Before running it, say: "Speakers on, volume normal. The first thing you'll hear is the voice introducing itself. The first start downloads a few gigabytes, so it can take a few minutes."

- The first download can take several minutes. That is expected; say so.
- A `HANDOFF` here is common: agent sandboxes usually can't reach Docker. Hand the command over, wait for "done", rerun `./tc engine`. It will find the engine running and play the hello.
- **Do not continue until the user says they heard the hello.** If they didn't: `./tc sound-check`.

## Phase 2: `./tc audition` then `./tc choose <voice> [name]`

Four voices read the same sentence. Ask which one they want and whether to name it. Then `./tc choose bm_george George` (their pick, their name). It confirms in the chosen voice. Ask "is that the one?" If not, choose again.

## Phase 3: `./tc hook`

Connects the agent to the voice and immediately proves it: a simulated finished reply is spoken aloud. Before running, say: "Now I connect myself to the voice. For Codex that's one line in my config; for Claude Code it's a Stop hook. Then you'll hear a test." Ask "did you hear that?"

## Phase 4: `./tc rule`

Appends the writing rule to the agent's instructions file. Before running, say: "Last piece: a one-page rule that tells me to end every reply with a short spoken summary, plain language, no file names or code. You can read it afterwards." Offer to show it: `tail -60 ~/.codex/AGENTS.md` or `tail -60 ~/.claude/CLAUDE.md`.

## Phase 5: `./tc finish`

Prints the wrap-up facts for you to relay, plays the wake-up line in the chosen voice ("Setup is done. I'm George. From now on…"), and lists the add-ons. Relay the add-ons as a short menu and ask if they want any now. Then tell the user to start a **new session** and say hello; this session started before the rule existed, so it won't speak here.

End your own wrap-up reply with a `===SPEAK===` block, as a preview of what every reply will sound like.

## If something goes wrong

- Read the `FAIL` and `NEXT` lines; they are specific.
- `./tc status` shows engine, hooks, rule, and voice in six lines.
- `./tc sound-check` replays the hello and shows the log.
- Never loop on permissions. One try, then `HANDOFF` to the user.

## Add-ons (only after finish)

| Option | How |
|---|---|
| Change the voice later | `./tc audition`, then `./tc choose <id> <name>` |
| Faster or slower | edit `"speed"` in `~/.talking-computer/config.json`, e.g. 1.15 |
| Hear it on another device over SSH | `remote/README.md` |
| Wire the other agent too | `./tc hook --agent both`, then `./tc rule` |
| Turn it off / on | `./tc off`, `./tc on` |
