# Code Review: ea2851e..HEAD (6 commits, updated after ElevenLabs removal)

## Commit Summary

| Commit | Description |
|--------|-------------|
| `216d61f` | Switch speech pipeline from cloud (OpenAI/ElevenLabs) to local Whisper MLX + Kokoro via `uv run` subprocesses |
| `64c5ce6` | Remove onboarding email collection flow (FormSpark + PostHog identify) |
| `dd75929` | Fix `uv` PATH resolution for GUI apps, `localhost` → `127.0.0.1` for IPv4-only servers, race fix in `cancel()` |
| `020c9b2` | Replace one-shot subprocesses with long-lived Python HTTP servers (`stt_server.py` :8765, `tts_server.py` :8766) |
| `39b49bb` | Update DEVELOPMENT_TEAM in Xcode project (signing identity change) |
| `1e8aadd` | **Remove all ElevenLabs code** — rename `ElevenLabsTTSClient` → `LocalTTSClient`, drop `/tts` worker route, strip `ELEVENLABS_*` secrets, remove `trackTTSError`, update docs |

---

## Feedback

### 🟢 Green — Solid work, keep doing this

| # | Item |
|---|------|
| G1 | Local-first speech pipeline — removes API cost, works offline, lower latency |
| G2 | Long-lived HTTP servers over one-shot subprocesses — right call for interactive push-to-talk |
| G3 | `127.0.0.1` over `localhost` — avoids macOS IPv6 `::1` binding trap |
| G4 | `LocalSpeechServiceBootstrap` — well-structured singleton, `@MainActor`, idempotent, started on app launch, terminated on dealloc |
| G5 | Cloud API surface stripped cleanly — provider always reports `isConfigured = true` |
| G6 | Onboarding email gate removed without dangling references |
| G7 | `DispatchSpecificKey` cancel fix — caught a real deinit race |
| G8 | Healthcheck with retry (30×200ms) handles variable model load times |
| G9 | Python servers: `ThreadingHTTPServer`, proper HTTP status codes, temp file cleanup, base64 JSON payloads, configurable via env vars |
| G10 | `Info.plist` gains `LocalWhisperModel`, `LocalTTSModel`, `LocalTTSVoice`, `LocalTTSLanguageCode` — configurable without recompiling |
| G11 | ElevenLabs code fully purged — file renamed, worker route dropped, secrets removed, analytics event deleted, `workerBaseURL` gone from `CompanionManager` |

---

### 🟡 Yellow — Watch / be aware of

| # | Issue | Current state | Files |
|---|-------|---------------|-------|
| Y1 | ~~`waitUntilExit()` blocks Swift concurrency thread~~ | **Resolved.** Code was in the old `ElevenLabsTTSClient` which no longer exists. The new `LocalTTSClient` calls the HTTP server, not a subprocess. | Historical |
| Y2 | ~~Transcript parsing from stdout was fragile~~ | **Resolved.** Replaced by structured JSON from STT server in commit 4. | Historical |
| Y3 | **`URLSession.shared` vs dedicated session** — STT uses `.shared`, TTS has a dedicated `session`. Both call localhost; no reason for the asymmetry. | Still present. `OpenAIAudioTranscriptionProvider.swift:176` uses `.shared`, `LocalTTSClient.swift` uses a dedicated session. | `OpenAIAudioTranscriptionProvider.swift`, `LocalTTSClient.swift` |
| Y4 | **`localSpeechScriptURL` is dev-only** — relies on `#filePath` to find `local_speech/`. Won't work in a shipped `.app` bundle. | Still present. `scriptNotFound` error handles gracefully, but production builds need scripts bundled as resources. | `AppBundleConfiguration.swift` |
| Y5 | **`ensureServersRunning` couples STT and TTS** — if TTS startup fails, the whole call throws even if only STT is needed. | Still present. Both servers launched together unconditionally. | `AppBundleConfiguration.swift` (LocalSpeechServiceBootstrap) |
| Y6 | **PostHog import only in `ClickyAnalytics.swift`** — `CompanionManager.swift` no longer imports PostHog. `ClickyAnalytics.swift` imports it independently. ✅ No action needed, but keep an eye on analytics after the `trackTTSError` removal left an empty trailing block. | `ClickyAnalytics.swift` has a trailing blank line after `trackTTSError` removal — minor cosmetic. | `ClickyAnalytics.swift` |

