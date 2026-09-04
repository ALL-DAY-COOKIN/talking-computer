#!/usr/bin/env python3
"""Talking Computer native voice engine: Kokoro via ONNX, no Docker.

Serves the same three endpoints speak.py uses, so nothing else changes:
  GET  /v1/models
  GET  /v1/audio/voices
  POST /v1/audio/speech   {"input": str, "voice": str, "speed": float}  -> WAV

Env: KOKORO_PORT (8880), KOKORO_MODEL, KOKORO_VOICES (paths), KOKORO_HOST (127.0.0.1)
"""
import io
import json
import os
import sys
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import shutil
import tempfile

import espeakng_loader
import numpy as np

HERE = Path(__file__).resolve().parent


def _short_espeak_data() -> None:
    """espeak-ng keeps its data path in a ~160-byte buffer. If the bundled data sits at a
    longer path (deep venvs do this) it silently falls back to a compiled-in path and
    aborts the process on first use. Copy the ~19 MB data dir somewhere short instead.
    A symlink is not enough: phonemizer resolves it back to the long path."""
    real = espeakng_loader.get_data_path()
    if len(real) < 140:
        return
    candidates = [
        os.environ.get("KOKORO_ESPEAK_DATA", ""),
        str(Path.home() / ".talking-computer" / "espeak-ng-data"),
        str(Path(tempfile.gettempdir()) / "tc-espeak-ng-data"),
    ]
    for dest in candidates:
        if dest and len(dest) < 140:
            if not (Path(dest) / "phontab").exists():
                Path(dest).parent.mkdir(parents=True, exist_ok=True)
                shutil.copytree(real, dest, dirs_exist_ok=True)
            espeakng_loader.get_data_path = lambda d=dest: d  # type: ignore[assignment]
            print(f"espeak data path too long ({len(real)} chars); using copy at {dest}", flush=True)
            return
    print(f"WARNING: espeak data path is {len(real)} chars and no short location was writable", flush=True)


_short_espeak_data()
from kokoro_onnx import Kokoro  # noqa: E402  (must come after the path fix)
MODEL = os.environ.get("KOKORO_MODEL", str(HERE / "models" / "kokoro-v1.0.onnx"))
VOICES = os.environ.get("KOKORO_VOICES", str(HERE / "models" / "voices-v1.0.bin"))
PORT = int(os.environ.get("KOKORO_PORT", "8880"))
HOST = os.environ.get("KOKORO_HOST", "127.0.0.1")

kokoro = Kokoro(MODEL, VOICES)
VOICE_LIST = sorted(kokoro.get_voices())


def to_wav(samples: np.ndarray, rate: int) -> bytes:
    pcm = np.clip(samples, -1.0, 1.0)
    pcm = (pcm * 32767).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


class H(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/v1/models"):
            return self._json(200, {"object": "list", "data": [{"id": "kokoro", "object": "model", "owned_by": "kokoro"}]})
        if self.path.startswith("/v1/audio/voices"):
            return self._json(200, {"voices": VOICE_LIST})
        self._json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        if not self.path.startswith("/v1/audio/speech"):
            return self._json(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length", "0"))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("input") or "").strip()
            voice = req.get("voice") or "am_eric"
            speed = float(req.get("speed") or 1.0)
            if not text:
                return self._json(400, {"error": "empty input"})
            if voice not in VOICE_LIST:
                return self._json(400, {"error": f"unknown voice {voice}", "voices": VOICE_LIST})
            lang = "en-gb" if voice.startswith("b") else "en-us"
            samples, rate = kokoro.create(text, voice=voice, speed=speed, lang=lang)
            wav = to_wav(samples, rate)
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.end_headers()
        self.wfile.write(wav)

    def log_message(self, fmt, *args):  # quieter than default
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    print(f"kokoro-onnx ready on http://{HOST}:{PORT}  voices={len(VOICE_LIST)}", flush=True)
    ThreadingHTTPServer((HOST, PORT), H).serve_forever()
