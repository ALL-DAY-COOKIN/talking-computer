#!/usr/bin/env python3
"""speak.py — Talking Computer: turn the ===SPEAK=== block at the bottom of an agent reply into audio.

Three ways to run it (stdlib only, no pip installs):

  speak.py --text "hello there"        synthesize with Kokoro and play it now
  speak.py --notify '<json>'           Codex `notify` entry point (JSON as argv or stdin)
  speak.py --stop-hook                 Claude Code `Stop` hook entry point (JSON on stdin)
  speak.py --listen                    tiny HTTP listener on 127.0.0.1:9876; POST raw
                                       text to it and this machine speaks. Use when the
                                       agent runs on a remote box: ssh -R 9876:127.0.0.1:9876
  speak.py --hello                     the first-sound speaker check
  speak.py --audition [--out-dir D]    four voices read the same sentence, one after another
  speak.py --choose VOICE [NAME]       remember the chosen voice (and a name for it)
  speak.py --wakeup                    the "setup is done" line, in the chosen voice
  speak.py --show                      print the saved choice

Environment (all optional):
  SPEAK_KOKORO_URL   default http://127.0.0.1:8880
  SPEAK_VOICE        default am_eric   (try af_heart, am_adam, bf_emma, ...)
  SPEAK_SPEED        default 1.0
  SPEAK_REMOTE_URL   if set, --notify POSTs the text here instead of speaking locally
                     (e.g. http://127.0.0.1:9876 through an ssh tunnel)
  SPEAK_LISTEN_PORT  default 9876
  SPEAK_LOG          default ~/.talking-computer/speak.log

A choice saved with --choose lives in ~/.talking-computer/config.json and is the default;
environment variables override it.
"""
from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

LOG_PATH = Path(os.environ.get("SPEAK_LOG", str(Path.home() / ".talking-computer" / "speak.log")))
LAST_PATH = LOG_PATH.parent / "last-spoken.txt"
CONFIG_PATH = LOG_PATH.parent / "config.json"


def load_config() -> dict:
    try:
        return json.loads(CONFIG_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_config(**kv) -> None:
    cfg = load_config()
    cfg.update({k: v for k, v in kv.items() if v is not None})
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))


_CFG = load_config()
KOKORO_URL = os.environ.get("SPEAK_KOKORO_URL", _CFG.get("kokoro_url", "http://127.0.0.1:8880")).rstrip("/")
VOICE = os.environ.get("SPEAK_VOICE", _CFG.get("voice", "am_eric"))
NAME = os.environ.get("SPEAK_NAME", _CFG.get("name", ""))
SPEED = float(os.environ.get("SPEAK_SPEED", _CFG.get("speed", 1.0)))
REMOTE_URL = os.environ.get("SPEAK_REMOTE_URL", _CFG.get("remote_url", "")).strip()
LISTEN_PORT = int(os.environ.get("SPEAK_LISTEN_PORT", "9876"))

# The experience lines. Keep them short; a voice you can't interrupt gets old fast.
HELLO = ("Hello. I'm the voice your computer is about to get. "
         "If you can hear me, say yes.")
AUDITION_SENTENCE = ("The build finished, two tests failed, "
                     "and I've got a fix ready when you are.")
AUDITION_VOICES = [
    ("am_eric",  "Eric",   "warm American male"),
    ("af_heart", "Heart",  "clear American female"),
    ("bm_george", "George", "measured British male"),
    ("bf_emma",  "Emma",   "soft British female"),
]


def wakeup_line() -> str:
    who = f"I'm {NAME}. " if NAME else ""
    return (f"Setup is done. {who}From now on, every time your agent finishes, "
            "I'll tell you what happened. Go start a new session and say hello.")
MARKER_RE = re.compile(r"^===SPEAK===\s*(.*)$", re.MULTILINE)