---

### 🔴 Red — Fix / take action

| # | Issue | Impact | Files |
|---|-------|--------|-------|
| R1 | **TTS server cold-starts a subprocess on every `/speak`** — `tts_server.py` calls `subprocess.run(["python", "-m", "mlx_audio.tts.generate", ...])` for each request. Model not kept warm. STT server calls `mlx_whisper.transcribe()` in-process — model stays loaded. Asymmetry means TTS still has high per-request latency. | `local_speech/tts_server.py` |
| R2 | **`ensureServersRunning` called redundantly from 3 places** — `CompanionManager.start()`, `LocalTTSClient.speakText()`, and `OpenAIAudioTranscriptionSession.transcribeWithLocalWhisper()`. Idempotency guard makes it harmless but it's a code smell. Should be a single pre-flight in `CompanionManager`. | `LocalTTSClient.swift`, `OpenAIAudioTranscriptionProvider.swift`, `CompanionManager.swift` |

---

## Checklist — Remove remaining cruft

- [x] Rename `ElevenLabsTTSClient.swift` → `LocalTTSClient.swift` (done in `1e8aadd`)
- [x] Drop `/tts` route from Cloudflare Worker (done in `1e8aadd`)
- [x] Remove `ELEVENLABS_API_KEY` and `ELEVENLABS_VOICE_ID` from worker env/types (done in `1e8aadd`)
- [x] Remove `trackTTSError` from `ClickyAnalytics.swift` (done in `1e8aadd`)
- [x] Remove `workerBaseURL` from `CompanionManager.swift` (done in `1e8aadd`)
- [x] Update `AGENTS.md` table and architecture section (done in `1e8aadd`)
- [x] Update `README.md` (done in `1e8aadd`)
- [ ] Clean up empty trailing block in `ClickyAnalytics.swift` after `trackTTSError` removal
- [ ] Consider renaming `OpenAIAudioTranscriptionProvider.swift` → `LocalWhisperTranscriptionProvider.swift` (class name is now a misnomer — it uses local Whisper MLX, not OpenAI)
- [ ] Update `Info.plist` `VoiceTranscriptionProvider` key — currently `openai` but the provider is now local whisper. Rename or add a new value like `local-whisper`
- [ ] `BuddyTranscriptionProvider.swift` factory — check the provider resolution logic still correctly maps `openai` → the local whisper provider

---

## Next Steps (ordered by priority)

### 🔴 R1 — Keep the TTS model warm in-process

`tts_server.py` shells out to `mlx_audio.tts.generate` on every `/speak`. Import `mlx_audio` at module level and call synthesis in-process, matching how `stt_server.py` uses `mlx_whisper.transcribe()` directly.
→ **Ralph loop:** `red-warm-tts-model`

### 🔴 R2 — Move server bootstrap to a single pre-flight

Remove `ensureServersRunning` from `LocalTTSClient.speakText()` and `OpenAIAudioTranscriptionSession.transcribeWithLocalWhisper()`. `CompanionManager.start()` already calls it. Clients should assume servers are running and fail fast if not.
→ **Ralph loop:** `red-single-bootstrap`

### 🟡 Y3 — Standardize URLSession usage

Both STT and TTS call localhost — use either `.shared` or a dedicated session consistently across both.
→ **Ralph loop:** `yellow-urlsession-consistency`

### 🟡 Y5 — Decouple STT and TTS server startup

Split `ensureServersRunning` so a failure in one server doesn't block the other.
→ **Ralph loop:** `yellow-decouple-servers`

### 🟡 Y4 — Bundle Python scripts for production

Add `stt_server.py` and `tts_server.py` to the Xcode target as bundled resources, resolve from `Bundle.main`.
→ **Ralph loop:** `yellow-bundle-scripts`

### 🟡 Final cleanup checklist items

Rename provider files/keys, clean up analytics trailing space, update `Info.plist`.
→ **Ralph loop:** `yellow-cleanup-cruft`
