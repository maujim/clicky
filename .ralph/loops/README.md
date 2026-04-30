# Ready-to-Dispatch Ralph Loops

Dispatch these one at a time. They are ordered to minimize conflicts.

1. `01-local-vision-lifecycle.md` — user-facing handling for missing/dead local vision server.
2. `02-speech-server-recovery.md` — targeted STT/TTS restart + one retry on connection failures.
3. `03-bundle-local-speech-resources.md` — package `local_speech` scripts into the `.app` bundle.
4. `04-tts-warm-server.md` — investigate/implement in-process Kokoro TTS to reduce latency.
5. `05-rename-vision-client.md` — project-file-aware rename from `ClaudeAPI` to `VisionChatClient`.
6. `06-worker-fallback-decision.md` — decide whether Worker routes are fallback, selectable mode, or dead code.

Global rule for every loop: do **not** run terminal `xcodebuild`; use Xcode for build verification.
