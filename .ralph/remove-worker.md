# Remove Cloudflare Worker entirely — Done ✓

## Goal
Remove the Cloudflare Worker (`worker/` directory) and all references to it from the app code and docs.

## Context
The user has decided to remove all Cloudflare code. The app is fully local-first now.

## Done
- [x] Check app code for any live Worker URL usage — ClaudeAPI.swift uses local endpoint only, AssemblyAI was sole worker consumer
- [x] Remove worker/src/index.ts and worker/ directory — **deleted**
- [x] Remove or update ClaudeAPI.swift if it references worker URLs — was already using `127.0.0.1:8080`, no worker refs
- [x] Update AssemblyAI transcription provider — **deleted** (depended on worker for tokens)
- [x] Update AppBundleConfiguration.swift — no worker URL keys present
- [x] Update AGENTS.md — **done**
- [x] Update README.md — **done**
- [x] Final verification: no worker/cloudflare references remain in Swift or doc files

## Verification
- [x] No remaining references to the Cloudflare Worker
- [x] No broken imports or dangling config keys
- [x] App still builds conceptually (no xcodebuild run)
