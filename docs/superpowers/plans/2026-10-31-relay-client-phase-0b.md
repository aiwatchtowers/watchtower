# Relay client Phase 0b — publishing on change — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac hub publishes a slice kind shortly after it changes (a phone action, a Desktop write, a Go write, a runner result) instead of on the 30 s full tick, while each kind is still saved at most once per the transport's minimum spacing (~2 s on CloudKit).

**Architecture:** `SlicePublisher`'s one loop keeps its cycles but every nudge now keeps its kinds (any kind), a 150 ms trailing debounce (capped at 1 s) replaces the 1 s window, and every cycle — fast, urgent tick, full tick — starts at least `Timing.spacing` after the previous one; the full tick becomes a 60 s backstop. Four change sources feed the nudge: the dispatcher after every applied action (one exhaustive `ActionKind → Set<SliceKind>` table), an in-process transaction observer over every table a slice reads (`HubChangeMap`), a `PRAGMA data_version` poll on its own read connection for Go's writes (`HubChangeWatch`, 250 ms hot / 1 s otherwise, which also refreshes `SessionAgentStateCenter`), and the three CLI runners' new `onChange`. The spacing is a property the hub transport provides (`HubTransport.minimumSendSpacing`; CloudKit = 2 s), so the hosted relay can bring 150 ms in Phase 2 without touching the publisher.

**Tech Stack:** Swift 5.10 language mode, SwiftUI/macOS 14 Desktop (`WatchtowerDesktop`), GRDB (`TransactionObserver`, `Database.recordingSelection`, `DatabaseRegion`), XCTest with a fabricated `ContinuousClock` (no real sleeps).

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md` (§6 "Publishing on change", §13 Phase 0b = board target #1238, Decisions: ask #735, ask #799)

## Global Constraints

- Phase 0b runs on CloudKit alone and does not depend on Phase 0a (#1237); the two run in parallel lanes. No Kit (`WatchtowerKit/`) or phone change in this phase.
- Minimum spacing between sends: ~2 s on CloudKit (each DataZone save is a silent push, battery rule #724); 150 ms on the hosted relay only (ask #735) — in 0b only the CloudKit value exists.
- Debounce: 150 ms trailing on the dirty-kind set; only dirty kinds are diffed. Full diff every 60 s as a backstop.
- `data_version` poll: every 250 ms while a phone is linked, the hub runs and the phone was in touch in the last 10 minutes; otherwise every 1 s; never slower than `SessionAgentStateCenter.pollInterval` (1 s), which it also nudges.
- The battery test `SlicePublisherTests.testANormalKindIsSavedAtMostOncePerThirtySeconds` is rewritten, not deleted, into "a kind is saved at most once per the transport's minimum spacing"; every other test that pins the 30 s / urgent-only rule is rewritten the same way, none deleted.
- Inventory guards stay unchanged: `docs/inventory/workbench.md` PROJ-11/12/16/21 (incl. `FastLaneTests::testTheReattachsEndReachesTheLivenessCopy` and every `SessionAgentStateCenterTests` guard), `docs/inventory/session-feed.md` FEED-05. `SessionAgentStateCenter.swift` is not modified.
- No mailbox-pass change: the 3 s / 30 s relay loop stays (the WebSocket-driven pass is Phase 2).
- Lanes: Task 1 → Task 2 in one lane; Tasks 3, 4 and 5 each in their own lane; Task 6 joins them; Task 7 is the gate.
- Inner loop only inside tasks: `make test-swift FILTER=<TestClass>` and `make lint-swift` (`make lint-diff` checks Go only). Full `make test-swift` / `make lint-all` run once, in Task 7.
- Timing tests use a fabricated clock (`FakeClock` in `SlicePublisherTests`/`FastLaneTests`) and step `takeDueCycle(now:)` / `poll()` directly; never `Task.sleep`.
- Public repo: no real ids, mail domains or local paths in tests, docs or the measurement notes.
- Swift / Desktop conventions of `docs/review/review-rules.md` apply (main-actor ownership, lock-guarded state for `Sendable` classes, no silent failure: a failing read is logged once per streak).

## Review Focus

1. **A storm of nudges never starves a send.** A daemon sync makes `data_version` change on nearly every poll, and the observer and runners nudge on top: a trailing debounce alone would never fire. Expect a cycle no later than `firstNudge + maxDebounce` (or the spacing, whichever is later). Test: Task 1 `testAContinuousNudgeStreamIsSentByTheMaxDebounce`.
2. **The watch's read fails or the file goes away** (workspace switch, a locked DB, a compaction): no nudge storm, one log line per failure streak, the 10 s urgent tick and the 60 s backstop keep publishing. Test: Task 3 `testAFailingReadNudgesNothingAndLogsOncePerStreak`.
3. **A stopped hub leaves nothing polling or observing.** After `stop()` the watch's loop ends and the transaction observer is removed; a later write nudges nothing. Tests: Task 3 `testStopEndsTheLoop`, Task 2 `testAStoppedLaneObservesNothing`.
4. **The 10-minute hot window at its edges.** Contact 599 s ago → 250 ms; 600 s, none, or no linked phone → 1 s. Test: Task 3 `testIsHotNeedsALinkedPhoneAndContactWithinTenMinutes`.
5. **No phone, no publishing (#724) survives "any kind is kept".** With no linked phone a nudge of any kind still publishes only `device_grant`. Test: Task 1 `testWithoutALinkedPhoneANudgeOfAnyKindPublishesOnlyTheGrant`.

---

### Task 1: Publisher — any kind nudged, 150 ms debounce, spacing on every cycle, transport spacing seam

**Depends on:** none

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/SlicePublisher.swift:26-85` (header comment, `Timing`), `:143-172` (`Lane`)
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/SlicePublisher+Loop.swift:8-134` (nudge, deadlines, `takeDueCycle`, sleep), `:163-206` (`run`, `sendAtOnce`)
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/MobileHubService.swift:8-41` (`HubTransport` requirement + CloudKit value), `:287-300` (`nudge`/`publishSoon` doc comments)
- Modify (tests): `WatchtowerDesktop/Tests/MobileHub/SlicePublisherTests.swift:62-72, 431-640, 787, 836, 858, 881`; `WatchtowerDesktop/Tests/MobileHub/MobileHubTestSupport.swift:14` (`StubHubTransport`); the `Timing` call sites `HubHeartbeatTests.swift:50`, `MobileHubServiceTests.swift:53`, `MobileSettingsTestSupport.swift:63`, `HubRunnerWakeTests.swift:161-176`; the publisher-timing lines of `FastLaneTests.swift:197-241` and `:599-657` (tick values only — Task 2 rewrites those two tests)

