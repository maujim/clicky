# leanring-buddy Target Notes

This directory contains the main macOS app target. The authoritative project instructions live in the repository-root `AGENTS.md` / `CLAUDE.md`.

Important local reminders:

- This is a menu bar-only SwiftUI/AppKit app, not a document/window-based app.
- Speech is local and in-process through Argmax:
  - STT: `LocalWhisperTranscriptionProvider.swift` using `WhisperKit()` defaults.
  - TTS: `LocalTTSClient.swift` using `TTSKit()` defaults.
- Vision chat uses `VLMClient.swift` against the local OpenAI-compatible endpoint.
- Do not reintroduce the old Python `local_speech` STT/TTS servers, Cloudflare Worker proxy, AssemblyAI provider, or Claude API client.
- Keep UI state changes on `@MainActor` and preserve the menu-bar/no-dock app pattern.
