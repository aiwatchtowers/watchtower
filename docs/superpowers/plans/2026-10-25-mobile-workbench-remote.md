# Mobile workbench remote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Design reference:** `docs/design/mobile/mockups.html` — 17 approved-direction mockups (screens 1–8 approved, ask #618).

**Goal:** The owner can run workbench sessions from the iPhone without sitting at the Mac: near-live workchat with a state line, chatting while the agent works, a push for every stop of work while away, and the whole app redesigned in the Desktop's language.

**Architecture:** The Mac hub (Desktop process) gains an away gate and one generalised alert kind (`ask_alert` carries four events), a faster session-chat lane and the PROJ-16 send-while-busy rule; the phone first moves onto a token module shared with the Desktop and a set of parts drawn from the approved mockups, then registers the CloudKit subscription it never registered, routes taps, merges session detail and chat into one workchat screen, and rebuilds every other screen to its mockup.

**Tech Stack:** Swift 5.10 mode (Swift 6 toolchain), SwiftUI, GRDB, CloudKit (`CKSyncEngine`, `CKQuerySubscription`), UserNotifications, IOKit power assertions, CoreGraphics event source; Go untouched except docs.

**Spec:** `docs/superpowers/specs/2026-10-25-mobile-workbench-remote-design.md` (approved, ask #615). Read it first; § numbers below are the spec's.

## Global Constraints

- Hub lives in the Desktop process; only the Desktop executable target links the Kit's `WatchtowerSync`; `WatchtowerCore` stays Kit-free (`PublicAPISurfaceTests`).
- Wire raw values never change: `SliceKind` raw strings, `ActionReason` raw strings, record names `<kind>-<id>`.
- Alert titles are sealed under `K_alert` only; no chat text ever goes into an alert. Chat stays in memory on the hub (FEED-01).
- Away = screen locked, displays asleep, console idle ≥ `180 s`, or the console user session inactive. Back at once on unlock or input.
- Stop pushes only after the state held `20 s`. One stop of work, one push. Nothing older than the hub's `enabled_at` ever alerts. Alert lifetime 7 days.
- Workchat while open: runner reads every `3 s` while the agent is live; `session_chat` is an urgent kind; phone repeat request stays 60 s; watch stays 5 min; caps unchanged (300 entries, 4000 chars, 600 000 bytes).
- Send while busy only for `claude` sessions; Codex, shell and unknown kinds keep the busy hold (PROJ-16 amended, ask #614).
- Keep-awake: `PreventUserIdleSystemSleep` while ≥ 1 live board session AND a linked phone's last contact < 24 h AND the toggle is on (default on).
- iOS 17 / macOS 14 floors. No new colours or fonts: semantic colours, Dynamic Type, SF Symbols; status colours only from `Tone`; touch targets ≥ 44 pt.
- Inner loop only per task (`make test-swift FILTER=…`, `make kit-test FILTER=…`, `make mobile-test MOBILE_FILTER=…`, `make lint-swift` — `lint-diff` does not check Swift). Full gate once per phase by the controller.
- Every user-visible change updates `docs/guide/features/iphone.md` (and `docs/guide/reference/settings.md` for new toggles) per `docs/guide/WRITING.md`; feature-note changes go to `docs/features/mobile-companion.md` / `session-chat-feed.md`; contract changes to `docs/inventory/workbench.md`. Guide edits: `go test ./docs/guide`.
- Public repo hygiene: demo data only, no real names/ids.

## Review Focus

1. **Owner returns, then leaves again** while the same ask is still open → no second push (ledger `pushed`). Test in Task 6 `testASecondAwayPeriodDoesNotRepushTheSameAsk`.
2. **A session stops with an open ask** (`waitingOnAsk`) or stops on a permission prompt (`needsApproval`) → exactly one push (the ask / the request), never also a session push. Task 6 `testAWaitingOnAskSessionPushesOnlyTheAsk`, `testNeedsApprovalPushesOnlyTheRequest`.
3. **The Mac restarts / the hub is rebuilt while the owner is away** → no push storm for old stops (enabled_at and ledger). Task 6 `testAHubRestartRepublishesWithoutNewSignals`.
4. **A phone line sent while a Claude agent works, then a permission prompt appears** → the line is held (`needs_approval`), never typed into the prompt. Task 11 `testProj16_AWorkingClaudeSessionTakesTheLineButNeverAPrompt`.
5. **The Mac is asleep or Watchtower is quit** while the phone shows a workchat → the screen says so and a sent line reads "Waiting for your Mac", never a fake "Sent". Task 13 `testAStaleHeartbeatShowsMacAsleepAndHoldsTheComposerCaption`.

---

## Phase A — design system first (spec §6; mockups approved, ask #618)

### Task 1: One token module for Desktop and phone

**Files:**
- Modify: `WatchtowerKit/Package.swift` (new target + product `WatchtowerDesign`, SwiftUI only, no GRDB), `WatchtowerDesktop/Package.swift` (DesignKit depends on `WatchtowerDesign`), `WatchtowerMobile/project.yml` (+ `make mobile-gen`)
- Create: `WatchtowerKit/Sources/WatchtowerDesign/Tokens.swift`, `Tone.swift` (moved from DesignKit; platform shims under `#if canImport(AppKit)` / `UIKit` for `Stroke.hairlineColor` and `Tone.amber`)
- Modify: `WatchtowerDesktop/Sources/DesignKit/Tokens.swift`, `Tone.swift` → `@_exported import WatchtowerDesign` (keep names public through DesignKit; `Surface.swift` stays macOS-only); phone `DesignSystem/Metrics.swift` and `PhoneTone.swift` read the shared values (phone-only additions — `RowInsets`, `TypeScale`, the orange reservation — stay in the phone)
- Modify: `WatchtowerDesktop/Tests/Core/PublicAPISurfaceTests.swift` only if `WatchtowerDesign` trips its module list (Core must still not import it), `WatchtowerMobile/Tests/DesignSystemTests.swift` (expected values now Desktop's: Radius gains container 10/bubble 16/pill 18, card radius = `Radius.container`), `WatchtowerMobile/.swiftlint.yml` (`orange_outside_phone_tone` still allows `PhoneTone.swift`; add `kit_no_raw_metrics` and `kit_no_color_opacity` scoped to `Sources/Features/`)
- Test: `WatchtowerKit/Tests/WatchtowerDesignTests/TokenTests.swift` (pins every value from `docs/design/desktop-style-guide.md` Tokens table)
- [ ] Steps: token tests FAIL → move → `make kit-test FILTER=TokenTests`, `make test-swift FILTER='PublicAPISurfaceTests|DesignShotsTests'`, `make mobile-test MOBILE_FILTER='DesignSystemTests|OrangeToneTests'`, `make design-gallery` builds, `make lint-swift` → PASS → commit `refactor(design): one token module shared by the Desktop and the phone`. Desktop pixels must not change: run `make desktop-shots DESKTOP_SHOTS=<scratch>` before and after and diff file hashes.

### Task 2: Phone components in the Desktop language

**Files:**
- Modify: every file in `WatchtowerMobile/Sources/DesignSystem/` — `Card.swift` (soft `Fill.card` + hairline, `Radius.container`, no opaque system fill), `Pill.swift` (`ChipTint` 0.14 fill + 0.5 stroke at 0.3, like `Chip`), `FlatRow.swift` (`.kitRow`-like fills, no `RowDivider` between rows), `Bars.swift` (composer bar like `WorkchatComposer`), `Parts.swift` (`SessionDot` = Desktop `SessionLiveDot`); add `SectionHeader` caps style with `Tracking.caps` per the Desktop `SectionHeader`; add `ChatBubble` (owner right on accent `Fill.selected`, `Radius.bubble`; agent left without a bubble; Watchtower lines as captions — Desktop `SessionChatRow`/`UserMessageBubble`)
- Modify: `WatchtowerMobile/Tests/ScreenshotTourTests.swift` — shot list covers spec §6.2's list: Now, workbench list, workbench sessions, workchat (working / waiting / permission card / inline ask / composer states), board, target detail, three ask views, agenda, event detail, recordings, recap, Settings, Macs, linking screens, empty and Mac-asleep states, a notification mock (rendered `UNNotificationContent` preview card)
- Test: `DesignSystemTests` updated to the new paints
- **Reference:** the approved mockups `docs/design/mobile/mockups.html` (screens 1–17, light and dark; 1–8 approved in ask #618) are the target look for every part: take sizes, fills, radii and copy from there, mapped onto the Task 1 tokens.
- Also add the parts the mockups use that the phone lacks: `StateLine` (dot/glyph + caption + optional "m:ss" timer; mockups 3, 4, 8), `MacStatusChip` (1, 7), `InlinePermissionCard` and `InlineAskCard` (4), `WorkchatComposerBar` (3, 4, 8), `BoardCard` (5, = Desktop `WorkbenchBoardCardView`), `CalendarRow` (7, = Desktop `CalendarEventRow`), `PrimaryActionBar` (9–12), `SettingsCard` with small switches (16).
- [ ] **Step 1:** Update `DesignSystemTests` to the new paints and add one test per new part (inputs → visible strings and tones) → FAIL. **Step 2:** build the parts → `make mobile-test MOBILE_FILTER='DesignSystemTests|OrangeToneTests'` PASS. **Step 3:** add a `designSystemShots()` page to `ScreenshotTourTests` rendering each part in its mockup states; `make mobile-shots` (default `build/mobile-shots`, gitignored); compare with the mockups side by side and fix drift. **Step 4:** `make lint-swift`. **Step 5:** commit `feat(mobile): design system in the Desktop language`.

---

## Phase B — pushes when work stops (spec §5.1, §5.2, §5.6 keep-awake)

### Task 3: Away gate

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/OwnerAwayPolicy.swift`
- Create: `WatchtowerDesktop/Sources/Services/OwnerAwayCenter.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (own and start the center next to `ownerPresenceCenter`, ~:365, ~:1845; stop in `clearForQuit` ~:727)
- Test: `WatchtowerDesktop/Tests/Core/OwnerAwayPolicyTests.swift`, `WatchtowerDesktop/Tests/OwnerAwayCenterTests.swift`

**Interfaces:**
- Produces:
  - `package enum OwnerAwayPolicy { package static let idleThreshold: TimeInterval = 180; package static func isAway(screenLocked: Bool, displaysAsleep: Bool, idleSeconds: TimeInterval, sessionActive: Bool) -> Bool }`
  - `final class OwnerAwayBox: @unchecked Sendable { func read() -> Bool; func write(_ away: Bool) }` (lock-protected, default `false`) — in `OwnerAwayCenter.swift`.
  - `@MainActor @Observable final class OwnerAwayCenter { init(box: OwnerAwayBox, clock: @escaping () -> Date = { Date() }, inputs: Inputs = .live, sources: OwnerPresenceCenter.NotificationSources = .live); private(set) var isAway: Bool; @ObservationIgnored var onChange: ((Bool) -> Void)?; func start(); func stop() }`
  - `struct Inputs { var screenLocked: () -> Bool; var displaysAsleep: () -> Bool; var idleSeconds: () -> TimeInterval; var sessionActive: () -> Bool; static let live }` — `idleSeconds` = `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)` (no TCC); `screenLocked` = `OwnerPresenceCenter.sessionScreenIsLocked`; `sessionActive` from `NSWorkspace.sessionDidBecomeActive/ResignActive`.
  - `AppState.ownerAwayBox: OwnerAwayBox` (one per app, never rebuilt — the hub captures it) and `AppState.ownerAwayCenter`.
- Leave `OwnerPresencePolicy` and `OwnerPresenceCenter` untouched (spec §5.1).

- [ ] **Step 1: Write failing tests.** Policy: `testLockedIsAway`, `testDisplaysAsleepIsAway`, `testIdleUnderThresholdIsPresent` (179 → false), `testIdleAtThresholdIsAway` (180 → true), `testInactiveSessionIsAway`. Center (fake `Inputs`, manual clock): `testLockNotificationTurnsAwayAtOnce`, `testUnlockReturnsAtOnce`, `testIdlePollTurnsAwayAfterThreshold` (poll every 15 s), `testOnChangeFiresOnlyOnChange`, `testBoxMirrorsState`.
- [ ] **Step 2:** `make test-swift FILTER='OwnerAwayPolicyTests|OwnerAwayCenterTests'` → FAIL (types missing).
- [ ] **Step 3:** Implement. Center re-evaluates on the lock/unlock distributed notifications, `screensDidSleep/Wake`, session active/resign, and a 15 s timer; writes the box before `onChange`.
- [ ] **Step 4:** Same command → PASS; `make lint-swift`.
- [ ] **Step 5:** Commit `feat(desktop): owner-away gate for phone alerts`.

### Task 4: Alert ledger in the hub sidecar

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/HubSyncState.swift` (schema ~:75, `markAlerted` ~:821, `pruneAlertedAsks` ~:841, `wipeSyncState` ~:885–938)
- Test: `WatchtowerDesktop/Tests/MobileHub/HubSyncStateWorkAlertsTests.swift`

**Interfaces:**
- Produces (replacing `AlertedAsk`, `markAlerted`, `pruneAlertedAsks`; `alerted_asks` is copied once then dropped):
  - Table `work_alerts(key TEXT PRIMARY KEY, seen_at REAL NOT NULL, pushed_at REAL, generation INTEGER NOT NULL)`; one-time copy `INSERT OR IGNORE INTO work_alerts SELECT 'ask-'||ask_id, at, at, generation FROM alerted_asks` then `DROP TABLE alerted_asks`, both inside the sidecar's schema setup.
  - `struct WorkAlertMark: Equatable, Sendable { let seenAt: Date; let pushedAt: Date?; let generation: Int }`
  - `func noteWorkAlerts(_ keys: [String], at: Date) throws -> (generation: Int, marks: [String: WorkAlertMark])` — insert-if-absent with `seen_at`, return marks for all given keys.
  - `func markWorkAlertsPushed(_ keys: [String], at: Date) throws` — sets `pushed_at` only where NULL.
  - `func pruneWorkAlerts(olderThan: Date, keeping: Set<String>) throws`
  - `wipeSyncState` keeps today's semantics on the new table (delete current-generation rows within 7 days with no `slice_state` hash for `ask_alert-<key>`, bump generation).

- [ ] **Step 1: Write failing tests:** `testFirstSeenWins`, `testPushedAtIsSetOnce`, `testPruneKeepsOpenKeys`, `testOldAlertedAsksRowsMigrateAsPushed` (pre-create `alerted_asks` with ask 7 → `ask-7` pushed), `testWipeBumpsGenerationAndKeepsPublishedRows`.
- [ ] **Step 2:** `make test-swift FILTER=HubSyncStateWorkAlertsTests` → FAIL.
- [ ] **Step 3:** Implement; update the two callers to compile (`AskAlertSlice` is rewritten in Task 6 — keep it building by mapping to `ask-<id>` keys for now).
- [ ] **Step 4:** `make test-swift FILTER='HubSyncStateWorkAlertsTests|AskAlertSliceTests|MobileHubServiceTests'` → PASS.
- [ ] **Step 5:** Commit `feat(mobile-hub): work_alerts ledger with seen and pushed`.

### Task 5: Kit alert payload for four events

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/AlertOpener.swift` (`AskAlertPayload` → `WorkAlertPayload`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/AskAlertSubscription.swift` (doc only: subscription now carries all work alerts; ID unchanged)
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/AlertOpenerTests.swift`

**Interfaces:**
- Produces:
  - `public struct WorkAlertPayload: Codable, Equatable, Sendable { public enum Event: String, Codable, Sendable { case ask, permission, sessionStopped = "session_stopped", sessionFailed = "session_failed" }; event, key: String, workbenchID: Int64, workbenchName: String, sessionID: Int64?, askID: Int64?, requestID: Int64?, title: String, body: String, quick: Bool }` — keys snake_case (`work_alert` fields: `event`, `key`, `workbench_id`, `workbench_name`, `session_id`, `ask_id`, `request_id`, `title`, `body`, `quick`). `title` = what the notification shows as title (workbench name · session title or workbench name), `body` per spec §5.2 table.
  - `AlertOpener.open(wireName:envelope:) -> WorkAlertPayload?` and `payload(...) throws -> WorkAlertPayload`; the frame kind check stays `SliceKind.askAlert` (wire `ask_alert` unchanged; hard cut accepted, spec §5.2).
  - `public enum WorkAlertKey { static func ask(_ id: Int64) -> String /* "ask-<id>" */; static func permission(_ id: Int64) -> String /* "perm-<id>" */; static func stop(session: Int64, stateAt: Date) -> String /* "stop-<session>-<unix ms>" */ }`

- [ ] **Step 1:** Update tests: round-trip each event; `testAnOldAskShapedPayloadDoesNotOpen` (missing `event` → nil, so the extension falls back to the generic body); key formats.
- [ ] **Step 2:** `make kit-test FILTER='AlertOpenerTests|AskAlertSubscriptionTests'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same → PASS; `make lint-swift`.
- [ ] **Step 5:** Commit `feat(kit): work alert payload for asks, permissions and session stops`.

### Task 6: Hub work-alert slice

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/WorkAlertSlice.swift` (replaces `AskAlertSlice.swift`, deleted)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkAlertPolicy.swift` (pure event selection)
- Modify: `WatchtowerDesktop/Sources/App/AppState+MobileHub.swift` (:74 source, :99 FastLane wiring), `WatchtowerDesktop/Sources/Services/MobileHub/FastLane.swift` (nudge `.askAlert` on away change)
- Test: `WatchtowerDesktop/Tests/Core/WorkAlertPolicyTests.swift`, `WatchtowerDesktop/Tests/MobileHub/WorkAlertSliceTests.swift` (replaces `AskAlertSliceTests.swift`)

**Interfaces:**
- Consumes: Task 3 `OwnerAwayBox.read()`, Task 4 ledger, Task 5 `WorkAlertPayload`/`WorkAlertKey`; `TerminalSessionSlice.publishedSessions(_:)` (`Published.state.kind`, `TerminalSessionSlice.stateAt(_:)`), `PermissionRequestSlice` row reading, `WorkbenchSlice.publishedWorkbenchRefs`.
- Produces:
  - `package enum WorkAlertPolicy { package static let stopHold: TimeInterval = 20; package enum Event: String { case ask, permission, sessionStopped = "session_stopped", sessionFailed = "session_failed" }; package struct AskInput { id, workbenchID, sessionID: Int64?, title, kind, createdAt: Date }; package struct RequestInput { id, sessionID, workbenchID, toolName, createdAt: Date }; package struct SessionInput { id, workbenchID, title, kind: SessionSwitcherPresentation.State.Kind, stateAt: Date?, openAsks: Int, hasPendingRequest: Bool }; package struct Candidate: Equatable { key: String, event: Event, workbenchID: Int64, sessionID: Int64?, askID: Int64?, requestID: Int64?, startedAt: Date, title: String, body: String }; package static func candidates(asks: [AskInput], requests: [RequestInput], sessions: [SessionInput], now: Date) -> [Candidate] }` (Core has no Kit types, so the slice maps `Candidate` to the Kit `WorkAlertPayload`). Rules: every open ask → `ask`; every pending request → `permission`; a session whose kind is `.finished` or `.stopped` → `sessionStopped`, `.failed` → `sessionFailed`, only when `stateAt` is set, `now - stateAt >= stopHold`, `openAsks == 0` and `!hasPendingRequest`; `.waitingOnAsk`, `.readyToCheck` and `.needsApproval` never yield a session candidate (their ask or request does).
  - `struct WorkAlertSlice: SliceSource { let kind = SliceKind.askAlert; init(sidecar: HubSyncState, isAway: @escaping @Sendable () -> Bool, liveness: @escaping @Sendable () -> SessionLiveness, now: @escaping @Sendable () -> Date = { Date() }) }`
  - `records(_:)`: `ensureEnabledAt`; candidates created at/after `enabled_at` (asks/requests by `created_at`, stops by `stateAt`); `noteWorkAlerts`; if `isAway()` → `markWorkAlertsPushed` for candidates with `pushedAt == nil`; emit a record (id = key) for each candidate whose mark has `pushedAt != nil`, current generation, `now - pushedAt <= 7 d`; prune with `keeping` = current candidate keys. A resolved event drops out of `records` → the publisher deletes record + signal (existing path).
  - FastLane: `OwnerAwayCenter.onChange` → `nudge([.askAlert])`; session state changes already nudge `.askAlert` via `stateChangeKinds`.

- [ ] **Step 1: Write failing tests** (policy + slice with in-memory DB and fake away closure): `testAtTheMacNothingIsPublished`, `testGoingAwayPublishesTheStillOpenAsk`, `testASecondAwayPeriodDoesNotRepushTheSameAsk`, `testAWaitingOnAskSessionPushesOnlyTheAsk`, `testNeedsApprovalPushesOnlyTheRequest`, `testAStopUnder20sDoesNotPush`, `testAStopHeld20sPushes`, `testFailedPushesSessionFailed`, `testAnsweredAskDropsItsRecord`, `testAHubRestartRepublishesWithoutNewSignals` (same keys, publisher sees published names, no new signal), `testNothingBeforeEnabledAt`, `testReadyToCheckPushesAsItsAsk`, payload bodies match spec §5.2 ("Needs approval: Bash", "Finished", "Waiting for you", "Failed").
- [ ] **Step 2:** `make test-swift FILTER='WorkAlertPolicyTests|WorkAlertSliceTests'` → FAIL.
- [ ] **Step 3:** Implement; delete `AskAlertSlice.swift` and its tests; wire in `buildMobileHub` with `isAway: { [box = ownerAwayBox] in box.read() }`.
- [ ] **Step 4:** `make test-swift FILTER='WorkAlertPolicyTests|WorkAlertSliceTests|FastLaneTests|SlicePublisherTests'` → PASS.
- [ ] **Step 5:** Update `docs/features/mobile-companion.md` "Owner asks and ask alerts (B4)" → work alerts; commit `feat(mobile-hub): push every stop of work while the owner is away`.

### Task 7: Phone subscription, extension and Settings

**Files:**
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift` (register/unregister in `startTransport` ~:586 and on toggle), `WatchtowerMobile/NotifyService/NotificationService.swift`, `WatchtowerMobile/Sources/App/DeviceSettings.swift` (`newAskAlerts` → `workAlerts`, key `notifications.workAlerts` in the app-group suite, default true, migrate old key value), `WatchtowerMobile/Sources/Features/Settings/SettingsView.swift:240`
- Create: `WatchtowerMobile/Sources/App/Hubs/AlertSubscriptionRegistrar.swift`
- Test: `WatchtowerMobile/Tests/AlertSubscriptionTests.swift`, `WatchtowerMobile/Tests/SettingsWiringTests.swift`

**Interfaces:**
- Produces:
  - `protocol SubscriptionSaving { func save(_ s: CKSubscription) async throws; func delete(id: CKSubscription.ID) async throws }` (live = private `CKDatabase`; fake in tests).
  - `@MainActor final class AlertSubscriptionRegistrar { init(hubID: String, scope: CloudDatabaseScope, saver: SubscriptionSaving); func apply(enabled: Bool) async }` — `.private` saves `AskAlertSubscription.subscription(for:hubID:)` (idempotent by ID), `.shared` does nothing; disabled deletes.
  - Extension: fills `title`/`body` from `WorkAlertPayload`, `threadIdentifier = "session-<id>"` (or `"workbench-<id>"`), `userInfo = ["wt_hub": hubID, "wt_event": event, "wt_key": key, "wt_session": sessionID?, "wt_ask": askID?]`; generic body on any failure.
  - Settings Notifications section: one toggle **"When work stops"** with footer "Asks, approvals and finished or failed sessions, only while you're away from your Mac."; in shared scope an extra footer line "Alerts may be late on this phone."

- [ ] **Step 1:** Failing tests: `testPrivateScopeSavesTheSubscriptionOnce`, `testTurningOffDeletesIt`, `testSharedScopeSavesNothing`, `testOldNewAsksValueCarriesOver`, Settings rows/footers.
- [ ] **Step 2:** `make mobile-test MOBILE_FILTER='AlertSubscriptionTests|SettingsWiringTests'` → FAIL.
- [ ] **Step 3:** Implement. The extension's fill logic is a pure Kit helper so it is testable outside the extension: `public struct WorkAlertContent: Equatable { title, body, threadID: String, userInfo: [String: String] ; public init(payload: WorkAlertPayload, hubID: String) }` in `WatchtowerKit/Sources/WatchtowerSync/Secure/WorkAlertContent.swift`; the extension copies its fields onto the mutable content. Test: `WatchtowerKit/Tests/WatchtowerSyncTests/WorkAlertContentTests.swift` (`make kit-test FILTER=WorkAlertContentTests`), one case per event plus the thread id rule.
- [ ] **Step 4:** Tests PASS; `make mobile-build`; `make lint-swift`.
- [ ] **Step 5:** Guide `docs/guide/features/iphone.md` (notifications section) + `reference/settings.md`; commit `feat(mobile): register the work-alert subscription and fill all four events`.

### Task 8: Tap routing and clearing resolved notifications

**Files:**
- Create: `WatchtowerMobile/Sources/App/NotificationRouter.swift`
- Modify: `WatchtowerMobile/Sources/App/WatchtowerMobileApp.swift` (`AppDelegate` becomes `UNUserNotificationCenterDelegate`), `WatchtowerMobile/Sources/App/AppRoot.swift` (`open(_ destination:)` next to `openNow()` ~:927), fetch completion in `HubSession.handlePush`/foreground fetch
- Test: `WatchtowerMobile/Tests/NotificationRouterTests.swift`

**Interfaces:**
- Produces:
  - `enum AlertDestination: Equatable { case ask(hubID: String, askID: Int64), session(hubID: String, sessionID: Int64) }`, `static func destination(userInfo: [AnyHashable: Any]) -> AlertDestination?` (ask event → ask; others → session).
  - `AppRoot.open(_ destination: AlertDestination)` — switches the active hub if needed, selects the Workbench tab and pushes `AskRoute`/`SessionRoute`.
  - `enum ResolvedAlerts { static func keysToRemove(delivered: [String: String] /* id → wt_key */, snapshot: WorkbenchReplicaSnapshot) -> [String] }` — ask not open, request not pending, session working again or a newer `stateAt`; the app removes those via `removeDeliveredNotifications(withIdentifiers:)` after each fetch.
- [ ] **Step 1:** Failing tests for `destination(userInfo:)`, routing (hub switch + route), `keysToRemove` per event.
- [ ] **Step 2:** `make mobile-test MOBILE_FILTER=NotificationRouterTests` → FAIL.
- [ ] **Step 3:** Implement; foreground presentation = `.banner, .sound` unless the target screen is open.
- [ ] **Step 4:** PASS; lint.
- [ ] **Step 5:** Commit `feat(mobile): open the right screen from an alert and clear resolved ones`.

### Task 9: Keep the Mac awake

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/KeepAwakePolicy.swift`, `WatchtowerDesktop/Sources/Services/MobileHub/MacAwakeAssertion.swift`
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/HubSyncState.swift` (`hub_meta` key `last_phone_contact`), `RelayProcessor` (stamp on every admitted action and on a `device` record read), `WatchtowerDesktop/Sources/Views/Settings/MobileSettingsView.swift` + `MobileSettingsViewModel` (toggle under `toggleSection`), `WatchtowerDesktop/Sources/WatchtowerCore/Utilities/Constants.swift` (`mobileKeepAwakeKey = "mobileKeepAwake"`)
- Modify (phone): `WatchtowerMobile/Sources/App/Hubs/HubSession.swift` — on foreground, rewrite this phone's `device` record when the last write is older than 1 h (Kit `DevicePayload` gains optional `seen_at`, written only when set)
- Test: `WatchtowerDesktop/Tests/Core/KeepAwakePolicyTests.swift`, `WatchtowerDesktop/Tests/MobileHub/MacAwakeAssertionTests.swift`, `WatchtowerMobile/Tests/HubBootTests.swift` (touch cadence)

**Interfaces:**
- Produces: `package enum KeepAwakePolicy { package static let contactWindow: TimeInterval = 86_400; package static func shouldHold(enabled: Bool, liveBoardSessions: Int, lastPhoneContact: Date?, now: Date) -> Bool }`; `@MainActor final class MacAwakeAssertion { init(power: PowerAsserting = IOKitPower()); func update(hold: Bool) }` with `protocol PowerAsserting { func create(reason: String) -> UInt32?; func release(_ id: UInt32) }`, reason "Watchtower: a session is running and your iPhone is connected". Evaluated on the publisher's full tick.
- [ ] **Step 1:** Failing tests: policy truth table (off, no session, contact 24h+1s, hold); assertion created once, released once, re-created after release.
- [ ] **Step 2–4:** `make test-swift FILTER='KeepAwakePolicyTests|MacAwakeAssertionTests|MobileSettingsViewModelTests'`, `make mobile-test MOBILE_FILTER=HubBootTests` FAIL → implement → PASS; lint.
- [ ] **Step 5:** Guide (`iphone.md`, `settings.md`: "Keep this Mac awake for the iPhone", note lid-closed on battery not covered); commit `feat(mobile-hub): keep the Mac awake while a session runs and the phone is in touch`.

**Phase B gate (controller):** `make test-swift`, `make kit-test`, `make mobile-test`, `make lint-all`.

**Dependencies:** Task 1 none; Task 2 on 1. Tasks 3, 4, 5, 9 none; Task 6 on 3, 4, 5; Task 7 on 5 and 2; Task 8 on 7. Tasks 10, 11 none; Task 12 on 11 and 2; Task 13 on 12. Tasks 14–17 on 2 (and 14/15 after 12–13, which build the workchat, Now and sessions screens new). Phase B and the hub halves of Phase C (Tasks 10, 11) run in parallel with Phase A; independent tasks run in parallel lanes, each in its own worktree.

---

## Phase C — workchat (spec §5.3–§5.6)

### Task 10: Near-live chat lane

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/SessionChatRunner.swift` (`Timing.standard.every` 10 → 3 s; `onChange: (@Sendable () -> Void)?` fired when a fetch changes a payload), `.../SlicePublisher.swift` (`urgentKinds` += `.sessionChat`, placed after the ask kinds in `publishOrder`), `AppState+MobileHub.swift` (runner `onChange` → `publisher?.nudge(kinds: [.sessionChat])`), `SessionChatSlice.swift` doc
- Test: `WatchtowerDesktop/Tests/MobileHub/SessionChatRunnerTests.swift` (`testNotUrgent` → `testUrgentAfterTheAskKinds`; `testLiveSessionRefreshesEvery10s` → `…Every3s`; new `testAChangedFeedNudgesTheChatKind`, `testAnUnchangedFeedDoesNotNudge`), `SlicePublisherTests` (`testAsksPublishBeforeChat`)
- Docs: `docs/features/session-chat-feed.md` (~40 s → ~5 s, Lifetime paragraph), Kit `SessionChat.live` comment.
- [ ] Steps 1–5 as usual: tests FAIL → implement → `make test-swift FILTER='SessionChatRunnerTests|SessionChatSliceTests|SlicePublisherTests|FastLaneTests'` PASS → commit `feat(mobile-hub): near-live session chat while a phone watches`.

### Task 11: PROJ-16 send while busy

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/Handlers/SessionInputHandlers.swift` (`verdict` ~:283: `kind == .claude ? control.workchatLineCheck : control.lineCheck`; applied result gains `while_busy: true` when `control.isWorking(sessionID)` at submit)
- Modify: `docs/inventory/workbench.md` PROJ-16 (heading "only while the agent is idle" → "while the agent is idle, or working for a Claude session", condition (2), the "why locked" line, an "Amended 2026-10-25 (ask #614)" paragraph, line ~82 and ~2160 restatements), `docs/features/mobile-companion.md:425-434`, `docs/features/session-chat-feed.md:81`
- Test: `WatchtowerDesktop/Tests/MobileHub/SessionInputHandlersTests.swift`, `WatchtowerDesktop/Tests/SessionControlTests.swift`

**Interfaces:**
- Produces: applied echo `{delivery: "submitted", while_busy: true}` (Kit `SessionInputResult` gains optional `whileBusy`).
- Guard changes (owner-approved amendment, ask #614 — do not weaken the others): replace `testProj16_AWorkingSessionHoldsTheLineUntilItStops` with `testProj16_AWorkingClaudeSessionTakesTheLineButNeverAPrompt` (working → submitted; then a `needsApproval` state → next line held `needs_approval`) and add `testProj16_AWorkingCodexSessionStillHoldsTheLine`; `SessionControlTests.testPhoneLineCheckStillHoldsWhileWorking` stays (it tests `lineCheck`, still used for Codex) with its doc comment updated.
- [ ] Steps 1–5: tests FAIL → implement → `make test-swift FILTER='SessionInputHandlersTests|SessionControlTests'` PASS → commit `feat(mobile-hub): a phone line reaches a working Claude agent (PROJ-16 amended)`.

### Task 12: One workchat screen on the phone

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Workbench/WorkchatView.swift`, `WorkchatModel.swift` (pure) (the composer is Task 2's `WorkchatComposerBar`; `TellSessionBar.swift` is deleted)
- Modify: `SessionChatView.swift` (kept for subagent chats only; main-chat path removed), `SessionDetailView.swift` (becomes `SessionReportView` reached from the actions menu "Report and timeline"), `SessionInputSender.swift` (`SessionInputModel.footnote` and held texts), navigation destinations in `WorkbenchListView.swift:31-36`, `NowView.swift:48-53` (`SessionRoute` → `WorkchatView`)
- Test: `WatchtowerMobile/Tests/WorkchatWiringTests.swift` (new), update `SessionChatWiringTests`, `SessionDetailWiringTests`, `SessionInputWiringTests`, `ScreenshotTourTests` sources

**Interfaces:**
- Consumes: `SessionChatRequester` (starts on appear, stops on disappear), `SessionRowModel`, `PermissionCardModel`, `SessionActionsModel`, `SessionInputModel`, Task 11 `whileBusy`.
- Produces: `struct WorkchatModel: Equatable { init(session: TerminalSessionState, chat: SessionChat?, snapshot: WorkbenchReplicaSnapshot, input: SessionInputModel, permission: PermissionCardModel?, macOnline: Bool, now: Date); stateLine: StateLine /* glyph, tone, caption, timer "m:ss" from stateAt while working */; entries: [SessionChat.Entry]; inlineAsks: [WaitingCardModel] /* the session's open asks, as SessionDetailModel.asks builds them today */; permission: PermissionCardModel?; composer: ComposerState }` with `enum ComposerState: Equatable { case hidden(SessionInputModel.TypingHint?), ready(footnote: String?), approval(String), macAway(String) }`.
- Copy (exact): composer placeholder "Message the session…"; footnote removed for Claude, "Delivered when the agent stops" for Codex; sent-while-busy caption "Queued · the agent reads it at its next step"; held captions unchanged except `.agentBusy` → "Queued · sends when the agent stops"; waiting copy unchanged ("Asking your Mac…", "Your Mac has not sent this chat yet. Is it awake?").
- Layout (mockups 3, 4, 8; built on the Task 2 parts `StateLine`, `ChatBubble`, `InlinePermissionCard`, `InlineAskCard`, `WorkchatComposerBar`): header (title, workbench, state line), feed, inline permission card and open asks at the bottom of the feed, composer pinned; actions menu: Stop, Finish, Interrupt, Report and timeline, Open board target.
- [ ] **Step 1:** Failing tests: `testOpeningTheSessionStartsTheChatWatch`, `testStateLineShowsTimerWhileWorking`, `testPermissionCardSitsAboveTheComposer`, `testOpenAsksShowInline`, `testSentWhileBusyShowsQueuedCaption`, `testCodexKeepsTheIdleFootnote`, `testSubagentScreenHasNoComposer`, `testReportIsReachableFromTheMenu`, plus the existing "no transcript" guards kept.
- [ ] **Step 2–4:** `make mobile-test MOBILE_FILTER='WorkchatWiringTests|SessionChatWiringTests|SessionDetailWiringTests|SessionInputWiringTests|PermissionCardTests'` FAIL → implement → PASS; lint.
- [ ] **Step 5:** Demo seed: add a `session_chat` record for working session 10 and a typing grant so the composer shows in the demo (`DemoSeed+SessionDetail.swift`); guide; commit `feat(mobile): one workchat screen with state line and composer`.

### Task 13: Now, sessions order and honest staleness

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Now/NowModel.swift`, `NowView.swift`, `Features/Workbench/WorkbenchView.swift`, `WorkbenchModels.swift`, `Features/Settings/MacStatusRow.swift` (reuse status for the chip)
- Uses: Task 2 `MacStatusChip` (feeds it `MacReachability`), `StateLine`, `SectionHeader`; layout per mockups 1 (Now) and 2 (sessions).
- Test: `WatchtowerMobile/Tests/NowWiringTests.swift`, `WatchtowerMobile/Tests/WorkbenchSessionsOrderTests.swift` (new), `WorkchatWiringTests`

**Interfaces:**
- Produces: `enum MacReachability: Equatable { case online, asleep(lastSeen: Date), offline }` from the heartbeat (online < 2100 s, asleep = older heartbeat on a still-linked hub, offline = no heartbeat/unlinked) — `static func of(heartbeat: Date?, linked: Bool, now: Date)`; Now sections `waitingForYou` (asks, requests, stopped/failed sessions, newest first, 20 shown), `working` (live working sessions with timers), `nextMeeting`; workbench sessions order = Desktop sessions panel (Waiting for you, Agents working/Working, Ready to check, then "▸ N finished" collapsed).
- [ ] **Step 1:** Failing tests incl. `testAStaleHeartbeatShowsMacAsleepAndHoldsTheComposerCaption` (composer line reads "Waiting for your Mac"), `testStoppedAndFailedSessionsAreWaitingForYou`, `testSessionsFollowTheDesktopPanelOrder`.
- [ ] **Step 2–5:** `make mobile-test MOBILE_FILTER='NowWiringTests|WorkbenchSessionsOrderTests|WorkchatWiringTests'` FAIL → implement → PASS → guide → commit `feat(mobile): Now leads with waiting work; Mac asleep is shown`.

**Phase C gate (controller):** `make test`, `make test-swift`, `make lint-all`, `make mobile-test`; then a device smoke checklist as a `kind: check` ask (pushes on private scope, tap routing, ~5 s chat latency measured and reported, send while busy, keep-awake assertion visible in `pmset -g assertions`).

---

## Phase D — the other screens, to the approved mockups

Each task: rebuild the listed screens on the Task 2 parts so they match the named mockups; no behaviour change; before/after shots (`make mobile-shots`) next to the mockup in the PR body; `make mobile-test MOBILE_FILTER=<the screens' wiring tests>`; `make lint-swift`; guide wording in `docs/guide/features/iphone.md` where it describes the screen; commit `feat(mobile): <area> in the new design`. Screens without a mockup (Macs, hub switcher, event detail, recordings list, question ask full screen, boot and failure screens, empty states) take the nearest mockup's parts.

### Task 14: Workbench list, board (mockup 5), target detail (9), New session (12), New target sheet
Tests: `BoardModelTests`, `BoardWriteWiringTests`, `StartSheetWiringTests`. (Now and sessions are built new in Task 13.)

### Task 15: Ask views — review (10), check (11), question (full-screen form of mockup 4's inline ask); report and timeline (13); subagent chat
Tests: `AskFormTests`, `SessionDetailWiringTests`. (Workchat and the permission card are built new in Task 12.)

### Task 16: Calendar agenda (7), event detail, recorder (14), recordings list, recap (15)
Tests: `CalendarWiringTests`, `RecordingsWiringTests`, `RecorderTests`.

### Task 17: Settings (16), Macs, hub switcher, linking (17) and onboarding, boot/failure screens, demo banner
Tests: `SettingsWiringTests`, `MacsModelTests`, `HubSwitcherTests`, `LinkingViewModelTests`.

**Final gate (controller):** full `make test`, `make test-swift`, `make lint-all`, `make mobile-test`, `go test ./docs/guide`; `docs/features/mobile-companion.md` "Design layer" rewritten and the 2026-10-11 design-pass spec marked superseded; `debate-review` on the branch; PR into `main`.