**Interfaces:**
- Produces:
  - `protocol HubTransport { var minimumSendSpacing: Duration { get } }` (sync requirement); `extension CloudKitTransport: HubTransport { nonisolated var minimumSendSpacing: Duration { .seconds(2) } }`; `StubHubTransport.minimumSendSpacing` settable, default `.seconds(2)`.
  - `SlicePublisher.Timing(tick:urgentTick:debounce:maxDebounce:spacing:)` — fields `tick`, `urgentTick`, `debounce`, `maxDebounce`, `spacing` (the labels `fastWindow`/`fastSpacing` are gone); `static func forTransport(spacing: Duration) -> Timing` = tick 60 s, urgentTick 10 s, debounce 150 ms, maxDebounce 1 s, `spacing`; `static let standard = forTransport(spacing: .seconds(2))`.
  - `nudge(kinds:)` keeps every kind; `publishSoon(kinds:)` unchanged in meaning (also sets the send request).
  - `Cycle` keeps its cases; `.urgent(Set<SliceKind>)` now carries any dirty kinds.
  - `Lane`: `firstNudgeAt`, new `lastNudgeAt`, `lastCycleAt` (replaces `lastFastSendAt`).

- [ ] **Step 1: Rewrite the pinned values and the lane tests (failing)**

In `SlicePublisherTests`:

```swift
func testPinnedTimingAndGuard() {
    XCTAssertEqual(SlicePublisher.Timing.standard.tick, .seconds(60))
    XCTAssertEqual(SlicePublisher.Timing.standard.urgentTick, .seconds(10))
    XCTAssertEqual(SlicePublisher.Timing.standard.debounce, .milliseconds(150))
    XCTAssertEqual(SlicePublisher.Timing.standard.maxDebounce, .seconds(1))
    XCTAssertEqual(SlicePublisher.Timing.standard.spacing, .seconds(2))
    XCTAssertEqual(SlicePublisher.Timing.forTransport(spacing: .milliseconds(150)).spacing, .milliseconds(150))
    XCTAssertEqual(StubHubTransport().minimumSendSpacing, .seconds(2), "the stub stands for CloudKit")
    // urgentKinds, unlinkedKinds, maxPayloadBytes, sliceSQL lines kept as they are
}
```

Lane tests on `FakeClock` (each `startedLane` takes the first full cycle at `origin`; spacing 2 s means nothing is due before `origin + 2 s`):
- `testNudgesInsideTheDebounceCoalesceIntoOneSend` (replaces `testNudgesInsideTheWindowCoalesceIntoOneSend`): at 3 s nudge `[.ownerAsk]`, at 3.1 s nudge `[.askAlert, .workbench]` → `fastDeadline == origin + 3.25 s`; `takeDueCycle(3.249 s) == nil`; `takeDueCycle(3.25 s) == .urgent([.ownerAsk, .askAlert, .workbench])` ("the normal kind is kept"); nothing more at 6 s.
- `testAContinuousNudgeStreamIsSentByTheMaxDebounce` (Review Focus 1): from 3 s nudge `[.workbench]` every 100 ms; the first non-nil `takeDueCycle` is at `origin + 4 s` (`first + maxDebounce`).
- `testTwoCyclesAreAtLeastTheSpacingApart` (replaces `testTwoNudgesOneAndAHalfSecondsApart…`): cycle taken at 3.15 s; nudge at 3.5 s → `fastDeadline == origin + 5.15 s`; `nil` at 5.149 s; due at 5.15 s.
- `testATickDueInsideTheSpacingWaits`: a fast cycle taken at 59 s → `takeDueCycle(60 s) == nil`, `takeDueCycle(61 s) == .full`; same for the urgent tick.
- `testANormalNudgeGoesOutAfterTheDebounce` (replaces `testANormalNudgeWaitsForTheFullTick`): nudge `[.workbench, .terminalSession, .workbenchTarget]` at 5 s → `.urgent` of those three at 5.15 s.
- `testAPhoneWritesKindsGoOutInTheFastLaneAndSendAtOnce` / `testAPhoneWritesSendSurvivesAFullTickAndAnEmptyDiff` / `testTicksCountFromACyclesEndAndAnySendSpacesTheFastLane`: same assertions, times moved to the 150 ms debounce, the 2 s spacing and the 60 s tick.
- `testEveryCycleThatChangedAnUrgentRecordSendsNow` → renamed `testANudgedCycleThatChangedAnyRecordSendsNow`: a nudged cycle that saved only a `workbench` record calls `sendNow` once; the 60 s full tick that saved only a normal record does not ("the backstop leaves normal records to CKSyncEngine"); the urgent tick that saved an ask does.
- `testWithoutALinkedPhoneANudgeOfAnyKindPublishesOnlyTheGrant` (Review Focus 5): `isLinked` false, sources grant + workbench + ask with payloads, nudge every kind → after the cycle only `device_grant-*` records were saved; workbench and ask sources read 0 times.

