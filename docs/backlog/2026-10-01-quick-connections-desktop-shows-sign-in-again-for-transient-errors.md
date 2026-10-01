---
type: bug
title: "Quick Connections: Settings shows \"Sign in again\" for a transient refresh error"
status: done
priority: low
tags: [quick-connections, oauth, desktop, qc-04]
context: split out of docs/backlog/2026-09-26-quick-connections-parallel-chat-launches-race-the-oauth-refresh.md (fix/ai-process-security, 2026-10-01)
created: 2026-10-01
---

**Where:** WatchtowerDesktop/Sources/Views/Settings/QuickConnectionsDetail.swift (the status dot + "Sign in again" button), WatchtowerDesktop/Sources/WatchtowerCore/Models/ExternalConnection.swift (`isOK`)

Since 2026-10-01 the chat launch records `status='revoked'` only when a new sign-in is the fix and `status='error'` for a transient refresh failure (network, 5xx, another process holding the token lock), which the next successful launch flips back to `ok`. The Desktop card still keys only on `isOK`: any non-`ok` row gets the red dot and a "Sign in again" button, so a network blip still reads as "sign in again". Fix direction: add `isRevoked` to `ExternalConnection`, show "Sign in again" only for `revoked`, render `error` neutral/amber with a "temporary — retried on the next chat" tooltip, and pin both states in a WatchtowerCore test.

Resolved 2026-10-01 (fix/qc-tool-allowlist): `ExternalConnection.needsSignIn` (status `revoked` only) gates the card's "Sign in again" button; an `error` row shows an orange dot with its reason as the tooltip, `revoked` stays red. Pinned by `ExternalConnectionTests.testNeedsSignIn_OnlyForRevoked`.
