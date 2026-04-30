# Ralph Loop: Decide Cloudflare Worker Fallback Role

## Goal

Make the Cloudflare Worker role explicit: keep it as supported fallback, remove unused routes, or wire it into a selectable mode.

## Context

Current default app path is local-first. `worker/src/index.ts` still exposes:

- `/chat` → Anthropic Messages API
- `/transcribe-token` → AssemblyAI token

Docs now call these legacy/fallback routes, but the product decision is still open.

## Constraints

- Do **not** remove fallback code unless the user/product decision is clear.
- Do **not** break AssemblyAI provider if it is intentionally kept as optional.
- Do **not** run terminal `xcodebuild`.

## Decision Options

1. Keep Worker as documented fallback only.
2. Remove `/chat` if Claude fallback is no longer wanted.
3. Add explicit app setting/config for local vision vs Claude Worker fallback.
4. Remove Worker entirely if all cloud fallback is dead.

## Tasks

- [ ] Inspect current app code for any live Worker `/chat` usage.
- [ ] Inspect current app code for AssemblyAI `/transcribe-token` usage.
- [ ] Pick one decision option with user confirmation if needed.
- [ ] Apply the smallest code/docs changes for that decision.
- [ ] Update `README.md`, `AGENTS.md`, and `worker/src/index.ts` comments accordingly.

## Verification

- [ ] Search docs and code for contradictions about Worker/default path.
- [ ] If removing routes, ensure Worker TypeScript still typechecks/deploys via Wrangler when user chooses to test it.

## Suggested Commit Message

`Clarify Cloudflare fallback role`