The battery test, rewritten in place (not deleted):

```swift
/// Owner decision Q3 (#724) as amended by ask #735: a kind changing every
/// 250 ms for two minutes, nudged each time, is saved at most once per the
/// transport's minimum spacing — and is not starved.
func testAKindIsSavedAtMostOncePerTheTransportsMinimumSpacing() async throws {
    for spacing in [Duration.seconds(2), .milliseconds(150)] {
        // fresh state + publisher with Timing.forTransport(spacing:), FakeClock, SendCounter
        // loop step 0...480: clock.set(250 ms × step); source.setPayload(step); nudge([.workbench]);
        //   run the due cycle if any; record the offset when a data save happened; record sendNow offsets
        let gaps = zip(saveTimes.dropFirst(), saveTimes).map { $0 - $1 }
        XCTAssertTrue(gaps.allSatisfy { $0 >= spacing }, "spacing \(spacing): \(gaps)")
        XCTAssertGreaterThanOrEqual(saveTimes.count, spacing == .seconds(2) ? 55 : 400, "not starved")
        let sendGaps = zip(sendTimes.dropFirst(), sendTimes).map { $0 - $1 }
        XCTAssertTrue(sendGaps.allSatisfy { $0 >= spacing }, "sendNow is spaced too")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test-swift FILTER=SlicePublisherTests`
Expected: FAIL (compile errors on `debounce`/`spacing`/`minimumSendSpacing`, then timing assertions).

- [ ] **Step 3: Implement**

