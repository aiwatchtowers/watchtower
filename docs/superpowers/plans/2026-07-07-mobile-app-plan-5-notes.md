# Carry-over Notes for Plan 5 (BYOK Agent Fallback) — from Plan 4 Final Review

Binding inputs for whoever writes/executes Plan 5. Source: Plan 4 whole-branch review (branch `feature/mobile-app-plan-4`, 6b2f10c..HEAD). The Plan 3 wire contracts and Plan 4 design decisions (single relay consumer; overlay-not-mutation; Kit owns relay writes; flag-driven error styling) still bind.

## Seam readiness verdict (from the final review)

BYOK is architecturally ready with ONE known friction point:

1. **Local answer path**: synthesize `ChatChunkPayload`s and feed them through the public `ChatAssembler.ingest` against the placeholder row `send()` already creates — cut-at-done/idempotency machinery works unchanged for a local answerer.
2. **THE friction**: `ChatAssembler.send()` unconditionally saves the `ChatMessagePayload` to the relay zone and THROWS on transport failure. An offline BYOK turn needs either a flag on `send` (skip relay) or a second entry point. Parameter addition, not redesign — decide it in the plan, first task.
3. Composition: transport/store/outbox/assembler are all injected with `AppEnvironment` as the single composition point — the fallback path plugs in there (spec Section 3: `MobileAgentBackend` protocol with Relay/DirectAPI backends; the DirectAPI backend's read tools mirror the MCP v1 set over `ReplicaStore.fetchAll`).
4. When BYOK adds a second composer path into `ChatAssembler.send`, promote the empty-text guard from the UI into the Kit (`send` precondition) — ledgered as Plan 4 item 7.
5. `RelayFeed.isDesktopReachable` is a nonisolated synchronous SQLite read on MainActor TimelineView ticks — fine at one caller; cache it if Plan 5 multiplies callers.

## Hardening handed to Plan 5 / packaging

- **ReplicaStore split** (~900 lines, three concerns): extract `ReplicaStore+Chat.swift` / `+PendingActions.swift` extension files BEFORE Plan 5 adds BYOK chat paths; claws back god-file drift too.
- **Inbox sub-day snoozes are cosmetic today**: Go's `UnsnoozeExpiredInboxItems` compares a bare UTC date, so same-day timestamps unsnooze on the NEXT day's sweep. Parity with desktop; the real fix is the Go sweep granularity (documented at `SnoozeOption.inboxCases`).
- **Retry non-atomicity for task_create** (documented at `PendingOverlay.retry`): remove-first for `.taskCreate` if it ever matters.
- **Packaging-plan items** (from the ledger): demo relaunch drops all batches as stale (persisted replica_meta tokens + fresh in-memory transport) — user-visible symptom includes the Chat "Mac unreachable" banner on every demo relaunch; real-CloudKit poll cadence tuning (RelayFeed 5 s / hydrator 30 s); "⚠️ " prefix removal once a mobile version floor exists; snapshot/UI-test infra (menu-literal guards, Boot failed-arm); frozen-token growth mitigation (dead-relay liveness).
