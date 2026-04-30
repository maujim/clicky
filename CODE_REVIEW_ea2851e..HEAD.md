# Code Review: ea2851e..HEAD (5 commits)

## Commit Summary

| Commit | Description |
|--------|-------------|
| `216d61f` | Switch speech pipeline from cloud (OpenAI/ElevenLabs) to local Whisper MLX + Kokoro via `uv run` subprocesses |
| `64c5ce6` | Remove onboarding email collection flow (FormSpark + PostHog identify) |
| `dd75929` | Fix `uv` PATH resolution for GUI apps, `localhost` → `127.0.0.1` for IPv4-only servers, race condition fix in `cancel()` |
| `020c9b2` | Replace one-shot subprocesses with long-lived Python HTTP servers (`stt_server.py` :8765, `tts_server.py` :8766) |
| `39b49bb` | Update DEVELOPMENT_TEAM in Xcode project (signing identity change) |

---

## Feedback

### 🟢 Green — Solid work, keep doing this

**Architecture decisions**
- Local-first speech pipeline removes API cost, works offline, and lowers latency
- Long-lived HTTP servers over one-shot subprocesses is the right call for interactive push-to-talk use
- `127.0.0.1` over `localhost` avoids the macOS IPv6 `::1` binding trap
- `LocalSpeechServiceBootstrap` is well-structured: singleton, `@MainActor`, idempotent guard, started on `CompanionManager.start()`, terminated on dealloc

**Clean removals**
- Cloud API surface stripped cleanly — provider no longer checks `apiKey`, always reports `isConfigured = true`
- Onboarding email gate removed without dangling references — `CompanionPanelView` dropped ~64 lines

**Correctness**
- `DispatchSpecificKey` cancel fix caught a real deinit race — `stateQueue.async` in `cancel()` now runs synchronously so state is updated before deallocation
- Healthcheck with retry (30 × 200ms) handles variable ML model loading times

**Python server quality**
- `ThreadingHTTPServer` for concurrent requests, proper HTTP status codes on errors
- Temp file cleanup in `finally` blocks, `log_message` suppressed
- Base64-encoded audio in JSON avoids multipart complexity
- Configurable model/voice via environment variables, with sensible defaults

**Config**
- `Info.plist` gains `LocalWhisperModel`, `LocalTTSModel`, `LocalTTSVoice`, `LocalTTSLanguageCode` — model choice is configurable without recompiling

---

### 🟡 Yellow — Watch / be aware of

| # | Issue | Location |
|---|-------|----------|
| 1 | **`waitUntilExit()` blocks a Swift concurrency thread** inside `ElevenLabsTTSClient.speakText()` (commit 1, later replaced). The correct async idiom is `await process.runUntilExit()`. Not a current bug (code was replaced in commit 4), but the pattern should be avoided in future Process usage. | `ElevenLabsTTSClient.swift` (historical) |
| 2 | **Transcript parsing from stdout was fragile** (commit 1) — filtered lines not starting with `[` and not containing "fetching"/"downloading". Tied to mlx-whisper log format. Fixed in commit 4 by using the structured JSON response from the STT server. | `OpenAIAudioTranscriptionProvider.swift` (historical) |
| 3 | **PostHog import removed from `CompanionManager.swift`** — verify `ClickyAnalytics.swift` still compiles and functions correctly (it likely imports PostHog independently). | `CompanionManager.swift` |
| 4 | **`URLSession.shared` vs dedicated session inconsistency** — STT uses `URLSession.shared` to call its local server; TTS uses a dedicated `session` instance. Both call localhost; neither needs to be different. Pick one and standardize. | `OpenAIAudioTranscriptionProvider.swift`, `ElevenLabsTTSClient.swift` |
| 5 | **`localSpeechScriptURL` is dev-only** — relies on `#filePath` to derive the project root directory. Won't resolve in a shipped `.app` bundle because `local_speech/` won't be adjacent to the source file. The `scriptNotFound` error path handles this gracefully, but production builds need the scripts bundled as app resources. | `AppBundleConfiguration.swift` |
| 6 | **`ensureServersRunning` requires both servers** — if only STT is needed but TTS fails to start, the call throws and STT is also blocked. The two servers should be independently startable. | `LocalSpeechServiceBootstrap` in `AppBundleConfiguration.swift` |