- `Timing` as in Interfaces; `HubTransport.minimumSendSpacing`; `StubHubTransport` property.
- `nudge(kinds:)` → `enqueueFast(kinds)` (no `urgentKinds` filter). `enqueueFast` sets `firstNudgeAt` when the set was empty and `lastNudgeAt = clock()` on every call.
- `fastDeadline(lane, timing)` = `max(min(lastNudge + debounce, firstNudge + maxDebounce), (lastCycleAt ?? -∞) + spacing)`; nil with nothing pending.
- `takeDueCycle(now:)`: returns nil while `now < lastCycleAt + spacing`; otherwise today's order (full tick first, then fast + urgent merged); every taken cycle sets `lastCycleAt = now`.
- `nextTickDeadline` (the loop's wake) = `max(min(nextTick, nextUrgentTick), lastCycleAt + spacing)`.
- `run(_:)`: `sendAtOnce()` when `requested || urgentChanges > 0 || (cycle is .urgent && pushed + deleted > 0)`; `sendAtOnce` stamps `lastCycleAt` (was `lastFastSendAt`).
- Rewrite the header comment of `SlicePublisher` (lines 26-48) and the doc comments of `nudge`/`publishSoon` in `SlicePublisher+Loop.swift` and `MobileHubService.swift` to the new rule (no "30 s", no "only urgent kinds kept").
- Update the `Timing(...)` call sites listed in Files to the new labels (same durations: `debounce` = old `fastWindow`, `spacing` = old `fastSpacing`, `maxDebounce` = the same value as `debounce` where a test only needs a short window). In `HubRunnerWakeTests.testTheRunnersIdleAt15SecondsAndTheFastLaneKeepsItsCadence` replace the four publisher lines with the new pinned values (keep its runner lines) and rename it `testTheRunnersIdleAt15SecondsAndThePublisherPinsItsCadence`.
- In `FastLaneTests` change only what the 60 s tick and the 2 s gate break: in `testNeedsApprovalRidesTheNextFullTickWithoutAnImmediateSend` and `testReviewFocus5AStormOfStateChangesIsSavedAtMostOncePerTick` the full-tick offsets 30/60/90 s become 60/120 s and the fast cycle is taken after the debounce; Task 2 rewrites both.

- [ ] **Step 4: Run to verify they pass**

Run: `make test-swift FILTER='SlicePublisherTests|SlicePublisherPolicyTests|FastLaneTests|HubRunnerWakeTests|HubHeartbeatTests|MobileHubServiceTests|MobileSettingsViewModelTests'`
Expected: PASS. Then `make lint-swift` → no new violations.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/MobileHub/SlicePublisher.swift WatchtowerDesktop/Sources/Services/MobileHub/SlicePublisher+Loop.swift WatchtowerDesktop/Sources/Services/MobileHub/MobileHubService.swift WatchtowerDesktop/Tests/MobileHub
git commit -m "feat(mobile-hub): publish any nudged kind after a 150 ms debounce, spaced per transport (#1238)"
```

---

### Task 2: Every table a slice reads nudges its kinds; session states nudge the session kinds

**Depends on:** Task 1

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/HubChangeMap.swift`
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/FastLane.swift:7-58` (header, constants), `:117-163` (begin/end), `:189-194` (`statesRead`), `:207-228` (replace the per-table `ValueObservation`s)
- Create: `WatchtowerDesktop/Tests/MobileHub/HubChangeMapTests.swift`
- Modify (tests): `WatchtowerDesktop/Tests/MobileHub/FastLaneTests.swift:10-14, 192-241, 281-296, 350-384, 403-423, 545-673`; `WatchtowerDesktop/Tests/MobileHub/SessionTimelineSliceTests.swift:246-252`

**Interfaces:**
- Consumes: `SlicePublisher.nudge(kinds:)` keeping every kind (Task 1).
- Produces:
  - `enum HubChangeMap { static let tables: [String: Set<SliceKind>]; static func kinds(forTable: String) -> Set<SliceKind>; static var dbBackedKinds: Set<SliceKind> }` (`dbBackedKinds` = the union of all values; Task 6 hands it to the watch).
  - `FastLane.stateChangeKinds = [.ownerAsk, .askAlert, .permissionRequest, .terminalSession, .workbench, .sessionTimeline]`; new `FastLane.livenessKinds = [.terminalSession, .workbench, .askAlert, .permissionRequest]`; `FastLane.observedTables` removed (callers use `HubChangeMap`); test seam `FastLane.isObserving: Bool` replaces the `observedTables` counter.

- [ ] **Step 1: Write the guard test of the map (failing)**

`HubChangeMapTests.testEveryTableASourceReadsNudgesItsKind`: seed a workbench with a live claude session linked to a target with status history and a board column, a root comment with a reply, an open ask with a spec review on the session, a pending permission request, a calendar event with a prep cache row and a target, a transcript with a recap; build every DB-reading `SliceSource` the hub builds in `AppState.buildMobileHub` (`WorkbenchSlice`, `WorkbenchTargetSlice`, `WorkbenchCommentSlice`, `TerminalSessionSlice`, `OwnerAskSlice`, `WorkAlertSlice`, `PermissionRequestSlice`, `CalendarEventSlice`, `MeetingTranscriptSlice`, `SessionTimelineSlice`) with stub closures (the session live). For each source:

(`Database.recordingSelection` is internal to GRDB; the public route is the statement trace plus `Statement.databaseRegion`, both public.)

```swift
var sqls: [String] = []
db.trace(options: .statement) { if case let .statement(statement) = $0 { sqls.append(statement.sql) } }
_ = try source.records(db)
db.trace(options: [])
let region = try sqls.reduce(DatabaseRegion()) { try $0.union(db.makeStatement(sql: $1).databaseRegion) }
for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
where region.isModified(byEventsOfKind: .insert(tableName: table)) {
    XCTAssertTrue(HubChangeMap.kinds(forTable: table).contains(source.kind), "\(table) → \(source.kind)")
}
```

Plus `testDBBackedKindsAreTheMapsKinds` (`dbBackedKinds == Set(tables.values.joined())`, contains none of `.deviceGrant`, `.recordingJob`, `.sessionReport`, `.sessionChat` — sidecar or runner fed).

- [ ] **Step 2: Rewrite the FastLane tests (failing)**

- `testTheDesktopsOwnWritesNudgeTheKindsOfTheirTable` (replaces `testTheDesktopsOwnAskWritesNudgeTheAskKinds`): an `owner_asks` insert nudges exactly `HubChangeMap.kinds(forTable: "owner_asks")`; a `permission_requests` insert nudges that table's kinds; one transaction writing `targets` and `project_comments` nudges once with the union; a write that rolls back nudges nothing.
- `testAStoppedLaneObservesNothing` (Review Focus 3, split out of the old test with its positive control): after `stop()`, `isObserving == false` and a write nudges nothing while a live control lane over the same pool sees it.
- `testFastLaneObservesSpecReviews`: `HubChangeMap.kinds(forTable: "spec_reviews").isSuperset(of: [.ownerAsk, .askAlert])`.
- `testAStateChangeNudgesTheStateKinds` (replaces `testAStateChangeNudgesTheAskKinds`): one nudge equal to `FastLane.stateChangeKinds`; an unchanged read nudges nothing.
- `testALivenessChangeOnAnUnchangedReadNudgesTheLivenessKinds`: a session leaving `liveIDs` with no DB change → one nudge `FastLane.livenessKinds`.
- `testNeedsApprovalReachesThePhoneInTheFastLane` (replaces `testNeedsApprovalRidesTheNextFullTickWithoutAnImmediateSend`): after the hook writes `approval` and the center polls at 5 s, the cycle at `5 s + 150 ms` publishes `state_kind == "needs_approval"`, `state_tone == "orange"`, `state_glyph == "hand.raised.fill"`, and `sendNowCalls == 1`.
- `testReviewFocus5AStormOfStateChangesIsSavedAtMostOncePerSpacing` (replaces `…AtMostOncePerTick`): 30 sessions changing state every second for 60 s → consecutive `terminal_session` save offsets differ by ≥ 2 s; `sendNow` offsets too; the last published state of every session equals its last DB state no later than `lastChange + 2 s + 150 ms`.
- `testAZeroCountThatAgesOutReachesThePhoneOnTheTickAndTheFastLane` and `testAgentsWorkingPublishesAsWorkingAndRaisesNoAlert`: assertion messages updated ("nudges the state kinds"); their checks stay.
- `SessionTimelineSliceTests.testAskAndTargetWritesReachTheTimelineOnTheFullTick` → `testAskAndTargetWritesNudgeTheTimeline`: `kinds(forTable: "owner_asks")`, `"terminal_session_targets"` and `"target_status_history"` contain `.sessionTimeline`; `urgentKinds` still lacks it.
- `testTheReattachsEndReachesTheLivenessCopy` (PROJ-21 guard) and `testStartCopiesTheLivenessAndNudgesNothing`: unchanged.

- [ ] **Step 3: Run to verify they fail**

Run: `make test-swift FILTER='HubChangeMapTests|FastLaneTests|SessionTimelineSliceTests'`
Expected: FAIL (`HubChangeMap` missing).

- [ ] **Step 4: Implement**

- `HubChangeMap.tables`, starting list (the guard test is the arbiter — add any table it reports with the reporting source's kind):
  `owner_asks` → ownerAsk, askAlert, sessionTimeline, terminalSession, workbench · `spec_reviews` → ownerAsk, askAlert · `permission_requests` → permissionRequest, askAlert · `terminal_sessions` → terminalSession, workbench, permissionRequest, askAlert, sessionTimeline · `projects` → workbench, workbenchTarget, workbenchComment, terminalSession · `targets` → workbenchTarget, workbench, calendarEvent, sessionTimeline · `target_status_history` → workbenchTarget, sessionTimeline · `workbench_board_columns` → workbenchTarget · `project_comments` → workbenchComment, workbench · `terminal_session_targets` → sessionTimeline · `automations` → workbench · `calendar_events`, `meeting_prep_cache` → calendarEvent · `meeting_transcripts` → meetingTranscript, calendarEvent · `meeting_recaps` → meetingTranscript.
- In `FastLane`, replace `observe(_:kinds:)` with one private `HubTableObserver: TransactionObserver` (lock-guarded, `@unchecked Sendable`): `observes(eventsOfKind:)` = the table is in the map; `databaseDidChange(with:)` adds `event.tableName`; `databaseDidCommit` nudges the union of the touched tables' kinds once and clears; `databaseDidRollback` clears. `begin()` adds it with `dbPool.add(transactionObserver:extent: .observerLifetime)` and keeps a strong reference; `end()` calls `dbPool.remove(transactionObserver:)`.
- `statesChanged` nudges `stateChangeKinds`; `statesRead` nudges `livenessKinds` when `copyLiveness()` reports a change (before `sessionStatesChanged()`).
- Rewrite the `FastLane` header comment: it observes every table a slice reads in-process; Go's writes come from `HubChangeWatch` (Task 3).

- [ ] **Step 5: Run to verify they pass**

Run: `make test-swift FILTER='HubChangeMapTests|FastLaneTests|SessionTimelineSliceTests|SessionAgentStateCenterTests'`
Expected: PASS (the center's guard tests untouched). `make lint-swift` clean.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/MobileHub/HubChangeMap.swift WatchtowerDesktop/Sources/Services/MobileHub/FastLane.swift WatchtowerDesktop/Tests/MobileHub
git commit -m "feat(mobile-hub): every table a slice reads nudges its kinds in process (#1238)"
```

---

### Task 3: `HubChangeWatch` — Go's commits through a `PRAGMA data_version` poll

**Depends on:** none

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/HubChangeWatch.swift`
- Create: `WatchtowerDesktop/Tests/MobileHub/HubChangeWatchTests.swift`

**Interfaces:**
- Produces:

```swift
final class HubChangeWatch: HubCompanion, @unchecked Sendable {
    nonisolated static let hotInterval: Duration = .milliseconds(250)
    nonisolated static let coldInterval: Duration = .seconds(1)
    nonisolated static let contactWindow: TimeInterval = 600
    typealias ReadVersion = @Sendable () throws -> Int64
    init(readVersion: @escaping ReadVersion,
         isHot: @escaping @Sendable () -> Bool,
         onChange: @escaping @Sendable () -> Void,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) })
    /// One read; calls onChange when the version moved since the last good read; returns the next interval.
    func poll() -> Duration
    func start(); func stop()
    var stats: (polls: Int, changes: Int, failures: Int) { get }   // test seam + the measurement's counters
    static func isHot(linked: Bool, lastContact: Date?, now: Date) -> Bool
    /// A read-only DatabaseQueue of its own on `dbPath` (data_version is per connection).
    static func live(dbPath: String, isHot: @escaping @Sendable () -> Bool,
                     onChange: @escaping @Sendable () -> Void) throws -> HubChangeWatch
}
```

- [ ] **Step 1: Write the failing tests**

- `testPinnedIntervals`: `hotInterval == .milliseconds(250)`, `coldInterval == .seconds(1)`, `contactWindow == 600`, `coldInterval <= SessionAgentStateCenter.pollInterval` ("never slower than the center's poll").
- `testTheFirstReadIsTheBaselineAndNudgesNothing`: reader returns 7 → `poll()`; `stats.changes == 0`, onChange count 0.
- `testAChangedVersionCallsOnChangeOnce`: 7, 7, 8, 8 → one onChange, after the third poll.
- `testTheIntervalFollowsIsHot`: `isHot` true → `poll() == .milliseconds(250)`; false → `.seconds(1)`.
- `testIsHotNeedsALinkedPhoneAndContactWithinTenMinutes` (Review Focus 4): `(true, now − 599 s)` → true; `(true, now − 600 s)` → false; `(true, nil)` → false; `(false, now − 1 s)` → false.
- `testAFailingReadNudgesNothingAndLogsOncePerStreak` (Review Focus 2): 7, throw, throw, 7, throw, 9 → onChange once (the 9); `stats.failures == 3`; the failure log is emitted twice (two streaks; count it through an injected `logFailure` closure or a `failureStreaks` seam).
- `testStopEndsTheLoop` (Review Focus 3): a `sleep` closure that records each duration and calls `watch.stop()` on the third call → after `start()` the loop ends (await its task through a test seam `loopTaskForTesting`), exactly 3 polls, no poll after stop.
- `testTheLiveReaderSeesAnotherConnectionsCommit`: a temp `DatabasePool` with one table; `live(dbPath:)` on its path; first `poll()` baseline; a write through the pool → next `poll()` calls onChange; a `poll()` with no write does not.

- [ ] **Step 2: Run to verify they fail**

Run: `make test-swift FILTER=HubChangeWatchTests`
Expected: FAIL (`HubChangeWatch` missing).

- [ ] **Step 3: Implement** `HubChangeWatch.swift` as in Interfaces: state (last version, failing flag, counters, loop task) under one `OSAllocatedUnfairLock`; `start()` runs `while !Task.isCancelled { await sleep(poll()) }`; `stop()` cancels it; `live` opens `DatabaseQueue(path:configuration:)` with `readonly = true` and a label, and reads `PRAGMA data_version` with `inDatabase` (no transaction). A debug `Logger` line once per 60 s with `stats` (the measurement in Task 7 reads it). Doc comment: why a poll (Go writes through its own connection), why its own connection, and that once database encryption Stage 2 adds a key this connection must be opened with it like `DatabaseManager`'s.

- [ ] **Step 4: Run to verify they pass**

Run: `make test-swift FILTER=HubChangeWatchTests` → PASS; `make lint-swift` clean.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/MobileHub/HubChangeWatch.swift WatchtowerDesktop/Tests/MobileHub/HubChangeWatchTests.swift
git commit -m "feat(mobile-hub): HubChangeWatch sees Go's commits through PRAGMA data_version (#1238)"
```

