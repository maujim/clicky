# Ralph Loop: Bundle Local Speech Scripts

## Goal

Make `local_speech/stt_server.py` and `local_speech/tts_server.py` work from a built `.app`, not only from the source tree.

## Context

`AppBundleConfiguration.localSpeechScriptURL()` now prefers bundled resources under `local_speech/` and falls back to the source tree for development. The Xcode project may still need Copy Bundle Resources entries for those Python scripts.

## Constraints

- Do **not** run terminal `xcodebuild`.
- Be careful editing `project.pbxproj`; keep changes minimal and inspect existing resource patterns first.
- Do not rename the Xcode project or scheme.

## Tasks

- [ ] Inspect `leanring-buddy.xcodeproj/project.pbxproj` for existing resource build phase patterns.
- [ ] Add `local_speech/stt_server.py` and `local_speech/tts_server.py` to the app bundle resources under a `local_speech` subdirectory if possible.
- [ ] If folder references are safer than individual files for this project, use the smallest safe project-file change.
- [ ] Confirm `AppBundleConfiguration.localSpeechScriptURL()` resource lookup path matches how Xcode will bundle the files.
- [ ] Update `README.md` / `AGENTS.md` only if the packaging behavior changes.

## Verification

- [ ] Open Xcode and confirm the scripts are listed in Copy Bundle Resources or equivalent.
- [ ] Build/run from Xcode only.
- [ ] Confirm logs show local speech scripts found from bundle or source-tree fallback.

## Suggested Commit Message

`Bundle local speech helper scripts`
