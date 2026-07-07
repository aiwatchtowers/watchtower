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

## Shipped in Plan 5 (delta for the packaging plan)

Plan 5 landed the full BYOK fallback on `feature/mobile-app-plan-5`: `ChatAssembler.send` route (`.localOnly`) + empty-text guard, `AnthropicClient` (URLSession SSE, frozen request bytes), `ReplicaToolbox` (12-tool MCP v1 mirror incl. `create_task`/`snooze_item` through ActionOutbox), `DirectAPIAgent` behind `MobileAgentBackend` (serialized per-session answers, snapshot-at-send history normalized for API alternation, every failure completes the placeholder as an error), `APIKeyStore` + Settings section, per-conversation `direct_mode` opt-in UX, and `DirectLoopTests` as the offline full-loop gate. The relay path is byte-identical to Plan 4 (pinned in `DirectLoopTests.testRelayBackendStillShipsFrozenPlan4WireRecord`).

Carry-overs for the packaging plan:

- **Dev-sim key volatility — fix next to entitlements** (T6 ledger): under `CODE_SIGNING_ALLOWED=NO` the simulator Keychain fails with `errSecMissingEntitlement` and the DEBUG in-memory fallback holds the key, so it evaporates on relaunch in dev sims. Resolves itself when packaging provisions real signing + Keychain entitlements; verify then and delete the fallback if possible.
- **Direct-flavored waiting hint** (T7 ledger): the past-45 s "still thinking" hint copy is relay-flavored ("is your Mac on?"); a direct-mode turn should get its own copy (the Mac is irrelevant mid-answer there).
- **Per-row direct badge** (T7 ledger): the sessions list does not mark which conversations are `direct_mode = 1`; only the open thread shows the chip.
- **Bounded rebuild-at-answer-time** (T5 ledger): history is snapshotted at `sendTurn`, so a queued turn answers from the thread as it stood when sent. If queued-turn answer quality ever matters, add a bounded rebuild at answer time (same normalization) instead of widening the snapshot.
- **Real-API smoke test once a key is provisioned**: every Plan 5 test scripts the network (fake client or URLProtocol). When a real `sk-ant-…` key exists in the team, run one manual live smoke (direct turn incl. one tool round against api.anthropic.com) before shipping — the wire freeze in AnthropicClientTests is the contract, but it has never met the real server.
- **From the final review**: empty/refusal turns (sonnet 5 safety classifiers can return `stop_reason: "refusal"` with zero text) currently complete as a silent empty bubble — substitute readable copy in `completeTurn` when `seq == 0 && buffer.isEmpty` (same UX family as the direct waiting hint). Tool errors ship as `{"error":…}` content without `is_error: true` on the tool_result — add the field only if the live smoke shows retry-looping. The live-API smoke is a MUST-DO checklist item before user-facing ship (the wire freeze has never met the real server). ReplicaToolbox (775 lines) is the top god-file contributor — split `+Definitions` if it grows again.
