# Second-Pass Review of Mukund Commits and Prior Ralph Audit

Date: 2026-04-30
Branch: `mukund/local-models`

## Scope

This is the requested second pass over the prior agent's `./.ralph` work. I verified claims against the current working tree, removed TODOs already fixed by later commits, separated runtime blockers from cleanup/naming/docs issues, and produced a prioritized action plan.

## Executive Summary

The prior agent's files in `./.ralph` are useful raw commit notes, but they should not be treated as the final source of truth. Several TODOs are stale, several file names are historical, and the biggest remaining issue is cross-cutting: the codebase is partly migrated to local models, but naming, docs, worker routes, and lifecycle handling still reflect the old Claude/OpenAI/ElevenLabs/Cloudflare architecture.

The most important work now is:

1. **Runtime:** add lifecycle/health/error handling for the local vision server.
2. **Runtime:** harden local speech crash recovery now that STT and TTS startup are decoupled.
3. **Runtime/perf:** stop shelling out per TTS request if Kokoro can be kept warm in-process.
4. **Packaging:** make `local_speech` scripts and `uv` resolution production-safe.
5. **Cleanup:** finish the local-model rename/docs cleanup so the repo no longer says Claude/Cloudflare where it means local OpenAI-compatible vision.

## Verified Current State

### Current commit set

`git log --author='mukund' --oneline --all` shows these relevant commits:

- `ea2851e` Switch vision chat to local OpenAI-compatible Liquid-VL endpoint
- `216d61f` Switch speech pipeline to local Whisper MLX and Kokoro TTS
- `64c5ce6` Remove onboarding email collection flow
- `dd75929` Fix local speech env paths and localhost model fallback handling
- `020c9b2` Run local STT and TTS as long-lived background services
- `39b49bb` Xcode project config
- `7b958b6` Remove ElevenLabs code / rename to LocalTTSClient
- `6794ef2` Add healthcheck delay
- `7bcb78c` Replace OpenAI speech transcription with Local Whisper provider

### Confirmed fixed / no longer current TODOs

These TODOs from the prior audit are already resolved or only historical:

- `hasSubmittedEmail` / `submitEmail` references are gone from app code.
- `OpenAIAudioTranscriptionProvider.swift` has been renamed to `LocalWhisperTranscriptionProvider.swift`.
- `OpenAIAPI.swift` is gone; only `AGENTS.md` mentions it as removed.
- `Info.plist` uses `VoiceTranscriptionProvider = local-whisper`.
- ElevenLabs app/worker code appears removed; remaining hits are stale review docs only.
- STT now uses structured JSON from `stt_server.py`; old stdout parsing concerns are historical.
- The initial one-shot Swift subprocess speech path is historical; speech now goes through local HTTP servers.

### Confirmed still true / needs work

These are real issues in current HEAD:

- `ClaudeAPI.swift` is now an OpenAI-compatible local vision client and its comments have been updated, but the file/type are still misnamed.
- `CompanionManager.swift` had Claude-specific names/comments; this pass renamed the main method and client property, but the legacy `selectedClaudeModel` UserDefaults key remains only as migration fallback.
- `AGENTS.md` and `README.md` have been updated to describe the local-first path.
- `worker/src/index.ts` still exposes `/chat` to Anthropic, though current app vision appears to use `127.0.0.1:8080` directly.
- Local vision endpoint has no visible bootstrap/healthcheck/recovery equivalent to local speech.
- `LocalSpeechServiceBootstrap` now has separate STT and TTS ensure methods; crash recovery/retry behavior is still underspecified.
- `ensureServersRunning()` remains as eager app-start warmup in `CompanionManager.start()`; per-client calls now use service-specific STT/TTS ensure methods.
- `local_speech/tts_server.py` shells out to `python -m mlx_audio.tts.generate` for every `/speak` request.
- `AppBundleConfiguration.localSpeechScriptURL()` relies on `#filePath` and source-tree-relative `local_speech`, not app bundle resources.
- `resolveLocalUVExecutablePath()` now uses the current user home directory for `~/.local/bin/uv` instead of a hardcoded `/Users/mukund` path.
- Stale review artifacts remain at repo root: `CODE_REVIEW_ea2851e..HEAD.md` and `CODE_REVIEW_UPDATED.md`.

## Critique of Each Prior `.ralph` File

### `.ralph/remove-email-flow.md`

Mostly accurate. Verified no current app-code references to `hasSubmittedEmail` or `submitEmail`.

Remaining value: low. This is complete unless analytics intentionally needs replacement identity handling.

### `.ralph/switch-vision-local.md`

Accurate about the direction of the commit, but underplays the cleanup fallout.

Current issue: local vision is implemented, but the codebase still has Claude-centric naming and docs. This should have been elevated to a top-level cleanup project.

### `.ralph/speech-pipeline-local.md`