def log(msg: str) -> None:
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def extract_speak_line(text: str) -> str:
    """Last ===SPEAK=== block in the text, marker stripped, one paragraph."""
    matches = MARKER_RE.findall(text or "")
    if not matches:
        return ""
    line = matches[-1].strip()
    # If the model put the block on the line after the marker, grab that paragraph.
    if not line:
        tail = text.rsplit("===SPEAK===", 1)[-1].strip()
        line = tail.split("\n\n", 1)[0].strip()
    return " ".join(line.split())


def synthesize(text: str, voice: str | None = None) -> bytes:
    body = json.dumps({
        "model": "kokoro",
        "input": text,
        "voice": voice or VOICE,
        "speed": SPEED,
        "response_format": "wav",
    }).encode()
    req = urllib.request.Request(
        f"{KOKORO_URL}/v1/audio/speech",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def player_command(path: str) -> list[str] | None:
    system = platform.system()
    if system == "Darwin" and shutil.which("afplay"):
        return ["afplay", path]
    if system == "Windows":
        ps = f"(New-Object Media.SoundPlayer '{path}').PlaySync()"
        return ["powershell", "-NoProfile", "-Command", ps]
    for cand in (["paplay", path], ["aplay", "-q", path], ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", path]):
        if shutil.which(cand[0]):
            return cand
    return None


def play(wav: bytes) -> None:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as fh:
        fh.write(wav)
        path = fh.name
    try:
        cmd = player_command(path)
        if not cmd:
            log("no audio player found (need afplay / paplay / aplay / ffplay)")
            return
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def speak(text: str, no_play: bool = False, out: str | None = None, voice: str | None = None) -> None:
    text = text.strip()
    if not text:
        return
    try:
        wav = synthesize(text, voice)
    except Exception as exc:  # noqa: BLE001
        log(f"kokoro error: {exc}")
        return
    if out:
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        Path(out).write_bytes(wav)
        log(f"wrote {out} ({len(wav)} bytes)")
    if not no_play:
        play(wav)
    log(f"spoke: {text[:80]}")


def post_remote(text: str) -> None:
    req = urllib.request.Request(REMOTE_URL, data=text.encode(), headers={"Content-Type": "text/plain"}, method="POST")
    try:
        urllib.request.urlopen(req, timeout=30).read()
        log(f"forwarded to {REMOTE_URL}: {text[:80]}")
    except Exception as exc:  # noqa: BLE001
        log(f"remote error: {exc}")


def handle_notify(raw: str) -> None:
    """Codex notify payload: {"type":"agent-turn-complete","last-assistant-message":"..."}"""
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        log("notify: payload was not JSON")
        return
    if payload.get("type") not in (None, "agent-turn-complete"):
        return
    message = payload.get("last-assistant-message") or payload.get("last_assistant_message") or ""
    line = extract_speak_line(message)
    if not line:
        return
    # De-dupe: the same block can arrive twice on some clients.
    try:
        if LAST_PATH.exists() and LAST_PATH.read_text().strip() == line:
            return
        LAST_PATH.parent.mkdir(parents=True, exist_ok=True)
        LAST_PATH.write_text(line)
    except OSError:
        pass
    if REMOTE_URL:
        post_remote(line)
    else:
        speak(line)


def _last_assistant_text(transcript_path: str) -> str:
    """Claude Code transcript is JSONL; return the text of the last assistant entry."""
    last = ""
    try:
        with open(transcript_path, encoding="utf-8") as fh:
            for raw in fh:
                try:
                    entry = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                msg = entry.get("message") or {}
                if msg.get("role") != "assistant":
                    continue
                parts = [c.get("text", "") for c in (msg.get("content") or []) if c.get("type") == "text"]
                if parts:
                    last = "\n".join(parts)
    except OSError:
        return ""
    return last


def handle_stop_hook(raw: str) -> None:
    """Claude Code Stop hook payload: {"transcript_path": "...", "hook_event_name": "Stop", ...}
    The final text block can land in the transcript slightly after the hook fires, so poll briefly."""
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        log("stop-hook: payload was not JSON")
        return
    path = payload.get("transcript_path", "")
    if not path:
        return
    try:
        last_spoken = LAST_PATH.read_text().strip() if LAST_PATH.exists() else ""
    except OSError:
        last_spoken = ""
    line = ""
    for _ in range(30):
        candidate = extract_speak_line(_last_assistant_text(path))
        if candidate and candidate != last_spoken:
            line = candidate
            break
        time.sleep(0.2)
    if not line:
        return
    try:
        LAST_PATH.parent.mkdir(parents=True, exist_ok=True)
        LAST_PATH.write_text(line)
    except OSError:
        pass
    if REMOTE_URL:
        post_remote(line)
    else:
        speak(line)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        text = self.rfile.read(length).decode("utf-8", "replace")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
        # Accept either a bare ===SPEAK=== block or raw text.
        line = extract_speak_line(text) or text
        speak(line)

    def do_GET(self):  # noqa: N802
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Talking Computer listener alive\n")

    def log_message(self, *_):  # silence default stderr chatter
        return


def listen() -> None:
    server = HTTPServer(("127.0.0.1", LISTEN_PORT), Handler)
    log(f"listening on 127.0.0.1:{LISTEN_PORT}")
    print(f"Talking Computer listener on http://127.0.0.1:{LISTEN_PORT}  (voice={VOICE}, kokoro={KOKORO_URL})")
    server.serve_forever()


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 1
    mode = argv[0]
    if mode == "--text":
        no_play = "--no-play" in argv
        out = None
        if "--out" in argv:
            out = argv[argv.index("--out") + 1]
        words = [a for a in argv[1:] if a not in ("--no-play", "--out", out)]
        speak(" ".join(words), no_play=no_play, out=out)
        return 0
    if mode == "--notify":
        raw = argv[1] if len(argv) > 1 else sys.stdin.read()
        # Fork so Codex isn't blocked while audio plays.
        if os.environ.get("SPEAK_FOREGROUND") != "1" and hasattr(os, "fork"):
            if os.fork() != 0:
                return 0
            os.setsid()
        handle_notify(raw)
        return 0
    if mode == "--stop-hook":
        raw = sys.stdin.read()
        if os.environ.get("SPEAK_FOREGROUND") != "1" and hasattr(os, "fork"):
            if os.fork() != 0:
                return 0          # return immediately so the agent isn't blocked
            os.setsid()
        handle_stop_hook(raw)
        return 0
    if mode == "--listen":
        listen()
        return 0
    if mode == "--extract":
        print(extract_speak_line(sys.stdin.read()))
        return 0
    if mode == "--hello":
        speak(HELLO, no_play="--no-play" in argv)
        return 0
    if mode == "--audition":
        out_dir = argv[argv.index("--out-dir") + 1] if "--out-dir" in argv else None
        no_play = "--no-play" in argv
        if out_dir:
            Path(out_dir).mkdir(parents=True, exist_ok=True)
        for i, (vid, nick, desc) in enumerate(AUDITION_VOICES, 1):
            print(f"{i}. {vid:10s} {nick:7s} {desc}")
            out = str(Path(out_dir) / f"{i}-{vid}.wav") if out_dir else None
            speak(f"Voice {i}. {AUDITION_SENTENCE}", no_play=no_play, out=out, voice=vid)
            if not no_play:
                time.sleep(0.6)
        print("Pick one: speak.py --choose <voice> [name]")
        return 0
    if mode == "--choose":
        if len(argv) < 2:
            print("usage: --choose VOICE [NAME]"); return 1
        voice = argv[1]
        name = " ".join(argv[2:]) or dict((v, n) for v, n, _ in AUDITION_VOICES).get(voice, "")
        save_config(voice=voice, name=name)
        print(f"saved: voice={voice} name={name or '(none)'} -> {CONFIG_PATH}")
        return 0
    if mode == "--wakeup":
        speak(wakeup_line(), no_play="--no-play" in argv)
        return 0
    if mode == "--show":
        print(json.dumps({"voice": VOICE, "name": NAME, "speed": SPEED, "kokoro_url": KOKORO_URL,
                          "remote_url": REMOTE_URL, "config": str(CONFIG_PATH)}, indent=2))
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