---

### 🔴 Red — Fix / take action

| # | Issue | Impact | Location |
|---|-------|--------|----------|
| 1 | **TTS server cold-starts a subprocess on every request** — `tts_server.py` calls `subprocess.run(["python", "-m", "mlx_audio.tts.generate", ...])` for each `/speak`. The model is not kept warm in the server's process memory. By contrast, `stt_server.py` calls `mlx_whisper.transcribe()` in-process so the model stays loaded after first use. This asymmetry means TTS per-request latency is still high — the server only saves the `uv`/Python process startup, not the model load. | `local_speech/tts_server.py` |
| 2 | **`ensureServersRunning` called redundantly from both clients** — `ElevenLabsTTSClient.speakText()` and `OpenAIAudioTranscriptionSession.transcribeWithLocalWhisper()` each call it. The idempotency guard makes subsequent calls no-ops, but this is a code smell. The bootstrap should be a single pre-flight in `CompanionManager.start()`, and the clients should assume servers are already running (or fail fast with a clear error). | `ElevenLabsTTSClient.swift`, `OpenAIAudioTranscriptionProvider.swift` |

---

## Next Steps (ordered by priority)

### 🔴 1. Keep the TTS model warm in-process

`tts_server.py` currently shells out to `mlx_audio.tts.generate` on every `/speak` request. Import `mlx_audio` at module level and call the synthesis function in-process, the same way `stt_server.py` uses `mlx_whisper.transcribe()` directly. This eliminates per-request model loading latency — the biggest remaining performance gap in the pipeline.

**Files:** `local_speech/tts_server.py`

### 🔴 2. Move server bootstrap to a single pre-flight

Remove `ensureServersRunning` calls from `ElevenLabsTTSClient.speakText()` and `OpenAIAudioTranscriptionSession.transcribeWithLocalWhisper()`. The `CompanionManager.start()` already calls it — that is the right trigger. The TTS and STT clients should assume servers are running and fail with a clear error if they aren't, rather than re-checking on every utterance.

**Files:** `ElevenLabsTTSClient.swift`, `OpenAIAudioTranscriptionProvider.swift`

### 🟡 3. Decouple STT and TTS server startup

Split `ensureServersRunning` (or add separate `ensureSTTServer`/`ensureTTSServer` methods) so that a failure in one server doesn't block the other. A TTS failure shouldn't prevent transcription from working.

**Files:** `AppBundleConfiguration.swift` (LocalSpeechServiceBootstrap)

### 🟡 4. Standardize URLSession usage

Both STT and TTS call localhost — pick one approach (dedicated session or shared) and use it consistently.

**Files:** `OpenAIAudioTranscriptionProvider.swift`, `ElevenLabsTTSClient.swift`

### 🟡 5. Verify PostHog / analytics still works

`CompanionManager.swift` no longer imports PostHog after the email flow was removed. Confirm `ClickyAnalytics.swift` imports it independently and all analytics events still fire.

**Files:** `ClickyAnalytics.swift`, `CompanionManager.swift`

### 🟡 6. Bundle Python scripts for production

`localSpeechScriptURL` resolves via `#filePath` which only works with the Xcode source tree. For a distributable build, add `stt_server.py` and `tts_server.py` to the app bundle as resources and resolve them from `Bundle.main`.

**Files:** `AppBundleConfiguration.swift`, Xcode project

### 🟢 7. (Nice to have) Use `await process.runUntilExit()` pattern

Any future Process usage should prefer `process.runUntilExit()` from the Swift concurrency Process extensions rather than blocking `waitUntilExit()`.

**Files:** Any future Process usage
