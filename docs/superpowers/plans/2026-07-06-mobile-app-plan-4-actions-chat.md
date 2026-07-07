# Watchtower Mobile — Plan 4: Actions + Chat

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone can act: quick actions (done/resolve/dismiss/snooze/create) flow through the ActionRequest relay queue with optimistic UI, and a Chat tab streams desktop AI answers via chunk records. Plus the desktop/Kit debts carried from Plan 3.

**Architecture:** Kit gains the mobile relay side: `ActionOutbox` (enqueue + local pending state + silent-pending sweep), `RelayFeed` (the phone's SINGLE relay consumer — own token, routes action echoes / chat chunks / heartbeat), `ChatAssembler` (seq-ordered assembly, cut at first `done`, `isError` flag) with chat persistence in the replica DB. The app overlays pending-action state in view models (the replica itself is never mutated locally — hydration remains the only writer of `slice_records`) and adds the Chat tab. Desktop: relay `events` age sweep + `isError` emission + the hub UX batch. Everything is testable against `InMemoryCloudTransport`, including a full mobile↔desktop loop test (both sides share one transport in-process).

**Tech Stack:** Swift 5.10+, GRDB 7.x, SwiftUI, XCTest; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-05-mobile-app-design.md` (Sections 2–3)
**Binding carry-over:** `docs/superpowers/plans/2026-07-06-mobile-app-plan-4-notes.md` and the wire contracts in `2026-07-06-mobile-app-plan-3-notes.md` (chunk assembly cut-at-done, ≥45 s liveness, silent-pending rule, snooze date forms).

## Design decisions (resolve the notes — read before implementing)

1. **Error chunks get a real flag (notes §1 of Plan 3 / minor 7 of Plan 2 final).** `ChatChunkPayload` gains `isError: Bool?` — optional, `encodeIfPresent`, absent = false, so every frozen fixture stays byte-identical. The desktop error path sets `isError: true` (keeping the human-readable `"⚠️ "` prefix). Mobile renders errors by flag, never by prefix sniffing.
2. **Relay access shape (notes §2).** No raw transport exposure from `AppEnvironment`. The Kit owns both directions: `ActionOutbox` writes `.relay`, `RelayFeed` reads it. The app talks to those two types only.
3. **One relay consumer per device (Plan 2 Task 6 lesson).** `RelayFeed` holds the phone's single relay token (persisted in `replica_meta`, key `relay_change_token`) and fans records out in-process. Nothing else on the phone calls `changes(in: .relay, …)`.
4. **Optimistic UI = overlay, not replica mutation.** Pending actions live in their own table; view models join them over the slice models (strike-through/pending chip, hidden-when-dismissed, etc.). `slice_records` stays hydration-only — no local-write/hydration races by construction. `applied` echo clears the overlay; the authoritative row change arrives with the next slice hydration. `failed` echo (or the 24 h silent-pending sweep) reverts the overlay and surfaces the error.
5. **Liveness.** Heartbeat arrives through `RelayFeed`; unreachable = heartbeat older than 12 min (spec) — and chat additionally shows "waiting" until the first chunk, with the ≥45 s threshold from the Plan 3 notes before offering anything. The BYOK fallback itself is Plan 5 — the Chat unreachable-state shows a disabled stub.
6. **`orderedBy` becomes an enum NOW (notes §3)** — before Plan 4 multiplies fetchAll call sites. `Sendable` bound on the seam (notes §4) is explicitly deferred to a strict-concurrency pass — a protocol-inheritance change to the frozen seam needs its own owner decision.
7. **Sidecar tables for actions/chat live in the replica DB** (same `DatabasePool`, so ValueObservation drives the UI for pending overlays and chat threads exactly like the tabs).

## Global Constraints

- Worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/mobile-app`, branch `feature/mobile-app-plan-4` (STACKED on feature/mobile-app-plan-3 until PR #28 merges; rebase onto origin/mobile-app happens at PR time).
- Gates after every task: Kit suite (85 baseline) + desktop suite (953 + 92) + mobile `xcodebuild test` (5 baseline, iPhone 17 Pro sim) green; `swiftlint lint --strict` 0 in Kit, `--baseline` 0 in desktop; desktop `swift build` + `make mobile-build` clean. Use `make mobile-test` / `make mobile-run` (Makefile targets exist).
- Frozen wire formats: every existing RelayCoder fixture stays byte-identical (the `isError` field is optional/omitted-when-nil BY DESIGN — if a frozen fixture needs editing, the design is wrong; STOP).
- The `CloudSyncTransport` seam gains nothing. `InMemoryCloudTransport` behavior unchanged.
- No CloudKit entitlements, no notifications (owner decision 2026-07-06): foreground demo transport only; the real-push work is the packaging plan.
- Mobile UI copy in English. PR text in English. app-guide.md is desktop-only — no update needed for mobile tabs, but DO update it for the desktop Settings changes in Task 8.

---

### Task 1: `isError` chat-chunk flag — Kit payload + desktop emission

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Relay/ChatPayloads.swift`
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/RelayProcessor.swift` (error-path chunk)
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/RelayPayloadTests.swift`, `WatchtowerDesktop/Tests/MobileHub/RelayProcessorChatTests.swift`

**Interfaces:**
- `ChatChunkPayload` gains `public var isError: Bool?` (last property; explicit CodingKeys entry `isError = "is_error"` — mind the snake_case double-mapping trap documented in the file). Memberwise init gains `isError: Bool? = nil` as the LAST parameter — all existing call sites compile unchanged.
- New frozen fixture test: chunk with `isError: true` → JSON contains `"is_error":true`; chunk with nil → byte-identical to the EXISTING frozen fixture (assert against the same literal — proving wire compatibility).
- Desktop: the error/timeout final chunks in `RelayProcessor` set `isError: true` (both the stream-error path and the watchdog-timeout path). Extend the existing chat error test + timeout test to assert the flag.
- Round-trip: decoder tolerates records without the field (old desktop versions) → `isError == nil`.

**Steps:** TDD; suites; lint; commit `feat(kit,desktop): isError flag on chat chunks — errors signaled by wire field, not prefix`.

---

### Task 2: `ReplicaSort` enum replaces the `orderedBy` SQL-fragment param

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Replica/ReplicaStore.swift`
- Modify: app call sites (`WatchtowerMobile/Sources/**` view models), `PublicAPISurfaceTests.swift`, `ReplicaTests.swift`

**Interfaces:**
- `public enum ReplicaSort { case newestFirst, oldestFirst, recordName }` mapping internally to the three ORDER BY fragments; both `fetchAll` overloads take `sort: ReplicaSort = .newestFirst` instead of `orderedBy sql: String?`. The interpolated-SQL foot-gun is gone; the doc comment about trusted fragments is deleted.
- Grep proves no remaining `orderedBy` references anywhere.

**Steps:** compile-driven refactor + test updates; suites (incl. mobile); lint; commit `refactor(kit): ReplicaSort enum — no raw ORDER BY fragments in the replica API`.

---

### Task 3: `ActionOutbox` — enqueue, pending overlay state, silent-pending sweep

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Relay/ActionOutbox.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Replica/ReplicaStore.swift` (new tables + accessors)
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/ActionOutboxTests.swift`

**Interfaces:**
- `ReplicaStore` gains `pending_actions(action_id TEXT PRIMARY KEY, kind TEXT, entity_record_name TEXT, payload BLOB, created_at REAL, state TEXT CHECK(state IN ('pending','failed')), error_message TEXT)` + typed accessors: `pendingActions() throws -> [PendingAction]`, `pendingActions(forEntity recordName: String)`, insert/markFailed/remove. `public struct PendingAction: Equatable, Identifiable` mirrors the row (id = action_id, decoded `ActionRequestPayload` available).
- `public actor ActionOutbox`:
  - `init(transport: any CloudSyncTransport, store: ReplicaStore, now: @escaping @Sendable () -> Date = Date.init)`
  - `enqueue(kind: ActionKind, entityRecordName: String?, params: [String: JSONValue]) async throws -> String` — builds `ActionRequestPayload` (UUID id; `entityID` extracted from the entity recordName's numeric suffix where required), saves via `CloudRecordFactory.record(for:)` into `.relay`, inserts the pending row in the same flow (transport first; a transport throw leaves no phantom overlay).
  - `applyEcho(_ action: ActionRequestPayload)` — `applied` → remove pending row; `failed` → `state='failed'` + error_message. Called by `RelayFeed` (Task 4).
  - `sweepSilentPending(olderThan age: Duration = .seconds(86_400))` — pending rows older than 24 h → failed-locally with the standard message (Plan 3 notes: no echo possible for undecodable actions; user must learn). Returns swept ids.
- Snooze params use ISO8601 (`snooze_until`); the desktop accepts plain + fractional forms (pinned in Plan 2/3) — pin the producer side with one fixture test.
- Tests: enqueue → relay record visible via `transport.changes(in: .relay…)` with `status: pending` AND pending row present; transport-throw → no pending row; applied/failed echo behavior; sweep boundary (23 h stays, 25 h fails); ValueObservation on `pending_actions` fires (drives the overlay).

**Steps:** TDD; suites; lint; commit `feat(kit): ActionOutbox — relay action producer with pending overlay and silent-pending sweep`.

---

### Task 4: `RelayFeed` — the phone's relay consumer

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Relay/RelayFeed.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Replica/ReplicaStore.swift` (relay token accessors on `replica_meta`; heartbeat state)
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/RelayFeedTests.swift`

**Interfaces:**
- `public actor RelayFeed`:
  - `init(transport: any CloudSyncTransport, store: ReplicaStore, outbox: ActionOutbox, assembler: ChatAssembler? = nil, pull: (@Sendable () async throws -> Void)? = nil)` (assembler optional so Task 4 lands before Task 5; wired in Task 5).
  - `pollOnce() async throws -> (echoes: Int, chunks: Int)` — coalesced like `ReplicaHydrator` (same inFlight pattern — reentrancy lesson); reads `changes(in: .relay, since: store.relayToken())`; routes by kind: `action` records decoded → `outbox.applyEcho` ONLY when `status != .pending` (a pending record in the feed is our own enqueue echoing back — skip); `chat_chunk` → assembler; `heartbeat` → `store.setHeartbeat(updatedAt:)`; token persisted after the batch (monotonic guard mirrors the replica: stale batch → drop).
  - `start(interval: Duration = .seconds(5))` / `stop()` — chat needs snappier polling than the 30 s hydrator; 5 s against the in-process demo transport is free, and the comment must note the real-CloudKit tuning belongs to packaging.
  - Liveness read side: `ReplicaStore.heartbeatAge(now:) -> Duration?` + `public var isDesktopReachable: Bool` style helper (stale > 12 min → unreachable; nil = never seen).
- Tests: routing of all three kinds (+ unknown kind ignored + logged once); own-echo skip (status pending not routed); token advances + monotonic drop; heartbeat staleness math (fresh/stale/never); coalescing (gated-transport test, template in ReplicaTests).

**Steps:** TDD; suites; lint; commit `feat(kit): RelayFeed — single relay consumer routing echoes, chunks, heartbeat`.

---

### Task 5: `ChatAssembler` + chat persistence + outgoing messages

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Relay/ChatAssembler.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Replica/ReplicaStore.swift` (chat tables + accessors)
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/ChatAssemblerTests.swift`

**Interfaces:**
- `ReplicaStore` tables: `chat_sessions(session_id TEXT PRIMARY KEY, title TEXT, created_at REAL, updated_at REAL)`, `chat_messages(message_id TEXT PRIMARY KEY, session_id TEXT, role TEXT CHECK(role IN ('user','assistant')), text TEXT, is_error INTEGER NOT NULL DEFAULT 0, is_complete INTEGER NOT NULL DEFAULT 0, created_at REAL)` + typed accessors (`sessions()`, `messages(inSession:)`, upserts). ValueObservation-friendly (same pool).
- `public actor ChatAssembler`:
  - `init(transport: any CloudSyncTransport, store: ReplicaStore, now: …)`
  - `send(text: String, sessionID: String?) async throws -> (sessionID: String, messageID: String)` — creates the session row on first message (title = first words), persists the user message (`is_complete: 1`), saves `ChatMessagePayload` into `.relay`, creates the assistant placeholder row (`is_complete: 0`).
  - `ingest(_ chunk: ChatChunkPayload)` — **the Plan 3 notes contract, verbatim**: per messageID ordered by seq; text appends only for seq not yet applied (track `last_seq` per assistant message — add a column); at the FIRST `done: true` mark `is_complete: 1` (+ `is_error` from the flag) and IGNORE any further chunks for that messageID, including stale higher-seq leftovers from a redelivered shorter answer.
  - Waiting state helper for the UI: `firstChunkPending(messageID:) -> Bool` + the ≥45 s "unreachable?" threshold constant exported for the view model (`public static let unreachableAfter: Duration = .seconds(45)`).
- Tests: ordered assembly; out-of-order seq buffering or drop (define: chunks arrive in seq order from the feed since the buffer is seq-ordered — assert the contract with a shuffled ingest anyway, deciding buffer-vs-drop and documenting); cut-at-first-done incl. stale higher-seq ignored (the notes' redelivery scenario end-to-end); isError propagation; session/message persistence + observation fires; duplicate chunk idempotent.

**Steps:** TDD; suites; lint; commit `feat(kit): ChatAssembler — chunk assembly per the frozen relay contract, chat persistence`.

---

### Task 6: Actions in the app — swipe actions, pending overlay, create sheet

**Files:**
- Modify: `WatchtowerMobile/Sources/App/AppEnvironment.swift` (outbox/feed wiring), the Inbox/Tasks view models + views
- Create: `WatchtowerMobile/Sources/Features/CreateTargetSheet.swift` (minimal)
- Test: `WatchtowerMobile/Tests/ReplicaWiringTests.swift` (extend) or a new `ActionsWiringTests.swift`

**Interfaces:**
- `AppEnvironment` builds `ActionOutbox` + `RelayFeed` (+ assembler placeholder until Task 7 wires chat UI) over the SAME transport/store; feed started in bootstrap; sweep scheduled daily.
- Inbox rows: swipe actions Resolve / Dismiss / Snooze (menu: 1h, tonight, tomorrow — ISO8601 params); Tasks rows: Done + Snooze; toolbar + on Tasks → Create sheet (text field → `task_create`).
- Overlay semantics in view models: pending `target_done` → row shows strike-through + "pending" chip; pending inbox resolve/dismiss → row dims with chip; `failed` → row restores + error banner with the message + a Retry button (re-enqueue) and Dismiss (remove pending row). Driven by ValueObservation on `pending_actions` joined in the VM (no replica mutation — decision 4).
- App-target tests: enqueue-through-UI-action (call the VM method) → pending row + relay record; failed echo → overlay reverts (drive `applyEcho` directly); the demo transport makes these deterministic.

**Steps:** TDD where wiring is assertable; simulator suite + `make mobile-run` boot-check; lint; commit `feat(mobile): quick actions — relay queue with optimistic overlay`.

---

### Task 7: Chat tab

**Files:**
- Create: `WatchtowerMobile/Sources/Features/ChatView.swift` (+ view model)
- Modify: `WatchtowerMobile/Sources/App/*` (tab entry — replaces the Settings position? NO: add as 5th tab, Settings moves under a toolbar gear or stays 6th — pick TabView with 6 items max concern: 5 visible + Settings stays; document the choice), `AppEnvironment` (assembler wiring)
- Test: `WatchtowerMobile/Tests/` chat wiring tests

**Interfaces:**
- Sessions list (recent first, from `sessions()` observation) → thread view: messages bubble list (assistant `is_complete: 0` renders a typing indicator that updates as `ingest` appends — observation on `chat_messages`), `isError` messages styled as errors; composer sends via `assembler.send`.
- Liveness banner: heartbeat stale/never → "Mac unreachable — answers need your desktop online" + disabled "Answer directly (coming in Plan 5)" stub; first-chunk waiting > 45 s → same banner inline at the message.
- App-target test: send → user message + placeholder persisted + relay record exists; ingest a chunk sequence (incl. done) through the assembler → thread shows the assembled text (VM-level assertion, not pixel).

**Steps:** TDD on VM wiring; simulator suite + boot-check with a scripted demo answer (DemoSeed gains a canned chat echo IF cheap — else note); lint; commit `feat(mobile): chat tab — relay streaming over the assembler`.

---

### Task 8: Desktop debts — relay events age sweep + hub UX batch

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/CloudKitTransport/TransportStore.swift` (age-based event sweep primitive), `WatchtowerDesktop/Sources/Services/MobileHub/RelayProcessor.swift` (hygiene wiring), `MobileHubService.swift`, `AppState.swift`, `MobileSettings.swift`, `docs/app-guide.md`
- Test: respective test files

**Interfaces:**
- `TransportStore.sweepEvents(in zone: CloudZoneID, olderThan cutoff: Date) throws -> Int` — DELETE by `modified_at < cutoff` (age-based — CANNOT re-blind hygiene, per the final-review argument; doc comment cites it). `runHygieneIfDue` calls it for `.relay` with `now − chatMaxAge − 1 day` margin after the record hygiene pass. Test: an aged-beyond-window event disappears, a within-window one survives, hygiene still finds its aged records first (ordering pinned).
- Hub UX batch (Plan 2/3 ledger): периодический availability re-probe while `.unavailable` (e.g. every 10 min → auto-recover when iCloud returns); `makeMobileHub` failure → `HubStatus.unavailable(message)` surfaced in Settings instead of print; `MobileHubService` takes `isEnabled: @Sendable () -> Bool` (AppState injects the UserDefaults read; the service-level UserDefaults dependency dies); the epoch stop-during-start test (gated stub transport holding `start()` while `stop()` lands).
- os.Logger replaces the remaining `print()` in desktop hub paths if any (grep).
- app-guide.md: Mobile settings paragraph updated (re-probe behavior).

**Steps:** TDD; full desktop + Kit suites; lint; commit `fix(kit,desktop): relay event age sweep; hub availability re-probe, injected enablement, surfaced init failures`.

---

### Task 9: Mobile hardening batch (carried minors)

**Files:**
- Create: `WatchtowerMobile/Sources/Components/Badge.swift` (move `Badge` + `color(_:)`)
- Modify: `TasksView.swift` (priority badge colored by PRIORITY via a small shared mapping; `statusColor` "secondary" handled), `AppEnvironment.swift` (pool-open failure → degraded error state rendered by a minimal ErrorView instead of `fatalError`; os.Logger for `refresh`/observer errors), `ReplicaObserver.swift`/`SettingsViewModel.swift` (Logger), `SlicePublisher.swift` (one-line residual-race comment — desktop)
- Test: mobile suite additions where behavior changed (AppEnvironment degraded-state test with an unwritable path)

**Steps:** mechanical + TDD for the degraded state; simulator suite; lint; commit `chore(mobile): components home for badges, correct priority colors, logger, degraded boot state`.

---

### Task 10: Full-loop integration tests (mobile ↔ desktop over one transport)

**Files:**
- Create: `WatchtowerDesktop/Tests/MobileHub/FullLoopTests.swift`

**Interfaces:**
- The desktop test target has everything: RelayProcessor + MockClaudeService + TestDatabase (desktop side), and the Kit's ActionOutbox/RelayFeed/ChatAssembler/ReplicaStore (mobile side) — wired over ONE `InMemoryCloudTransport`:
  1. **Action loop:** outbox.enqueue(inbox_resolve) → RelayProcessor.processOnce applies to the fixture DB + writes the applied echo → RelayFeed.pollOnce routes it → pending row cleared. Assert DB state AND overlay state.
  2. **Failed loop:** enqueue for a nonexistent id → processOnce writes failed → feed → pending row `state='failed'` with the desktop's errorMessage.
  3. **Chat loop:** assembler.send → processOnce (MockClaudeService streams a scripted answer) → chunks land → feed.pollOnce → assembler.ingest → `chat_messages` row complete with the full text; error variant asserts `is_error` (Task 1's flag) arrives end-to-end.
- These are THE gate for the whole feature: the two halves built against the same frozen contracts must actually interlock.

**Steps:** TDD (they'll fail until wired correctly); full suites everywhere; lint; commit `test(desktop,kit): full mobile↔desktop relay loop over one transport`.

---

## Out of scope for Plan 4 (explicit)

- Notifications (owner decision — packaging plan, where push-wake exists).
- BYOK fallback / direct Anthropic API (Plan 5); the Chat unreachable stub only.
- Real CloudKit on device, entitlements, TestFlight (packaging plan).
- `Sendable` bound on the frozen seam (strict-concurrency pass, owner decision required).
- `RunningSummary.Meta` publicizing (still unreferenced by mobile).