---

### Task 4: The dispatcher asks for each applied action's kinds

**Depends on:** none

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/MobileHubCommandDispatcher.swift:24-51`
- Create: `WatchtowerDesktop/Tests/MobileHub/MobileHubCommandDispatcherTests.swift`

**Interfaces:**
- Produces:
  - `MobileHubCommandDispatcher.publishSoon: (@MainActor (Set<SliceKind>) -> Void)?` (nil by default, so the existing `MobileHubCommandDispatcher()` call sites in tests are unchanged).
  - `nonisolated static func publishedKinds(after kind: ActionKind) -> Set<SliceKind>` — an exhaustive `switch` with no `default`, so a new `ActionKind` cannot compile without its entry:

| `ActionKind` | kinds |
|---|---|
| `askAnswer` | ownerAsk, askAlert, sessionTimeline |
| `boardTargetStatus`, `boardTargetPriority`, `boardCommentAdd`, `boardCommentReply`, `boardTargetCreate` | `BoardHandlers.publishedKinds` |
| `sessionStart` | terminalSession, workbench, sessionTimeline |
| `sessionInput`, `sessionInputCancel`, `sessionFinishRequest`, `sessionInterrupt` | terminalSession, sessionChat |
| `sessionStop` | terminalSession, workbench, askAlert, permissionRequest |
| `sessionReportRequest` | sessionReport |
| `permissionAnswer` | permissionRequest, askAlert, terminalSession |
| `sessionChatRequest` | sessionChat |
| `automationRun` | workbench |
| `probe` and the pre-POC kinds (`targetDone`, `targetSnooze`, `inboxResolve`, `inboxDismiss`, `inboxSnooze`, `taskCreate`, `trackRead`, `situation*`, `dayPlanItem*`, `digestRead`, `streamDigestRead`) | `[]` |

- [ ] **Step 1: Write the failing tests**

- `testThePublishTablePinsTheSessionAndBoardKinds`: the `sessionStart`, `sessionStop`, `permissionAnswer` rows above; `publishedKinds(after: .boardCommentAdd) == BoardHandlers.publishedKinds`; `.probe` → `[]`.
- `testADispatchedActionAsksForItsKindsOnce`: register `.sessionStart` returning `.applied()`; `publishSoon` records → `[[.terminalSession, .workbench, .sessionTimeline]]`.
- `testAThrowingOrRefusedHandlerStillAsksForItsKinds`: a handler that throws, and one returning `.failed(.conflict)` → each records its kinds once (the dispatch still throws / returns the failure).
- `testAKindWithoutAHandlerOrWithAnEmptyEntryAsksForNothing`: unregistered `.askAnswer` → `dispatch` returns nil, no call; a registered `.probe`-style empty entry → no call with an empty set.

- [ ] **Step 2: Run to verify they fail**

Run: `make test-swift FILTER=MobileHubCommandDispatcherTests` → FAIL.

- [ ] **Step 3: Implement** — `dispatch` keeps its signature; after a registered handler returns or throws (a `defer`), it calls `publishSoon?(kinds)` when `kinds` is not empty. The handlers' own `publishSoon` calls (`BoardHandlers`, `AutomationRunHandler`) stay: they coalesce in the lane and their tests pin them. Doc comment: the dispatcher-level nudge generalises `BoardHandlers`' (spec §6.1).

- [ ] **Step 4: Run to verify they pass**

Run: `make test-swift FILTER='MobileHubCommandDispatcherTests|BoardHandlersTests|AutomationRunHandlerTests|RelayProcessorTests'` → PASS; `make lint-swift` clean.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/MobileHub/MobileHubCommandDispatcher.swift WatchtowerDesktop/Tests/MobileHub/MobileHubCommandDispatcherTests.swift
git commit -m "feat(mobile-hub): nudge each applied phone action's slice kinds (#1238)"
```

