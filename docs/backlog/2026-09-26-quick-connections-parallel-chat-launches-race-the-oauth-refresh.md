---
type: bug
title: "Quick Connections: parallel chat launches race the OAuth refresh-token rotation, and any refresh error is recorded as \"revoked\""
status: open
priority: med
tags: [quick-connections, oauth, concurrency, qc-04, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** cmd/generator.go:171-260, internal/mcpoauth/refresh.go:25-62
**Confidence:** med

Every chat launch (`ai query --tools chat`) is its own process running `loadExternalMCPServers` → `EnsureFresh` → `store.Save`, with no lock. A grant with unknown expiry is refreshed on every launch (by design), and an expiring grant is refreshed by whichever launch comes first. Two chats started together (main plus target chat, or a retry) both refresh with the same refresh token:
- With a rotating-token server, the loser gets `invalid_grant`.
- With reuse detection (common in OAuth servers), the whole token family can be revoked.

`applyOAuthCredentials` also stamps `status='revoked'` for any `EnsureFresh` error, including a timeout or 5xx, so a network blip reads as "Sign in again". Fix: take a per-connection flock around load/refresh/save and re-read the grant after acquiring it. Record `revoked` only for `invalid_grant`/`ErrInvalidGrant` and leave transient errors as "error". This changes how QC-04's "visible" state is reported, but not the contract's intent.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
