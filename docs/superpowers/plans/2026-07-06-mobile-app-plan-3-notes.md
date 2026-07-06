# Carry-over Notes for Plan 3 (iOS Skeleton + Replica) — from Plan 2 Final Review

Binding inputs for whoever writes/executes Plan 3. Source: Plan 2 whole-branch review (branch `feature/mobile-app-plan-2`, 7be34b7..HEAD).

## Wire contracts the mobile consumer MUST honor

1. **Chunk assembly contract.** Assemble chat chunks per `messageID` ordered by `seq`; **cut at the first `done: true`** and ignore any stale higher-seq chunks (a crash-window redelivery can re-stream a shorter answer, leaving orphaned `done: false` records above the new `done`). Error chunks are currently signaled only by the `"⚠️ "` text prefix — decide in Plan 3 whether to add an optional backward-compatible `isError` field to `ChatChunkPayload` BEFORE mobile hard-codes prefix sniffing.
2. **Liveness math.** The spec's "no first chunk within 20 s → offer fallback" is too tight for the shipped desktop cadence: relay idle poll is 30 s (drops to 3 s only after activity), so first-chunk latency for a fresh conversation is 30 s poll + stream start + CK propagation. Until push entitlements land, mobile's unreachable threshold must be **≥ ~45 s** (heartbeat staleness stays the primary signal).
3. **Snooze dates**: send ISO8601; both plain and fractional-seconds forms are accepted by the desktop parser (fixed in Plan 2 final wave). Undecodable/unknown-id actions come back `failed` with `errorMessage`.
4. **Undecodable action = silent pending.** If mobile ships a payload the desktop cannot decode, no `failed` echo is possible (no addressable id) — the record stays `pending` forever on mobile. Producer-side rule: treat "no echo within X (suggest 24 h)" as failed locally.

## CloudKit transport production-readiness — HARD GATE before any real-device integration

One coherent work item on `CloudKitTransport`/`TransportStore`, first task of real-device Plan 3 work:

- **`.serverRecordChanged` conflict handling** (production-fatal): desktop status write-backs target mobile-created recordNames and heartbeat re-saves its own record; fresh `CKRecord`s without server change tags will hit `.serverRecordChanged` on essentially every such save, and the current behavior is a slow resend loop. Persist/reuse CK system fields (encodeSystemFields) or resolve conflicts in the delegate.
- **`.accountChange` reset**: engine state + events buffer + pending must be wiped on iCloud sign-out/switch; currently swallowed by `default: break`.
- **Unmappable-zone pending rows**: evict-and-log instead of silent skip in `pendingBatch`.
- **`relay_processed` + `events` retention**: both grow unboundedly; add sweeps mirroring the hygiene windows (events compaction owner note is already on the table's doc comment).
- **Read-your-writes caveat**: `changes()` visibility of a device's own saves is transport-dependent (immediate in the fake, delayed until engine re-fetch in CK) — desktop hygiene of self-authored records is best-effort; mobile must not assume immediate echo visibility either.

## Smaller items assigned to Plan 3

- `SliceDiff`/`SlicePublisher`: NULL/blob id → `"0"` recordName collision fallback — skip the row into `skipped` instead.
- `taskCreate` crash-replay non-idempotency — harden via `sourceType: "mobile"` + `sourceID: action.id` dedupe pre-check (schema-adjacent decision).
- `MobileHubService`: periodic availability re-probe (`.unavailable` currently sticky until toggle cycle); surface `makeMobileHub` init failure into `HubStatus.unavailable` (now print-only); epoch stop-during-start path needs its own test; remove the service-level UserDefaults read via injected `isEnabled` closure.
- `TransportStore`: tighten over-public adapter internals (`bufferChanged`/`bufferDeleted`/`pendingBatch`/`clearPending`) to `internal` before mobile consumes the Kit API.
- `RunningSummary.Meta` members are internal — publicize when the iOS app reads `.meta` (carried from Plan 1).
- Kit tests: add one file with plain `import WatchtowerKit` (no `@testable`) to compile-check the public surface as the iOS app will consume it (carried from Plan 1).

## PR-description notes (English)

- Sidecar paths deviate from the plan's Global Constraints: shipped `Application Support/Watchtower/MobileHub/transport.db` + `hubstate.db` (not `Watchtower/cloudkit-transport.sqlite` + `mobile-hub.sqlite`). Align or accept before first release persists state.
- Owner-approved semantics change (option A, 2026-07-06): date-only due dates use the user's LOCAL calendar day uniformly (model predicates, SQL counters, guard suites) — plus two pre-existing near-midnight bug fixes (dueToday `T24` boundary; local-day guard-suite alignment).
