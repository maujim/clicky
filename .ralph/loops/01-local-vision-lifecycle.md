# Ralph Loop: Local Vision Server Lifecycle

## Goal

Make the local OpenAI-compatible vision endpoint (`http://127.0.0.1:8080/v1/chat/completions`) explicit, observable, and failure-friendly.

## Context

The app currently defaults to a local vision endpoint but does not manage or healthcheck that server the way it manages local STT/TTS. If the server is missing or dead, users likely see a generic request failure.

## Constraints

- Do **not** run terminal `xcodebuild`.
- Keep changes focused on vision lifecycle/error handling.
- Do not rename `ClaudeAPI.swift` in this loop unless required for the implementation.
- Preserve current local endpoint/model defaults.

## Tasks

- [ ] Identify all local vision request call sites.
- [ ] Add a small local vision healthcheck abstraction or method.
- [ ] Before first vision request, detect whether the endpoint is reachable.
- [ ] Surface a clear user-facing error when the local vision server is unavailable.
- [ ] Add a timeout appropriate for local server failures.
- [ ] Decide whether this loop should auto-start the vision server or only document/manual-check it. If auto-start requires unknown external commands, do **not** guess; add a clear TODO instead.
- [ ] Update `README.md` / `AGENTS.md` if startup expectations change.

## Verification

- [ ] With no local vision server running, app should fail gracefully with a clear message.
- [ ] With local vision server running, existing screenshot → vision response flow should still work.
- [ ] Search for stale docs that imply local vision is auto-managed if it is not.

## Suggested Commit Message

`Handle local vision server availability clearly`
