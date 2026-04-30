# Ralph Loop: Keep Kokoro TTS Warm

## Goal

Reduce TTS latency by avoiding `subprocess.run(["python", "-m", "mlx_audio.tts.generate", ...])` on every `/speak` request if the `mlx-audio` API supports in-process synthesis.

## Context

`stt_server.py` imports `mlx_whisper` and calls it in-process. `tts_server.py` still shells out for each request, so Kokoro may not stay warm.

## Constraints

- Do **not** run terminal `xcodebuild`.
- This is an investigation + implementation loop. If `mlx-audio` has no stable importable API, document that and keep the subprocess path.
- Preserve current HTTP contract: `/health`, `/speak`, JSON request, `audioBase64` response.
- Keep failure messages clear.

## Tasks

- [x] Inspect installed/available `mlx-audio` docs or module surface for an in-process TTS API.
- [x] If feasible, load model/voice once at server startup or first request.
- [x] Replace per-request subprocess with in-process synthesis.
- [x] Keep temp file cleanup safe.  (no temp files at all — uses BytesIO)
- [ ] If in-process is not feasible, add a comment explaining why and improve subprocess logging/error output.  (not needed — in-process IS feasible and implemented)
- [ ] Benchmark rough before/after latency manually if possible.

## Verification

- [ ] `curl http://127.0.0.1:8766/health` returns ok.
- [ ] `/speak` returns valid base64 WAV audio.
- [ ] Multiple `/speak` calls do not reload the model unnecessarily if in-process path is implemented.

## Investigation Notes

- `mlx-audio` v0.4.3 exposes `mlx_audio.tts.load(path_or_repo)` and `model.generate(text, voice, speed, lang_code)` as a stable in-process API.
- `model.generate()` returns a generator of `GenerationResult` namedtuples with `.audio` (mx.array), `.sample_rate`, `.audio_duration`.
- WAV encoding uses `mlx_audio.audio_io.write(BytesIO, audio_np, samplerate, format="wav")`.
- Kokoro requires the `misaki` package for G2P (already in the uv bootstrap command as `--with misaki`).
- No temp files needed: audio flows entirely through in-memory BytesIO.

## Suggested Commit Message

`Keep local Kokoro TTS warm between requests`