Historically useful, but many TODOs are now stale because later commits replaced one-shot Swift subprocesses with local HTTP servers.

Still relevant only as history. Current speech concerns should focus on server lifecycle, packaging, and TTS subprocess-per-request behavior.

### `.ralph/fix-env-paths.md`

Partly stale.

Accurate:

- `127.0.0.1` is now used for local speech and local vision endpoints.
- GUI PATH handling is a real concern.

Stale/historical:

- References to `ElevenLabsTTSClient.swift` and `OpenAIAudioTranscriptionProvider.swift` are old file names.
- Subprocess error pattern matching from the one-shot path is less central now.

Still needs work:

- `resolveLocalUVExecutablePath()` now uses the current user home directory for `~/.local/bin/uv`.
- `uv` failure UX still deserves clearer user-facing error handling.

### `.ralph/long-lived-servers.md`

One of the most useful files. Its core issues are still valid.

Confirmed still valid:

- TTS server shells out per request.
- STT/TTS bootstrap is coupled.
- Production bundling of scripts is not solved.
- Crash/recovery behavior is not clearly designed.

Correction: the claim “subsequent requests are ~100-500ms” may be optimistic for TTS because Kokoro is still invoked via subprocess per `/speak`.

### `.ralph/xcode-config.md`

Accurate but low priority. Do not run terminal `xcodebuild` per project instructions.

### `.ralph/remove-elevenlabs.md`

Mostly accurate about code removal, but overstates doc cleanup.

Correct:

- app/worker ElevenLabs symbols appear gone.

Incorrect/overstated:

- “Updated all docs” is not true in the broader architecture sense. `AGENTS.md` and `README.md` still describe stale cloud/Claude flow.

### `.ralph/healthcheck-delay.md`

Accurate but minor. The 1s delay reduces log noise but is not a robust readiness strategy by itself.

Note: because `ensureServersRunning()` checks STT then TTS sequentially and `waitForHealthcheck()` sleeps 1s each time, startup adds at least 2s of fixed delay when both checks are needed.

### `.ralph/whisper-provider-rename.md`

Mostly accurate and current.

Correction: it says `ClaudeAPI.swift` old Claude/Anthropic references were removed, but current `ClaudeAPI.swift` still has Claude/Cloudflare comments in its header and doc comments.

## Runtime Blockers / Product Risks

### R1 — Local vision server has no lifecycle management

Current app points vision calls at:

`http://127.0.0.1:8080/v1/chat/completions`

But I found no equivalent of `LocalSpeechServiceBootstrap` for this server.

Risk:

- app fails if local vision server is not already running,
- user receives generic connection errors,
- no recovery if the server dies,
- docs do not clearly explain how the server starts.

Recommended fix:

- Add `LocalVisionServiceBootstrap` or clearly document manual server startup.
- Healthcheck before first request.
- Clear panel/overlay error if unavailable.
- Timeout and retry policy.

### R2 — STT and TTS bootstrap have been decoupled; recovery still needs work

This pass split speech bootstrap into service-specific ensure methods and updated STT/TTS clients to start only the service they need.

Remaining risk:

- connection failures after startup do not yet trigger a targeted restart/retry.
- app startup still eagerly starts both services through `ensureServersRunning()`, which is acceptable as a warmup but should not be required for individual client calls.

### R3 — Local speech server crash recovery is underspecified

The bootstrap can relaunch if the tracked `Process` is not running, but HTTP request failures from clients do not clearly trigger targeted restart/retry behavior.

Risk:

- broken local server state persists until app restart,
- user gets generic failures during dictation/TTS.

Recommended fix:

- On connection refused / dropped connection, restart the relevant service once and retry.
- Surface a clear error if retry fails.

### R4 — TTS likely still has avoidable latency

`tts_server.py` shells out to `python -m mlx_audio.tts.generate` on each `/speak`.

Risk:

- model/process overhead on every response,
- inconsistent latency,
- harder cancellation/recovery.

Recommended fix:

- Investigate calling Kokoro synthesis in-process, mirroring how `stt_server.py` imports and calls `mlx_whisper` directly.
- Benchmark before/after.

### R5 — Production packaging is fragile

`localSpeechScriptURL()` uses `#filePath` and source-tree-relative paths.

Risk:

- built `.app` outside repo cannot find `local_speech/stt_server.py` or `tts_server.py`.

Recommended fix:

- Add scripts as app bundle resources.
- Resolve via `Bundle.main.url(forResource:withExtension:subdirectory:)`.
- Keep source-tree fallback only for debug/dev if needed.

### R6 — `uv` resolution is not portable enough

Current known paths include Homebrew locations and the current user's `~/.local/bin/uv`.

Risk:

- other machines fail unless Homebrew path matches,
- user-specific path should not ship.

Recommended fix:

- Remove user-specific absolute path or make it debug-only.
- Include `$HOME/.local/bin/uv` dynamically if desired.
- Provide clear install/setup guidance when `uv` is missing.

