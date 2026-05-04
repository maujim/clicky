Update: April 30, 2026.

Hi there! I'm Farza, the guy that made Clicky.

The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private. To get the latest Clicky, you can go [here](https://www.heyclicky.com/).

Go crazy with this repo!! It's an MIT license.

# Hi, this is Clicky.

It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and point at stuff. Kinda like having a real teacher next to you.

This branch is local-model focused: local vision, local Argmax WhisperKit speech-to-text, and local Argmax TTSKit text-to-speech.

## Manual setup

### Prerequisites

- macOS 15+ for Argmax TTSKit
- Xcode 16+
- A local vision model server (run `./run-llama-server.sh`) listening at `http://127.0.0.1:8080/v1/chat/completions`

### Vision model server

```bash
./run-llama-server.sh
```

This starts `llama-server` with the **Liquid VL 450M** model (F32) by default. The 1.6B BF16 model is available via `CLICKY_VISION_MODEL_SIZE=1.6B` but requires more GPU memory and may crash on Apple Silicon with limited unified memory.

Environment overrides:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLICKY_VISION_MODEL_SIZE` | `450M` | `450M` or `1.6B` |
| `CLICKY_VISION_HOST` | `127.0.0.1` | Server bind address |
| `CLICKY_VISION_PORT` | `8080` | Server port |
| `CLICKY_VISION_CTX_SIZE` | `4096` | Context window size |
| `CLICKY_VISION_GPU_LAYERS` | `99` | GPU layer count |

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

### Local speech

STT and TTS run in-process through Argmax's Swift package:

- `WhisperKit()` handles local transcription with Argmax defaults.
- `TTSKit()` handles local speech playback with Argmax defaults.

Models are downloaded and cached by Argmax on first use.

### Troubleshooting

**Vision model crashes with "Insufficient Memory" / "command buffer failed"**
→ Stick with the 450M model (default). The 1.6B BF16 model easily exhausts Metal memory on M-series Macs during screenshot processing.

## Permissions the app needs

- **Microphone** — push-to-talk voice capture
- **Accessibility** — global keyboard shortcut
- **Screen Recording** — screenshots for vision requests
- **Screen Content** — ScreenCaptureKit access

## Architecture

Menu bar-only macOS app with two `NSPanel` windows: one for the control panel dropdown and one for the transparent cursor overlay. Push-to-talk records audio through `AVAudioEngine`, transcribes locally with Argmax WhisperKit, captures screenshots with ScreenCaptureKit, sends transcript + screenshots to a local OpenAI-compatible vision endpoint, streams text back into the cursor overlay, and speaks the response with Argmax TTSKit.

The vision model can embed `[POINT:x,y:label:screenN]` tags in responses. Clicky parses those tags and animates the blue cursor to the referenced screen coordinate.

### Key design decisions

- **Argmax speech stack** — STT and TTS run directly in Swift through WhisperKit/TTSKit instead of helper Python HTTP servers.
- **450M default vision model** — the 1.6B BF16 model causes Metal OOM on many M-series Macs when processing screenshot images, dropping the HTTP connection and crashing llama-server.

## Project structure

```text
leanring-buddy/                 # Swift source; typo stays
  CompanionManager.swift        # Central state machine
  CompanionPanelView.swift      # Menu bar panel UI
  VLMClient.swift               # Local OpenAI-compatible vision client
  LocalWhisperTranscriptionProvider.swift # Local Argmax WhisperKit STT
  LocalTTSClient.swift          # Local Argmax TTSKit playback
  OverlayWindow.swift           # Blue cursor overlay
  BuddyDictation*.swift         # Push-to-talk pipeline
  AppBundleConfiguration.swift  # Bundle config helper
  MenuBarPanelManager.swift     # NSStatusItem + NSPanel lifecycle
  GlobalPushToTalkShortcutMonitor.swift
run-llama-server.sh             # Convenience launcher for llama.cpp vision server
CLAUDE.md                       # Symlink to AGENTS.md
```

## Contributing

PRs welcome. If you're using an agent, point it at `CLAUDE.md` / `AGENTS.md` first.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
