# Session Chat on the iPhone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone shows a workbench session's chat (and its subagents' chats) through the Mac hub, published only while the phone has that chat open.

**Architecture:** The phone enqueues a `session_chat_request` relay action while its Chat screen is open. The Mac's `SessionChatRunner` watches the requested session for 5 minutes, runs `watchtower workbench session-feed --json`, clips the result into a wire payload and keeps it in memory. `SessionChatSlice` publishes the payloads on the normal 30 s tick, and a watch that expires drops its record from the zone.

**Tech Stack:** Swift (WatchtowerDesktop hub, WatchtowerKit, WatchtowerMobile SwiftUI), the existing Go CLI unchanged.

**Spec:** `docs/superpowers/specs/2026-10-18-session-chat-iphone-design.md` (owner approved, ask #379). Parent: `docs/superpowers/specs/2026-10-16-session-chat-feed-design.md`.

## Global Constraints

- Wire rawValues (never renamed): slice kind `session_chat`, action kind `session_chat_request`.
- Record names: `session_chat-<session_id>` (main feed), `session_chat-<session_id>-<agent_id>` (a subagent).
- Watch length 5 min from the last request; phone repeats the request every 60 s while the screen is open.
- Runner: a live session every 10 s, a finished one once per watch; CLI timeout 30 s.
- Caps: newest 300 entries, entry `text` 4000 characters, `title` and subagent `description` 200, payload 600 000 bytes after clipping (drop oldest entries, add them to `entries_more`).
- Wire keys (snake_case, Unix-second dates): `session_id`, `agent_id`, `updated_at`, `live`, `entries_more`, `entries[]` {`id`, `kind`, `at`, `text`, `text_clipped`, `ask_id`, `title`, `via`, `subagent` {`agent_id`, `type`, `description`, `status`}}.
- `session_chat` is not an urgent kind (not in `SlicePublisher.urgentKinds`, not in the fast lane).
- Copy: "Chat" row; "Asking your Mac…"; "Your Mac has not sent this chat yet. Is it awake?"; "N earlier messages — open on the Mac"; "via Watchtower".
- Fixtures use placeholders only (I-9). Every Swift task runs `make lint-swift` (lint-diff is Go-only).
- **Ruling (deviation from the spec text):** the runner keeps payloads **in memory**, not in the hub sidecar. A watch does not survive a restart anyway (5 min), and nothing transcript-derived lands on disk on the Mac (FEED-01 spirit). Task 5 updates the spec line.

## Review Focus

1. A session the phone never opened → no `session_chat` record ever (Task 3 test `testNoWatchPublishesNothing`).
2. The phone closes Chat → the record disappears after 5 min, not kept forever (Task 3 `testExpiredWatchLeavesWindow`).
3. A huge transcript (many long entries) → the record still fits under 600 KB and shows `entries_more` (Task 2 `testTrimsToByteBudget`).
4. The CLI fails or times out (session deleted, transcript gone) → the last payload stays, error logged, no crash loop (Task 3 `testFetchFailureKeepsLastPayload`).
5. A phone not allowed to type → no Tell bar on the chat screen (Task 4 `testTellBarHiddenWithoutTypingGrant`).

---

### Task 1: Kit wire types

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Sync/SliceRecord.swift` (add `case sessionChat = "session_chat"`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionRequestPayload.swift` (add `case sessionChatRequest = "session_chat_request"`, idempotent — not in the Mac's `nonIdempotentKinds`)
- Create: `WatchtowerKit/Sources/WatchtowerKit/Models/SessionChat.swift`
- Create: `WatchtowerKit/Tests/Fixtures/workbench/session_chat.json` (main feed: one entry of every kind, one clipped text, `entries_more` 12) and `session_chat_subagent.json` (with `agent_id`)
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/WorkbenchMirrorFixtureTests.swift`, `WatchtowerKit/Tests/WatchtowerSyncTests/SliceKindTests.swift`, `RelayPayloadTests`

**Interfaces:**
- Produces: `public struct SessionChat: SliceMirror` { `sessionID: Int64`, `agentID: String?`, `updatedAt: Date`, `live: Bool`, `entriesMore: Int`, `entries: [Entry]` }; `public struct Entry: Hashable, Sendable, Decodable, Identifiable` { `id: String`, `kind: OpenWireValue<Kind>`, `at: Date?`, `text: String`, `textClipped: Bool`, `askID: Int64?`, `title: String?`, `via: String?`, `subagent: Subagent?` }; `public enum Kind: String { owner, agent, askAnswer = "ask_answer", watchtower, brief, subagent, separator }`; `public struct Subagent` { `agentID: String`, `type: String`, `description: String`, `status: String }`; `static func recordName(sessionID: Int64, agentID: String?) -> String`.

- [ ] **Step 1:** Tests: `SliceKindTests` lists `session_chat`; `RelayPayloadTests` round-trips `session_chat_request` with params `{session_id, subagent_id}`; `WorkbenchMirrorFixtureTests.testSessionChatFixtureDecodes` decodes both fixtures (every `Kind` known, `textClipped` true on the clipped entry, `entriesMore == 12`, subagent fixture `agentID != nil`) and `testSessionChatRecordName` (`session_chat-7`, `session_chat-7-a1b2`).
- [ ] **Step 2:** Run `make kit-test FILTER='SliceKindTests|RelayPayloadTests|WorkbenchMirrorFixtureTests'` → FAIL.
- [ ] **Step 3:** Implement the enum cases and the mirror (decode with `RelayCoder` rules, unknown keys ignored, unknown kind kept as an open value).
- [ ] **Step 4:** Same command → PASS; `make lint-swift`.
- [ ] **Step 5:** Commit `feat(kit): session_chat slice and session_chat_request action (#486)`.

### Task 2: Mac payload mapping and caps

**Depends on:** Task 1

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/SessionChatPayload.swift`
- Test: `WatchtowerDesktop/Tests/MobileHub/SessionChatPayloadTests.swift`

**Interfaces:**
- Consumes: `SessionFeedPayload` / `SessionFeedEntry` (WatchtowerCore, decodes the CLI JSON), `SliceClip.text(_:limit:)`, `RelayCoder.makeEncoder()`.
- Produces: `enum SessionChatPayload { static func encode(_ feed: SessionFeedPayload, sessionID: Int64, agentID: String?, live: Bool, now: Date) throws -> Data }` with `static let maxEntries = 300, maxText = 4000, maxLabel = 200, maxBytes = 600_000`.

- [ ] **Step 1:** Tests: `testKeepsNewest300` (350 entries → 300 newest, `entries_more == 50`), `testClipsText` (5000-char text → 4000 + `text_clipped: true`), `testClipsLabels`, `testTrimsToByteBudget` (300 entries of 4000 chars → encoded ≤ 600 000, oldest dropped, `entries_more` counts them), `testMatchesKitFixtureKeys` (`SliceJSON.kitFixture("workbench/session_chat.json")` keys == encoded keys), `testDatesAreUnixSeconds`.
- [ ] **Step 2:** `make test-swift FILTER=SessionChatPayloadTests` → FAIL.
- [ ] **Step 3:** Implement: tail first, then clip, then drop oldest until it fits (binary search not needed; drop in chunks of 10 is fine).
- [ ] **Step 4:** PASS; `make lint-swift`.
- [ ] **Step 5:** Commit `feat(hub): session chat payload with caps (#486)`.

### Task 3: Runner, slice, request handler, wiring

**Depends on:** Task 2

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/SessionChatRunner.swift`, `Slices/SessionChatSlice.swift`, `Handlers/SessionChatRequestHandler.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState+MobileHub.swift` (build the runner next to `SessionReportRunner` when the CLI exists, register the handler, add the slice to `sources`, start/stop it as a `HubCompanion`)
- Test: `WatchtowerDesktop/Tests/MobileHub/SessionChatRunnerTests.swift`, `SessionChatSliceTests.swift`, `SessionChatRequestHandlerTests.swift`

**Interfaces:**
- Consumes: Task 2's `SessionChatPayload.encode`; `CLIRunnerProtocol.run(args:)`; the `liveness()` source `TerminalSessionSlice` uses.
- Produces:
  - `final class SessionChatRunner: HubCompanion, Sendable` with `struct Timing { every: Duration = 10 s, watch: Duration = 5 min, timeout: Duration = 30 s, wake: Duration = 2 s }`, `typealias Fetch = @Sendable (_ sessionID: Int64, _ agentID: String?) async throws -> SessionFeedPayload`, `typealias IsLive = @Sendable (Int64) -> Bool`, `func request(sessionID: Int64, agentID: String?)`, `func payloads() -> [String: Data]` (keyed by record name, only unexpired watches), `static func arguments(sessionID:agentID:) -> [String]` = `["workbench","session-feed","--session",N,"--json"]` plus `["--subagent", id]`.
  - `struct SessionChatSlice: SliceSource` (kind `.sessionChat`, records from `runner.payloads()`).
  - `SessionChatRequestHandler(runner:).register(on:)` — validates `session_id` (a workbench agent session in the published window, else `.failed("unknown_session")`), calls `request`, returns `.applied()`; no grant check.

- [ ] **Step 1:** Tests with an injected clock and fake fetch:
  - `testNoWatchPublishesNothing` (slice records empty with no request);
  - `testRequestRunsAndPublishes` (one request → one fetch → one record named `session_chat-7`);
  - `testLiveSessionRefreshesEvery10s`, `testFinishedSessionRunsOncePerWatch`;
  - `testExpiredWatchLeavesWindow` (5 min + 1 s after the last request → `payloads()` empty, memory freed);
  - `testRepeatRequestExtendsWatch`;
  - `testSubagentWatchIsSeparate` (`session_chat-7-a1b2`, `--subagent a1b2` in args);
  - `testFetchFailureKeepsLastPayload` (error logged, payload unchanged, next run still scheduled);
  - `testTimeoutBoundsRun` (fetch longer than 30 s is cancelled);
  - `testStopDropsEverything`;
  - `testNotUrgent` (`!SlicePublisher.urgentKinds.contains(.sessionChat)`);
  - handler: `testUnknownSessionFails`, `testValidRequestApplies` (no typing grant needed).
- [ ] **Step 2:** `make test-swift FILTER='SessionChatRunnerTests|SessionChatSliceTests|SessionChatRequestHandlerTests'` → FAIL.
- [ ] **Step 3:** Implement following `SessionReportRunner`'s shape (one loop task, generation counter, `OSAllocatedUnfairLock` state, off-main CLI). Wire in `AppState+MobileHub.swift`.
- [ ] **Step 4:** PASS, plus `make test-swift FILTER='SlicePublisherTests|MobileHubServiceTests'`; `make lint-swift`.
- [ ] **Step 5:** Commit `feat(hub): publish a session's chat while the phone asks for it (#486)`.

### Task 4: Phone chat screen

**Depends on:** Task 1 (and Task 3 only for an end-to-end check)

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Workbench/SessionChatView.swift`, `SessionChatViewModel.swift` (with `SessionChatRequester`)
- Modify: `SessionDetailView.swift` (a **Chat** row above the report card → `SessionChatRoute`; make `TellSessionBar` reusable — move it to its own file `TellSessionBar.swift`), the four `navigationDestination` sites (`WorkbenchListView.swift`, `WorkbenchView.swift`, `BoardTargetDetailView.swift`, `Features/Now/NowView.swift`) for `SessionChatRoute`, `WatchtowerMobile/Sources/App/DemoSeed+SessionDetail.swift` (seed a chat for the demo session)
- Test: `WatchtowerMobile/Tests/SessionChatWiringTests.swift`, `ReplicaWiringTests` `seededCounts`

**Interfaces:**
- Consumes: Task 1's `SessionChat`, `SessionChat.recordName`, `ActionKind.sessionChatRequest`, `ActionOutbox.enqueue`.
- Produces: `struct SessionChatRoute: Hashable { sessionID: Int64; agentID: String? }`; `final class SessionChatRequester` (`func start(sessionID:agentID:)`, `func stop()`, repeats every 60 s, injectable clock); `SessionChatViewModel(sessionID:agentID:store:requester:)` exposing `chat: SessionChat?`, `waitingTooLong: Bool` (60 s with no record).

- [ ] **Step 1:** Tests: `testRequestsOnAppearAndEvery60s`, `testStopsOnDisappear`, `testShowsAskingThenWaitingTooLong`, `testSubagentRowPushesSubagentRoute`, `testEarlierMessagesLine` ("12 earlier messages — open on the Mac"), `testTellBarHiddenWithoutTypingGrant`, `testTellBarShownWithTypingGrant`.
- [ ] **Step 2:** `make mobile-test MOBILE_FILTER=SessionChatWiringTests` → FAIL.
- [ ] **Step 3:** Implement the view after the Mac mockup (owner bubbles right, agent left, "via Watchtower" marker on ask answers / Watchtower lines, collapsed brief line, separators, subagent rows with type/description/status, scroll to newest on open). Sent lines from the Tell bar show as pending bubbles until they appear in the feed.
- [ ] **Step 4:** PASS; `make mobile-build`; `make lint-swift`.
- [ ] **Step 5:** Commit `feat(mobile): session chat screen (#486)`.

### Task 5: Contracts and docs

**Depends on:** Tasks 3–4

**Files:**
- Modify: `docs/inventory/session-feed.md` (add **FEED-05** with guard tests `SessionChatSliceTests.testNoWatchPublishesNothing`, `SessionChatRunnerTests.testExpiredWatchLeavesWindow`, `SessionChatPayloadTests.testMatchesKitFixtureKeys`; changelog line citing ask #379), `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` (I-4 amended exactly as the spec's quoted text), `docs/superpowers/specs/2026-10-18-session-chat-iphone-design.md` (in-memory ruling), `docs/features/session-chat-feed.md` (phase 3 section), `docs/features/mobile-companion.md` (the new slice, action and I-4 exception), the user guide page for the phone (`docs/guide/` — the page that covers the iPhone app's sessions, per `docs/guide/WRITING.md`), `CLAUDE.md` (the session chat bullet: "phases 1-3", `session_chat` on the phone)
- [ ] **Step 1:** Write the docs; `go test ./docs/guide/` passes.
- [ ] **Step 2:** Commit `docs: session chat on the iPhone, FEED-05, I-4 amendment (#486)`.
