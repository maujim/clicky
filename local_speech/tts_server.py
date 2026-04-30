import base64
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("CLICKY_TTS_HOST", "127.0.0.1")
PORT = int(os.environ.get("CLICKY_TTS_PORT", "8766"))
MODEL = os.environ.get("CLICKY_TTS_MODEL", "mlx-community/Kokoro-82M-4bit")
VOICE = os.environ.get("CLICKY_TTS_VOICE", "af_heart")
LANGUAGE_CODE = os.environ.get("CLICKY_TTS_LANGUAGE_CODE", "a")


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
            self._send_json(
                200,
                {
                    "ok": True,
                    "model": MODEL,
                    "voice": VOICE,
                    "languageCode": LANGUAGE_CODE,
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

            temp_directory_path = f"/tmp/clicky-tts-{os.getpid()}-{os.urandom(4).hex()}"
            os.makedirs(temp_directory_path, exist_ok=True)

            try:
                command = [
                    "python",
                    "-m",
                    "mlx_audio.tts.generate",
                    "--model",
                    MODEL,
                    "--text",
                    text,
                    "--voice",
                    VOICE,
                    "--lang_code",
                    LANGUAGE_CODE,
                    "--output_path",
                    temp_directory_path,
                ]

                process = subprocess.run(
                    command,
                    capture_output=True,
                    text=True,
                    check=False,
                )

                if process.returncode != 0:
                    error_message = (process.stdout or "") + "\n" + (process.stderr or "")
                    self._send_json(500, {"ok": False, "error": error_message.strip()})
                    return

                generated_files = [
                    os.path.join(temp_directory_path, file_name)
                    for file_name in os.listdir(temp_directory_path)
                    if file_name.lower().endswith((".wav", ".mp3", ".m4a"))
                ]

                if not generated_files:
                    self._send_json(500, {"ok": False, "error": "no_audio_file_generated"})
                    return

                newest_audio_file_path = max(generated_files, key=os.path.getmtime)
                with open(newest_audio_file_path, "rb") as audio_file:
                    audio_bytes = audio_file.read()

                audio_base64 = base64.b64encode(audio_bytes).decode("utf-8")
                self._send_json(200, {"ok": True, "audioBase64": audio_base64})
            finally:
                for file_name in os.listdir(temp_directory_path):
                    try:
                        os.remove(os.path.join(temp_directory_path, file_name))
                    except OSError:
                        pass
                try:
                    os.rmdir(temp_directory_path)
                except OSError:
                    pass

        except Exception as error:
            self._send_json(500, {"ok": False, "error": str(error)})

    def log_message(self, format, *args):
        return


def main():
    server = ThreadingHTTPServer((HOST, PORT), TTSHandler)
    print(f"[clicky-tts] listening on http://{HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
