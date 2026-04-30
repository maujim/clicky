# Ralph Loop: Rename Misnamed Claude Vision Client

## Goal

Finish the local-vision naming cleanup by renaming `ClaudeAPI.swift` / `ClaudeAPI` to a neutral name.

## Context

The implementation now sends OpenAI-compatible chat-completions requests to the local vision endpoint. Comments were updated, but the type/file are still named `ClaudeAPI` to avoid project-file churn in the previous pass.

## Constraints

- Do **not** run terminal `xcodebuild`.
- This loop touches Xcode project file references, so inspect before editing.
- Preserve behavior exactly.
- Keep old UserDefaults fallback for `selectedClaudeModel` unless deliberately migrating/removing it.

## Recommended Names

- File: `VisionChatClient.swift`
- Type: `VisionChatClient`
- Property: `visionChatClient` already exists in `CompanionManager.swift`

## Tasks

- [ ] Rename `leanring-buddy/ClaudeAPI.swift` to `leanring-buddy/VisionChatClient.swift`.
- [ ] Rename `class ClaudeAPI` to `class VisionChatClient`.
- [ ] Update all Swift references.
- [ ] Update `project.pbxproj` file references/build file entries.
- [ ] Update `AGENTS.md` and `README.md` project structure/key files.
- [ ] Search for stale `ClaudeAPI` references.

## Verification

- [ ] `rg "ClaudeAPI"` should return no active source/doc references except archived review notes if intentionally kept.
- [ ] Open in Xcode and verify the renamed file appears in the target.
- [ ] Build/run from Xcode only.

## Suggested Commit Message

`Rename local vision chat client`