---

### Task 5: The CLI runners report a changed result

**Depends on:** none

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/WorkbenchGitRefresher.swift:240-246` (`store`)
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/SessionReportSummaryRunner.swift:255` (`store`)
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/SessionReportRunner+Pass.swift:58-90` (milestones), `:197-202` (report save); the property in `SessionReportRunner.swift`
- Modify (tests): `WatchtowerDesktop/Tests/MobileHub/HubRunnerWakeTests.swift` (its fake fetches and test clock)

**Interfaces:**
- Produces, on each of `WorkbenchGitRefresher`, `SessionReportSummaryRunner`, `SessionReportRunner`: `var onChange: (@Sendable () -> Void)?` stored under a lock, the shape of `SessionChatRunner.onChange` (`SessionChatRunner.swift:83-90`). Each runner knows nothing of slice kinds; Task 6 maps them.

- [ ] **Step 1: Write the failing tests** (in `HubRunnerWakeTests`)

- `testGitRefresherCallsOnChangeOnlyWhenTheSnapshotChanges`: two passes with the same status → 1 call; a changed branch → 2.
- `testSummaryRunnerCallsOnChangeOnlyWhenASummaryChanges`: same summaries twice → 1; a changed one → 2.
- `testReportRunnerCallsOnChangeWhenAStoredReportOrMilestoneChanges`: a first report → 1; the same bytes again → still 1; a new state milestone → 2; a timed-out or failed run → no call.

- [ ] **Step 2: Run to verify they fail**

Run: `make test-swift FILTER=HubRunnerWakeTests` → FAIL (`onChange` missing).

- [ ] **Step 3: Implement** — git: call after `store` when the entry's snapshot differed; summary: when the stored dictionary differed; report: compare the encoded payload with the stored one (`sidecar.sessionReports()[id]`) before `saveSessionReport` and call only on a difference; call too after `addStateMilestone`. Never under the runner's lock.

- [ ] **Step 4: Run to verify they pass**

Run: `make test-swift FILTER='HubRunnerWakeTests|SessionReportSliceTests|SessionTimelineSliceTests|WorkbenchSliceTests|TerminalSessionSliceTests'` → PASS; `make lint-swift` clean.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/MobileHub/Slices WatchtowerDesktop/Tests/MobileHub/HubRunnerWakeTests.swift
git commit -m "feat(mobile-hub): git, summary and report runners report a changed result (#1238)"
```

