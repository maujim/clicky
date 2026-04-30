import base64
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import mlx_whisper

HOST = os.environ.get("CLICKY_STT_HOST", "127.0.0.1")
PORT = int(os.environ.get("CLICKY_STT_PORT", "8765"))
MODEL = os.environ.get("CLICKY_STT_MODEL", "mlx-community/whisper-base-mlx-fp32")


class STTHandler(BaseHTTPRequestHandler):
    def _send_json(self, status_code: int, payload: dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"ok": True, "model": MODEL})
            return
        self._send_json(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        if self.path != "/transcribe":
            self._send_json(404, {"ok": False, "error": "not_found"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            raw_body = self.rfile.read(content_length)
            payload = json.loads(raw_body.decode("utf-8"))

            audio_base64 = payload.get("audioBase64", "")
            if not audio_base64:
                self._send_json(400, {"ok": False, "error": "missing_audio"})
                return

            audio_data = base64.b64decode(audio_base64)
            temp_wav_path = f"/tmp/clicky-stt-{os.getpid()}-{os.urandom(4).hex()}.wav"
            with open(temp_wav_path, "wb") as audio_file:
                audio_file.write(audio_data)

            try:
                result = mlx_whisper.transcribe(
                    temp_wav_path,
                    path_or_hf_repo=MODEL,
                    fp16=False,
                )
                transcript_text = (result.get("text") or "").strip()
                self._send_json(200, {"ok": True, "text": transcript_text})
            finally:
                try:
                    os.remove(temp_wav_path)
                except OSError:
                    pass

        except Exception as error:
            self._send_json(500, {"ok": False, "error": str(error)})

    def log_message(self, format, *args):
        return


def main():
    server = ThreadingHTTPServer((HOST, PORT), STTHandler)
    print(f"[clicky-stt] listening on http://{HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