## Cleanup / Naming / Docs Work

### C1 — Rename local vision client and related symbols

Current names imply Claude even though the code is OpenAI-compatible local vision.

Recommended names:

- `ClaudeAPI.swift` → `VisionChatClient.swift` or `LocalVisionChatClient.swift`
- `ClaudeAPI` → `VisionChatClient`
- `sendTranscriptToVisionModelWithScreenshot` is now the active method name.
- `selectedClaudeModel` UserDefaults key → local vision naming, optionally with migration fallback

### C2 — Fix stale docs

Update:

- `AGENTS.md`
- `README.md`
- `ClaudeAPI.swift` comments if not renamed
- `worker/src/index.ts` comments if `/chat` is retained as legacy/fallback

Current docs say Claude/Cloudflare is the main path, which conflicts with current code.

### C3 — Clarify Cloudflare Worker role

Current worker still supports:

- `/chat` → Anthropic
- `/transcribe-token` → AssemblyAI

But current default app path appears local vision + local Whisper + local Kokoro.

Choose and document one:

- keep worker as fallback/legacy,
- remove unused `/chat`,
- or wire app back to worker as selectable mode.

### C4 — Clean stale review docs

`CODE_REVIEW_ea2851e..HEAD.md` and `CODE_REVIEW_UPDATED.md` contain stale file names and already-fixed TODOs.

Recommended:

- update them to reflect HEAD, or
- move them into `.ralph/archive`, or
- delete if they are no longer useful.

## Prioritized Action Plan

### P0 — Decide architecture truth

Before broad edits, decide whether this branch is:

1. fully local-first,
2. hybrid local speech + Claude vision fallback,
3. experimental local-model branch with old cloud path kept around.

This decision controls docs, naming, worker cleanup, and UI copy.

### P1 — Runtime stability

1. Add local vision server health/error handling.
2. Add targeted restart/retry for dead local speech servers.
4. Make production packaging of `local_speech` explicit.

### P2 — Performance

1. Investigate in-process Kokoro TTS.
2. Benchmark TTS latency before/after.
3. Remove redundant all-server healthchecks from per-request paths once restart behavior is designed.

### P3 — Cleanup

1. Rename `ClaudeAPI` and Claude-specific symbols.
2. Update `AGENTS.md` and `README.md`.
3. Clarify or remove stale worker routes.
4. Archive stale review docs.

## Suggested PR Breakdown

### PR 1: Local vision naming/docs cleanup

- Rename `ClaudeAPI` to a neutral vision client.
- Rename Claude-specific methods/properties in `CompanionManager.swift`.
- Update docs to accurately state current local-first behavior.
- Do not change behavior.

### PR 2: Speech bootstrap hardening

- Add one retry/restart on local connection failure.
- Keep service-specific startup paths for STT and TTS.
- Remove user-specific `uv` path.

### PR 3: Production resource packaging

- Bundle `local_speech/stt_server.py` and `local_speech/tts_server.py`.
- Resolve scripts via `Bundle.main`.
- Keep dev fallback if useful.

### PR 4: Local vision lifecycle

- Add local vision healthcheck / startup docs / clear error UX.
- Decide whether server is auto-managed or manually managed.

### PR 5: TTS warm server optimization

- Replace subprocess-per-request with in-process Kokoro if feasible.
- Benchmark and document observed latency.

## Final Verdict

The prior Ralph output is a helpful pile of commit notes, but the second-pass answer is: finish the local-model migration. The urgent work is not more feature work; it is making the new local architecture coherent, recoverable, shippable, and honestly documented.


## Changes Applied in This Pass

- Updated `AGENTS.md` to describe local-first vision/STT/TTS and mark Worker routes as legacy/fallback.
- Rewrote `README.md` around the current local-model setup.
- Updated `worker/src/index.ts` comments to mark the Worker as legacy/fallback.
- Renamed key `CompanionManager.swift` references from Claude-specific wording to vision-model wording, including `sendTranscriptToVisionModelWithScreenshot` and `visionChatClient`.
- Added `selectedVisionModel` persistence while preserving `selectedClaudeModel` as a migration fallback.
- Updated `ClaudeAPI.swift` comments to reflect OpenAI-compatible local vision behavior. The type/file still need a project-file-aware rename.
- Updated `AppBundleConfiguration.localSpeechScriptURL()` to prefer bundled `local_speech` resources and use the source-tree path only as a development fallback.
- Replaced the hardcoded `/Users/mukund/.local/bin/uv` lookup with the current user's `~/.local/bin/uv`.
- Moved stale root review docs into `.ralph/archive/`.

- Split `LocalSpeechServiceBootstrap` into `ensureSTTServerRunning()` and `ensureTTSServerRunning()`, and updated STT/TTS clients to call only the service they need.
