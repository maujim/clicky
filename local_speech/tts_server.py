"""
Local Kokoro TTS HTTP server — speaks text as base64 WAV audio.

Loads the Kokoro model once at startup and keeps it warm across
requests, avoiding the per-request subprocess cold-start penalty.
"""

import base64
import io
import json
import os
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer

import numpy as np

HOST = os.environ.get("CLICKY_TTS_HOST", "127.0.0.1")
PORT = int(os.environ.get("CLICKY_TTS_PORT", "8766"))
MODEL = os.environ.get("CLICKY_TTS_MODEL", "mlx-community/Kokoro-82M-4bit")
VOICE = os.environ.get("CLICKY_TTS_VOICE", "af_heart")
LANGUAGE_CODE = os.environ.get("CLICKY_TTS_LANGUAGE_CODE", "a")


# ── Warm model: loaded once at server startup ──────────────────────────────
# We import the TTS loader lazily so the healthcheck is responsive before the
# (potentially slow) first model download completes. On the very first boot
# this will fetch ~57 files from HuggingFace; subsequent restarts use the
# local HF cache.
_tts_model = None  # type: ignore
_tts_startup_error = None


def _ensure_model():
    """Lazy-load the Kokoro TTS model on first request (or explicit warm call)."""
    global _tts_model
    if _tts_model is not None:
        return _tts_model

    from mlx_audio.tts import load as load_tts_model

    print(f"[clicky-tts] Loading TTS model {MODEL} -> voice={VOICE} lang={LANGUAGE_CODE}")
    _tts_model = load_tts_model(MODEL, lazy=False)
    print("[clicky-tts] Model loaded and warm")
    return _tts_model


# ── HTTP handler ───────────────────────────────────────────────────────────


class TTSHandler(BaseHTTPRequestHandler):
    def _send_json(self, status_code: int, payload: dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            model_status = "warm" if _tts_model is not None else "cold"
            is_ready = _tts_model is not None and _tts_startup_error is None
            self._send_json(
                200 if is_ready else 503,
                {
                    "ok": is_ready,
                    "model": MODEL,
                    "voice": VOICE,
                    "languageCode": LANGUAGE_CODE,
                    "modelStatus": model_status,
                    "error": str(_tts_startup_error) if _tts_startup_error else None,
                },
            )
            return
        self._send_json(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        if self.path != "/speak":
            self._send_json(404, {"ok": False, "error": "not_found"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            raw_body = self.rfile.read(content_length)
            payload = json.loads(raw_body.decode("utf-8"))

            text = (payload.get("text") or "").strip()
            if not text:
                self._send_json(400, {"ok": False, "error": "missing_text"})
                return

            model = _ensure_model()

            # In-process synthesis: call model.generate() directly.
            # This returns a generator of GenerationResult namedtuples; we
            # consume the first (and typically only) segment.
            results = model.generate(
                text=text,
                voice=VOICE,
                speed=1.0,
                lang_code=LANGUAGE_CODE,
            )

            result = next(results)
            audio_array = result.audio  # mx.array

            # Convert MLX array → numpy for the WAV encoder
            if hasattr(audio_array, "tolist"):
                audio_np = np.array(audio_array.tolist(), dtype=np.float32)
            else:
                audio_np = np.asarray(audio_array, dtype=np.float32)

            # Encode to WAV bytes in-memory (no temp files)
            from mlx_audio.audio_io import write as audio_write

            wav_buffer = io.BytesIO()
            audio_write(
                wav_buffer,
                audio_np,
                samplerate=model.sample_rate,
                format="wav",
            )

            audio_base64 = base64.b64encode(wav_buffer.getvalue()).decode("utf-8")
            self._send_json(200, {"ok": True, "audioBase64": audio_base64})

        except ImportError as error:
            self._send_json(
                500,
                {
                    "ok": False,
                    "error": (
                        f"Missing dependency: {error}. "
                        "Ensure mlx-audio and misaki[en] are installed "
                        "(uv run --with mlx-audio --with 'misaki[en]' --with soundfile …)."
                    ),
                },
            )
        except Exception as error:
            traceback.print_exc()
            self._send_json(500, {"ok": False, "error": str(error)})

    def log_message(self, format, *args):
        return


# ── Entrypoint ─────────────────────────────────────────────────────────────


def main():
    # MLX GPU streams are thread-local. A threaded HTTP server can load the
    # model on the main thread and then synthesize on a worker thread, causing
    # `There is no Stream(gpu, 0) in current thread.` Keep all Kokoro calls on
    # the single server thread instead.
    server = HTTPServer((HOST, PORT), TTSHandler)
    print(f"[clicky-tts] listening on http://{HOST}:{PORT}")

    # Pre-warm the model eagerly (can take several seconds on first boot
    # but guarantees zero cold-start penalty for the first request).
    global _tts_startup_error
    try:
        _ensure_model()
    except Exception as exc:
        _tts_startup_error = exc
        print(f"[clicky-tts] WARNING: model pre-warm failed ({exc}). "
              "The server will still accept requests and retry loading on demand.")

    server.serve_forever()


if __name__ == "__main__":
    main()