---

### Task 6: Wire the change sources into the hub

**Depends on:** Task 1, Task 2, Task 3, Task 4, Task 5

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/AppState+MobileHub.swift:94-190` (`buildMobileHub`)

**Interfaces:**
- Consumes: `SlicePublisher.Timing.forTransport(spacing:)`, `HubTransport.minimumSendSpacing` (Task 1); `HubChangeMap.dbBackedKinds` (Task 2); `HubChangeWatch.live(dbPath:isHot:onChange:)`, `HubChangeWatch.isHot(linked:lastContact:now:)` (Task 3); `MobileHubCommandDispatcher.publishSoon` (Task 4); the runners' `onChange` (Task 5).

- [ ] **Step 1: Wire**
  - `SlicePublisher(… timing: .forTransport(spacing: storage.transport.minimumSendSpacing) …)`.
  - `dispatcher.publishSoon = { [weak self] in self?.mobileHub?.publishSoon(kinds: $0) }`.
  - `gitRefresher?.onChange` → `publisher.nudge(kinds: [.workbench])`; `summaries?.onChange` → `[.terminalSession]`; `reports?.onChange` → `[.sessionReport, .sessionTimeline]` (each `[weak publisher]`).
  - `HubChangeWatch.live(dbPath: dbPool.path, isHot: { HubChangeWatch.isHot(linked: hasPhone(), lastContact: hasPhone() ? sidecar.lastPhoneContact() : nil, now: Date()) }, onChange: …)` where `onChange` nudges `HubChangeMap.dbBackedKinds` and hops to the main actor to call `sessionAgentStateCenter.refresh()` only while `isPolling` (a live agent session; otherwise the center has nothing to follow). A throwing `live` is logged and the hub runs without the watch (the 10 s urgent tick and the 60 s backstop remain). Append the watch to `companions` (started with the publisher, stopped with the hub).
  - Update the comments in `buildMobileHub` that say "normal kinds: the next full tick diffs them" (`:164-165`, `:206-207`).

- [ ] **Step 2: Build and run the hub suites**

Run: `make test-swift FILTER='MobileHubServiceTests|MobileHubPolicyTests|HubHeartbeatTests|FastLaneTests|SlicePublisherTests|HubChangeWatchTests'` → PASS; `make lint-swift` clean. (`buildMobileHub` has no unit harness today; its pieces are tested in Tasks 1–5 and the whole is checked on a device in Task 7.)

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/App/AppState+MobileHub.swift
git commit -m "feat(mobile-hub): wire publish-on-change sources into the hub (#1238)"
```

