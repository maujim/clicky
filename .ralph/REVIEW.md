# Review of the Ralph Commit Audit

This reviews the prior agent's work in `./.ralph` against the current repository state.

## Bottom Line

The prior audit is useful as a commit-by-commit notebook, but it is not a reliable final answer to “what needs working on.” It contains stale claims, misses some cross-cutting architecture drift, and does not prioritize the remaining work clearly.

The biggest current issue is not one isolated commit. It is that the app is halfway through a cloud/Claude/OpenAI/ElevenLabs → local-model migration, and many names, comments, docs, worker routes, and lifecycle assumptions still describe the old architecture.

## What the Prior Agent Got Right

- Covered all Mukund-authored commits visible on the current branch.
- Correctly identified the migration arc:
  - local OpenAI-compatible vision endpoint,
  - local Whisper MLX transcription,
  - local Kokoro TTS,
  - long-lived local STT/TTS servers,
  - cleanup of OpenAI and ElevenLabs naming.
- Correctly surfaced several real follow-up items:
  - TTS server still shells out per request.
  - STT/TTS bootstrap is coupled.
  - `ensureServersRunning()` is called from multiple places.
  - local vision server has no healthcheck/bootstrap/recovery.
  - documentation and comments need cleanup.

## Where the Prior Agent Was Wrong or Too Optimistic

### 1. It claimed documentation cleanup was complete when it is not

`.ralph/remove-elevenlabs.md` says docs were updated, but current files still contain old architecture descriptions.

Examples:

- `AGENTS.md` still describes Claude via Cloudflare Worker as the AI chat path.
- `AGENTS.md` still lists `/chat` as Anthropic/Claude proxying.
- `README.md` still describes Claude SSE and cloud proxy assumptions.
- `ClaudeAPI.swift` still says it is Claude/Cloudflare-specific even though it now sends OpenAI-compatible chat-completions requests.

### 2. It did not emphasize the architecture/name mismatch enough

Current code uses local vision:

- `CompanionManager.swift` points to `http://127.0.0.1:8080/v1/chat/completions`.
- model picker uses Liquid VL model IDs.
- `ClaudeAPI.swift` builds OpenAI-compatible `messages` with `image_url` blocks.

But many symbols still say Claude:

- `ClaudeAPI`
- `sendTranscriptToClaudeWithScreenshot`
- `selectedClaudeModel`
- many comments about Claude responses and TLS warmup
- `ElementLocationDetector.swift` Claude Computer Use comments

This is a major maintainability problem and should be handled as a top-priority cleanup.

### 3. It left stale review artifacts unflagged

Some generated review files are now outdated. For example, `CODE_REVIEW_UPDATED.md` still lists the local Whisper rename / `Info.plist` provider rename as pending, even though HEAD has:

- `LocalWhisperTranscriptionProvider.swift`
- `VoiceTranscriptionProvider = local-whisper`

The prior agent should have marked those review artifacts as stale or updated them.

### 4. It was too checklist-heavy and not priority-driven

Most `.ralph/*.md` files are commit summaries with broad TODOs. That is useful raw material, but it does not answer “what should I work on next?” clearly.

## Current Prioritized Work

### P0 — Decide and document the actual architecture

Choose one of these paths:

1. **Fully local-first:** local vision + local STT + local TTS, with Cloudflare only for optional/fallback services.
2. **Hybrid:** local speech, but Claude/Cloudflare still supported for vision.
3. **Experimental branch:** local models are WIP and docs should say so explicitly.

Right now the repo reads like all three at once.

### P1 — Rename/refactor local vision client naming

Recommended cleanup:

- Rename `ClaudeAPI.swift` / `ClaudeAPI` to something like `VisionChatClient` or `LocalVisionChatClient`.
- Rename `sendTranscriptToClaudeWithScreenshot` to `sendTranscriptToVisionModelWithScreenshot`.
- Rename `selectedClaudeModel` / `selectedClaudeModel` UserDefaults key to local-vision naming, with a migration fallback if preserving user settings matters.
- Update comments that still mention Claude where the code now targets local OpenAI-compatible vision.

### P1 — Fix docs to match current behavior

Update:

- `AGENTS.md`
- `README.md`
- `ClaudeAPI.swift` file header/comments, or rename the file first
- worker docs/comments if `/chat` is no longer used by the app

Do not claim Anthropic/Claude is the main path if the app defaults to Liquid VL locally.

### P1 — Add local vision server lifecycle/error handling

Current local speech servers have a bootstrapper. Local vision does not appear to have equivalent lifecycle handling.

Needed:

- healthcheck before first request,
- clear user-facing error if `127.0.0.1:8080` is unavailable,
- timeout/retry behavior,
- recovery if the server dies,
- documentation for how the local vision server is started.

### P2 — Decouple STT and TTS bootstrap

`LocalSpeechServiceBootstrap.ensureServersRunning()` starts/checks both servers together. That means a TTS failure can block STT and vice versa.

Better shape:

- `ensureSTTServerRunning()`
- `ensureTTSServerRunning()`
- optional `ensureAllSpeechServersRunning()` for app startup

### P2 — Make local server crash recovery intentional

After initial bootstrap, clients should either:

- retry/restart the relevant server on connection failure, or
- fail fast with a very clear message.

Right now the behavior is not clearly designed.

### P2 — Improve TTS latency

`local_speech/tts_server.py` still shells out to `mlx_audio.tts.generate` per request. This likely avoids Swift-side process startup but still leaves meaningful per-request overhead.

Investigate whether Kokoro can be loaded and reused in-process, similar to STT.

### P2 — Remove hardcoded/developer-specific paths

`resolveLocalUVExecutablePath()` includes `/Users/mukund/.local/bin/uv`. That is okay for local hacking, but not portable.

Prefer:

- bundle/config driven path,
- robust PATH construction,
- common Homebrew/user-local paths without user-specific absolute paths,
- clear installation error if `uv` is missing.

### P2 — Production packaging of `local_speech`

The bootstrap appears to resolve scripts relative to development paths. Verify the app works when built as an `.app` outside the source tree.

If this is meant to ship, package `local_speech/*.py` as bundle resources and resolve via `Bundle.main`.

### P3 — Clean stale review artifacts

Either update or delete/archive:

- `CODE_REVIEW_UPDATED.md`
- `CODE_REVIEW_ea2851e..HEAD.md`

They contain stale TODOs and old filenames that are no longer true at HEAD.

## Suggested Next PRs

### PR 1 — Local architecture cleanup

Scope:

- rename `ClaudeAPI` to a neutral local vision client name,
- rename key methods/properties in `CompanionManager.swift`,
- update comments and docs,
- remove stale review artifacts.

This is mostly mechanical and will make later work less confusing.

### PR 2 — Speech bootstrap hardening

Scope:

- split STT/TTS bootstrap,
- make restart behavior explicit,
- remove redundant `ensureServersRunning()` calls or make them intentionally per-service,
- remove user-specific `uv` paths.

### PR 3 — Local vision bootstrap

Scope:

- add healthcheck/error handling for the local vision endpoint,
- document how it is launched,
- add recovery/fallback behavior if desired.

### PR 4 — TTS performance

Scope:

- investigate in-process Kokoro server implementation,
- benchmark before/after,
- keep model warm if possible.

## Final Assessment

The prior Ralph work is a decent goblin pile of shiny commit notes, but it needs sorting. The important work now is finishing the local-model migration cleanly: names, docs, lifecycle, packaging, and server recovery.
