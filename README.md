Update: April 30, 2026.

Hi there! I'm Farza, the guy that made Clicky.

The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private. To get the latest Clicky, you can go [here](https://www.heyclicky.com/).

Go crazy with this repo!! It's an MIT license.

# Hi, this is Clicky.

It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and point at stuff. Kinda like having a real teacher next to you.

This branch is local-model focused: local vision, local Whisper MLX speech-to-text, and local Kokoro TTS.

## Manual setup

### Prerequisites

- macOS 14.2+ for ScreenCaptureKit
- Xcode 15+
- [`uv`](https://github.com/astral-sh/uv) available from Homebrew, `/usr/local/bin`, or `~/.local/bin`
- A local OpenAI-compatible vision server listening at `http://127.0.0.1:8080/v1/chat/completions`
- Optional: Node.js 18+ and Cloudflare/Wrangler if you want to use the legacy Worker fallback routes

### Run the app

```bash
open leanring-buddy.xcodeproj
```

In Xcode:

1. Select the `leanring-buddy` scheme. The typo is intentional.
2. Set your signing team under Signing & Capabilities.
3. Hit **Cmd + R** to build and run.

Do not use terminal `xcodebuild` for normal local runs; it can invalidate macOS TCC permissions and force you to re-grant Screen Recording / Accessibility.

The app appears in your menu bar, not the dock. Click the icon, grant permissions, and use **Control + Option** for push-to-talk.

### Local speech services

The app starts two Python HTTP services through `uv`:

- `local_speech/stt_server.py` on `127.0.0.1:8765` for Whisper MLX transcription
- `local_speech/tts_server.py` on `127.0.0.1:8766` for Kokoro TTS

The Swift bootstrap first looks for these scripts in the app bundle under `local_speech/`, then falls back to the source-tree path for development.

### Optional Cloudflare Worker

The Worker remains for legacy/fallback cloud routes:

- `POST /chat` proxies to Anthropic Messages API
- `POST /transcribe-token` fetches an AssemblyAI streaming token

If you use those routes:

```bash
cd worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler deploy
```

The default app path on this branch does not require those cloud keys.

## Permissions the app needs

- **Microphone** — push-to-talk voice capture
- **Accessibility** — global keyboard shortcut
- **Screen Recording** — screenshots for vision requests
- **Screen Content** — ScreenCaptureKit access

## Architecture

Menu bar-only macOS app with two `NSPanel` windows: one for the control panel dropdown and one for the transparent cursor overlay. Push-to-talk records audio through `AVAudioEngine`, transcribes locally with Whisper MLX, captures screenshots with ScreenCaptureKit, sends transcript + screenshots to a local OpenAI-compatible vision endpoint, streams text back into the cursor overlay, and speaks the response with local Kokoro TTS.

The vision model can embed `[POINT:x,y:label:screenN]` tags in responses. Clicky parses those tags and animates the blue cursor to the referenced screen coordinate.

## Project structure

```text
leanring-buddy/                 # Swift source; typo stays
  CompanionManager.swift        # Central state machine
  CompanionPanelView.swift      # Menu bar panel UI
  ClaudeAPI.swift               # Misnamed local OpenAI-compatible vision client
  LocalWhisperTranscriptionProvider.swift
  LocalTTSClient.swift          # Local Kokoro playback client
  OverlayWindow.swift           # Blue cursor overlay
  AssemblyAI*.swift             # Optional legacy/fallback transcription provider
  BuddyDictation*.swift         # Push-to-talk pipeline
local_speech/
  stt_server.py                 # Local Whisper MLX HTTP server
  tts_server.py                 # Local Kokoro HTTP server
worker/
  src/index.ts                  # Legacy/fallback Cloudflare routes
CLAUDE.md                       # Symlink to AGENTS.md
```

## Known cleanup work

- `ClaudeAPI.swift` should be renamed to a neutral vision-client name in a project-file-aware cleanup.
- Local vision server startup/healthcheck/recovery needs to be made explicit.
- `tts_server.py` still shells out for synthesis per request; keeping Kokoro warm in-process may reduce latency.

## Contributing

PRs welcome. If you're using an agent, point it at `CLAUDE.md` / `AGENTS.md` first.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