---

### Task 7: Phase gate — full suites, docs, load measurement, device check

**Depends on:** Task 6

**Files:**
- Modify: `docs/features/mobile-companion.md:214, 289, 365, 379, 484` and every other "30 s full tick" / "urgent kinds only" cadence line (`grep -n "full tick\|urgent tick\|fast lane" docs/features/mobile-companion.md`)
- Modify: `CLAUDE.md` (the Mobile companion feature-list entry: "`SlicePublisher` (30 s full tick, 10 s urgent tick, 1 s / 2 s fast lane for asks only …)")
- Modify: `docs/superpowers/specs/2026-10-29-relay-client-design.md` (Decisions: the measured interval)

- [ ] **Step 1: Docs.** Rewrite the cadence lines to the shipped rule: any nudged kind after a 150 ms trailing debounce (≤ 1 s), every cycle ≥ the transport's spacing apart (CloudKit 2 s), 10 s urgent tick, 60 s backstop; the four change sources (dispatcher table, `HubChangeMap` observer, `HubChangeWatch` 250 ms / 1 s with the 10-minute contact window, runner `onChange`); a nudged cycle that changed any record sends at once, the backstop only for urgent records or a phone write; the battery test's new name. Replace the "No generic kind unchanged skip … `PRAGMA data_version` is per connection and database-wide" passage with what the watch does and why it still diffs every DB-backed kind. The user guide (`docs/guide/features/iphone.md`) states only the relay cadence, which 0b keeps: no guide change.

- [ ] **Step 2: Gate.** Run `make test-swift > "$LOG_DIR/test-swift.log" 2>&1; echo "exit=$?"` (`LOG_DIR` = the run's scratch directory) and `make lint-all`; expected `exit=0` and no lint violations. The inventory guards named in Global Constraints pass unchanged (`git diff main -- docs/inventory` is empty).

- [ ] **Step 3: Load measurement** (signed build of this branch on a **copy** of a workspace, never the live database; Development-signed Mac with an Xcode-run phone per `docs/features/mobile-companion.md` "CloudKit environments").
  Three 5-minute runs, nothing else open, Desktop in the background:
  - **A — cold:** hub on, phone linked, no phone action for > 10 min (1 s poll).
  - **B — hot idle:** the same right after one phone action (250 ms poll), no daemon sync running.
  - **C — hot during sync:** as B while `watchtower sync --now` runs a full cycle.
  For each: Activity Monitor → Energy → "Energy Impact" of Watchtower read every 30 s and averaged; `top -l 60 -s 5 -pid <pid> -stats cpu` averaged; the watch's debug line (`log stream --predicate 'category == "HubChangeWatch"' --level debug`) for polls and changes per minute. Run C also on `main` for the comparison.
  **Pass:** B − A ≤ 0.5 Energy Impact and ≤ 0.5 percentage points of CPU; C (branch) − C (main) ≤ 3 percentage points of CPU averaged over the sync cycle. If a bound fails, do not change the interval silently: file an owner ask with the numbers and the options (500 ms hot interval; or nudging only the workbench kinds from the watch).

- [ ] **Step 4: Record the result** in the spec's Decisions line for the `data_version` interval (the three averages, no machine names), and in `docs/features/mobile-companion.md` next to `HubChangeWatch`.

- [ ] **Step 5: Device check** (one, the phase touches what the phone sees): a board comment, a session start and a permission answer from the phone each show their effect on the phone within ~3 s; with the phone left alone > 10 min the watch reports the 1 s interval; a session state change from Go reaches the phone without a phone action.

- [ ] **Step 6: Commit**

```bash
git add docs/features/mobile-companion.md CLAUDE.md docs/superpowers/specs/2026-10-29-relay-client-design.md
git commit -m "docs(mobile-hub): publish-on-change cadences and the data_version measurement (#1238)"
```

---

## Overlap with Phase 0a (#1237)

- `MobileHubService.swift`: 0b adds `minimumSendSpacing` to `HubTransport` and the CloudKit conformance at `:41`; 0a's `HubTransportFactory` replaces the direct `CloudKitTransport(...)` construction in `MobileHubStorage.live()` (`:128-145`). Different lines; whichever merges second keeps the requirement on the protocol the factory returns.
- `AppState+MobileHub.swift` `buildMobileHub`: 0b edits the publisher, dispatcher and companion lines; 0a may touch how `storage` is built. Rebase, no shared logic.
- The hosted relay's `minimumSendSpacing` (150 ms) and the WebSocket-driven mailbox pass (§6.5–6.6) land with `HostedRelayTransport` in Phase 2.
