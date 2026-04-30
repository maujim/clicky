# Ralph Loop: Local Speech Server Recovery

## Goal

Make local STT/TTS server failures recover without requiring an app restart.

## Context

`LocalSpeechServiceBootstrap` now has service-specific ensure methods:

- `ensureSTTServerRunning(whisperModelName:)`
- `ensureTTSServerRunning(ttsModelName:ttsVoiceName:ttsLanguageCode:)`

But client request failures after startup do not yet trigger targeted restart/retry behavior.

## Constraints

- Do **not** run terminal `xcodebuild`.
- Keep STT and TTS independent. A TTS failure must not block transcription.
- Avoid broad rewrites of dictation or playback state machines.

## Tasks

- [ ] Add targeted stop/restart methods for STT and TTS, or safely extend existing bootstrap methods.
- [ ] In `LocalWhisperTranscriptionProvider`, on connection refused / cannot connect / dropped local server errors, restart STT once and retry the request once.
- [ ] In `LocalTTSClient`, on connection refused / cannot connect / dropped local server errors, restart TTS once and retry the request once.
- [ ] Keep non-connectivity HTTP errors as normal failures; do not infinite retry model errors.
- [ ] Add clear logs for first failure, restart attempt, retry success/failure.
- [ ] Ensure cancellation still exits promptly and does not trigger unnecessary retries.

## Verification

- [ ] Start app, kill STT server, then dictate: app should restart STT or produce a clear final error after one retry.
- [ ] Start app, kill TTS server, then request response: app should restart TTS or produce a clear final error after one retry.
- [ ] Rapid cancel/retry should not deadlock.

## Suggested Commit Message

`Recover local speech servers after connection failures`
