# Home Zones Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Home's Today card grid with zones — the feed (waiting on you / NOW / later today / next day) with Open · Done · Hide, Workbench, links and today in numbers.

**Architecture:** WatchtowerCore gets pure readers and builders per zone (`HomeFeedQueries` + `HomeFeedBuilder`, `HomeWorkbenchBuilder`, `HomeLinksBuilder`, `HomeNumbersQueries`), tested in `Tests/Core`. `HomeCenter` keeps its observation + 30 s tick and builds a `HomeSnapshot` that now carries zones instead of `[TodayCard]`. Views are value-and-closure views (ViewInspector-testable) under `Views/Home/`. Feed writes: inbox items through the Go CLI (`watchtower inbox resolve|dismiss <id>`), reminders and targets through GRDB.

**Tech Stack:** Swift 5.10 language mode, SwiftUI macOS 14, GRDB, XCTest + ViewInspector; Go only for docs/inventory (no Go code change).

**Spec:** `docs/superpowers/specs/2026-10-19-home-zones-design.md` (§§1–8, 10–11; §9 Learn is #718, a separate plan). Mockups: `docs/superpowers/specs/2026-10-19-home-zones-mockups.html`.

## Global Constraints

- UI text is English only (repo rule); board/asks are Russian.
- Feed window: inbox rows with `MAX(created_at, mentioned_at)` within the last **72 h**; at most **7** rows above NOW; "N more" expands in place.
- Feed inbox triggers: `mention`, `dm`, `thread_reply`, `reaction`, `jira_assigned`, `jira_comment_mention`, `email_received`; `status = 'pending'`, `item_class = 'actionable'`, not snoozed (`snooze_until = '' OR snooze_until <= now`).
- Kind order above NOW: Slack (mention/dm/thread_reply/reaction) → Jira → proposal → reminder → target → email; newest first within a kind. `priority` is never used.
- `read_at` never hides a row; a read row renders secondary.
- Next day: the first day after today with calendar events, within 3 days; meetings only, ≤ 3 rows; title "Tomorrow" when it is tomorrow, else the weekday ("Monday").
- Events: no all-day, no `event_status = 'cancelled'`, none the owner declined (an attendee whose email equals the event's `accountEmail` with `responseStatus == "declined"`).
- PROJ-01: no workbench target (`project_id IS NOT NULL`) ever reaches Home.
- Two columns at ≥ 900 pt content width (feed ≈ 60 %); one column below, order feed, Workbench, links, numbers.
- No migration in this plan. No AI. No new daemon phase.
- Tests: Core logic in `Tests/Core` (`make test-swift FILTER=…`); `swiftlint` on touched Swift (`make lint-swift`) — `make lint-diff` does not lint Swift.

## Review Focus

1. **Midnight and the clock.** Home left open across midnight must move "later today" to yesterday-gone, the next day to today, and the 72 h window forward without a DB change — the builders take `now`; `HomeCenter`'s tick re-reads. Test: `HomeFeedBuilderTests.testMidnightRollsTheNextDayIntoToday` (Task 3).
2. **A write from another process meanwhile.** The daemon auto-resolves an item (INBOX-02) while the owner presses Done on it; the CLI then reports success or "not found" — both must leave the row gone, never an error banner. Test: `HomeFeedActionTests.testDoneOnAnAlreadyResolvedItemIsQuiet` (Task 4).
3. **A huge backlog.** Hundreds of pending emails older than 72 h must cost nothing and show nothing: the query filters in SQL, not in Swift. Test: `HomeFeedQueriesTests.testOldBacklogStaysOutAndCountIsBounded` (Task 2).
4. **A table missing mid-migration or one failing read.** One feed source failing marks only that part failed and is never the all-clear "Nothing is waiting for you." Test: `HomeFeedQueriesTests.testOneFailingSourceMarksOnlyItself` (Task 2) and `HomeFeedBuilderTests.testFailedSourceIsNeverAllClear` (Task 3).
5. **The CLI is missing or fails.** Done/Hide on an inbox row with no CLI, or a non-zero exit, brings the row back with a one-line error under it. Test: `HomeFeedActionTests.testCLIFailureBringsTheRowBack` (Task 4).

---

# PR 1 — layout, feed, actions

### Task 1: Feed model

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/HomeFeed.swift`
- Test: compiled through Tasks 2–3 (no test of its own)

**Interfaces:**
- Produces:
  - `package enum FeedKind: Int, Comparable, Sendable { case slack, jira, proposal, reminder, target, email }` — the raw value is the kind order.
  - `package enum FeedRef: Hashable, Sendable { case inbox(Int), reminder(Int64), proposal(Int64), target(Int), event(String) }`
  - `package enum FeedAction: Sendable { case done, hide }`
  - `package struct FeedRow: Equatable, Identifiable, Sendable { id: FeedRef; kind: FeedKind; chip: String; who: String; whereText: String?; text: String; stamp: Date; read: Bool; actions: Set<FeedAction>; link: HomeLink }` — `chip` ∈ "Mention", "DM", "Thread", "Reaction", "Jira", "Proposal", "Failed", "Reminder", "Overdue", "Due", "Email".
  - `package struct FeedEvent: Equatable, Identifiable, Sendable { id: FeedRef; start: Date; end: Date; title: String; chip: String; prepReady: Bool; isNext: Bool; isOngoing: Bool; link: HomeLink }` — rows below NOW (events, timed targets, later reminders); `chip` ∈ "Meeting", "in N min", "until HH:mm", "Due", "Reminder".
  - `package enum FeedSource: Hashable, Sendable { case inbox, reminders, proposals, targets, calendar }`
  - `package struct FeedDay: Equatable, Sendable { title: String; events: [FeedEvent] }`
  - `package struct HomeFeed: Equatable, Sendable { waiting: [FeedRow]; hiddenWaiting: Int; nowLabel: String; ongoing: FeedEvent?; laterToday: [FeedEvent]; nextDay: FeedDay?; failed: Set<FeedSource> }`
  - `HomeLink` gains `case permalink(URL)` (Slack/mail/Jira open) and `case reminders` (Inbox tab; reuse `.inbox` — only add `permalink`).

- [ ] **Step 1: Add the types above** with `package init`s, following `Home.swift`'s style (doc comment per type).
- [ ] **Step 2: Build** — `cd WatchtowerDesktop && swift build --target WatchtowerCore` → succeeds.
- [ ] **Step 3: Commit** — `feat(home): feed model types (#717)`.

### Task 2: Feed read

**Depends on:** Task 1

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/HomeFeedQueries.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ReminderQueries.swift` (add `fetchPending(_:fromUTC:toUTC:)`)
- Test: `WatchtowerDesktop/Tests/Core/HomeFeedQueriesTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `AgentActionQueries.awaitingOwner(_:limit:)`, `ReminderQueries.fetchDue(_:nowUTC:)`, `CalendarQueries.fetchEvents(_:from:to:)`, `CalendarQueries.hasPrep(_:eventID:)`, `UserQueries.fetchByID`, `ChannelQueries.fetchByID`, `InboxItem.mentionSendersLabel(names:)`.
- Produces:
  - `package struct HomeFeedData: Equatable, Sendable { inbox: [HomeFeedInboxRow]; dueReminders: [Reminder]; laterReminders: [Reminder]; proposals: [AgentAction]; targets: [Target]; events: [CalendarEvent]; prepEventIDs: Set<String>; failed: Set<FeedSource> }`
  - `package struct HomeFeedInboxRow: Equatable, Sendable { item: InboxItem; stamp: Date; who: String; whereText: String? }`
  - `package enum HomeFeedQueries { package static let observedTables: [String]; package static func read(_ db: Database, now: Date, calendar: Calendar) -> HomeFeedData }`
  - `ReminderQueries.fetchPending(_ db: Database, fromUTC: String, toUTC: String) throws -> [Reminder]` — pending, `remind_at > fromUTC AND remind_at <= toUTC`, by `remind_at`.

Source rules (each source read on its own, same `readCard`-style catch as `HomeQueries.today`: a missing table = empty, a throw = logged + `failed.insert`):
- inbox: the Global Constraints filter in SQL, `ORDER BY MAX(created_at, mentioned_at) DESC LIMIT 200`. `who`/`whereText`: Slack — sender `bestName` (accumulated item: `mentionSendersLabel`) and `#channel`; email — `sender_user_id` (the from address) and the subject (`snippet` up to " — "); Jira — `whereText` = nil, `who` = `channel_id` (the issue key), plus "assigned to you" / "mentioned you" as `whereText`.
- proposals: `awaitingOwner(db, limit: 7)`.
- targets: `homeSummary`'s WHERE without the `OR status = 'in_progress'` arm — overdue or due today (date part ≤ today), limit 7; PROJ-01 clause kept verbatim.
- events: `fetchEvents(from: startOfDay(now), to: startOfDay(now) + 4 days)`; `prepEventIDs` from `hasPrep` for the events still to start today and on the next day only.
- reminders: due = `fetchDue(nowUTC)`, later = `fetchPending(fromUTC: now, toUTC: end of today)`.

- [ ] **Step 1: Write the failing tests** in `HomeFeedQueriesTests` (fixtures in the style of `HomeQueriesTests`: `TestDatabase.create()`, raw inserts):
  - `testInboxWindowIs72Hours` — items at 71 h and 73 h ago: only the first returned.
  - `testOnlyActionablePendingFeedTriggers` — one each of `mention`, `email_cc`, `briefing_ready`, `calendar_invite`, a `resolved` mention, an `ambient` mention, a snoozed-until-tomorrow dm: only the plain `mention` returned.
  - `testMentionedAtCountsAsTheStamp` — `created_at` 5 days ago, `mentioned_at` 1 h ago: returned, `stamp` = mentioned_at.
  - `testOldBacklogStaysOutAndCountIsBounded` — 500 emails 10 days old + 3 fresh: `inbox.count == 3`.
  - `testProj01_FeedNeverReturnsAProjectTarget` — a `project_id = 1` overdue target: absent (PROJ-01).
  - `testInProgressWithoutDueIsNotATargetRow` — absent.
  - `testOneFailingSourceMarksOnlyItself` — drop `reminders` mid-test via a `CREATE VIEW reminders AS SELECT 1/0` swap (or the failure technique `HomeQueriesTests.testOneFailingCardKeepsTheOthers` uses): `failed == [.reminders]`, inbox still read.
  - `testSlackWhoAndWhere` — user `Ann` in `#eng`: `who == "Ann"`, `whereText == "#eng"`.
- [ ] **Step 2: Run** `make test-swift FILTER=HomeFeedQueriesTests` → FAIL (no `HomeFeedQueries`).
- [ ] **Step 3: Implement** `HomeFeedQueries.read` and `ReminderQueries.fetchPending` per the rules above. `observedTables` = `["inbox_items", "reminders", "agent_actions", "targets", "calendar_events", "calendar_calendars", "google_accounts", "meeting_prep_cache"]`.
- [ ] **Step 4: Run** `make test-swift FILTER=HomeFeedQueriesTests` → PASS.
- [ ] **Step 5: Commit** — `feat(home): feed read (#717)`.

### Task 3: Feed builder

**Depends on:** Task 1 (Task 2's `HomeFeedData` type)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/HomeFeedBuilder.swift`
- Test: `WatchtowerDesktop/Tests/Core/HomeFeedBuilderTests.swift`

**Interfaces:**
- Consumes: `HomeFeedData`.
- Produces: `package enum HomeFeedBuilder { package static let waitingLimit = 7; package static let nextDayHorizonDays = 3; package static func feed(_ data: HomeFeedData, now: Date, calendar: Calendar, expanded: Bool, hidden: Set<FeedRef>) -> HomeFeed }` — `hidden` = rows the owner just pressed Done/Hide on (optimistic, Task 4).

Rules: waiting = inbox + due reminders + proposals + overdue/due-today-without-time-or-past targets, minus `hidden`, sorted by `FeedKind` then `stamp` DESC (reminders by `remind_at`, targets by due date); `expanded == false` keeps the first 7 and sets `hiddenWaiting`. Actions: inbox/reminder/target → `[.done, .hide]`, proposal → `[]`. Proposal chip "Failed" when `status == "failed"`. Below NOW: today's events not yet ended (an event with `start ≤ now < end` is `ongoing`, chip "until HH:mm"), targets due later today with a time (chip "Due"), later reminders (chip "Reminder"); by start; the first upcoming event `isNext`, chip "in N min" under 60 min. `nowLabel` = "HH:mm". Next day per Global Constraints.

- [ ] **Step 1: Write the failing tests** (fixed `now` = 10:40 local on a Tuesday, like `HomeTodayTests`' fixed morning):
  - `testKindOrderThenNewest` — email 5 min ago, mention 2 h ago, reminder due, target overdue, proposal: order mention, proposal, reminder, target, email.
  - `testCapAtSevenAndNMore` — 10 rows: `waiting.count == 7`, `hiddenWaiting == 3`; `expanded: true` → 10 and 0.
  - `testHiddenRefsLeave` — `hidden: [.inbox(4)]` drops item 4.
  - `testReadRowIsKeptAndMarked` — `read_at` set → present, `read == true`.
  - `testProposalHasNoActions`.
  - `testOngoingMeetingSitsOnNow` — 10:00–11:00 → `ongoing` chip "until 11:00", not in `laterToday`.
  - `testNextMeetingInMinutes` — 11:00 → `isNext`, chip "in 20 min".
  - `testAllDayCancelledDeclinedLeftOut` — three events, none shown.
  - `testTomorrowNeverUnderToday` — the AI-9 case: `now` = Sunday 21:10, only event Monday 09:30 → `laterToday` empty, `nextDay?.title == "Tomorrow"`.
  - `testFridayEveningShowsMonday` — Friday 20:00, events only Monday → `nextDay?.title == "Monday"`; only Thursday next week → `nextDay == nil`.
  - `testNextDayMeetingsOnlyMaxThree` — 5 meetings + a reminder tomorrow → 3 events, no reminder.
  - `testMidnightRollsTheNextDayIntoToday` — same data, `now` 23:59 vs 00:01 next day: the 09:30 meeting moves from `nextDay` to `laterToday`.
  - `testFailedSourceIsNeverAllClear` — `failed: [.inbox]`, no rows → `feed.failed == [.inbox]` (the view shows the error, not the all-clear).
- [ ] **Step 2: Run** `make test-swift FILTER=HomeFeedBuilderTests` → FAIL.
- [ ] **Step 3: Implement** `HomeFeedBuilder.feed` (pure; English POSIX formatting via the same `format(_:_:_:)` helper shape as `HomeTodayBuilder`).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(home): feed builder (#717)`.

### Task 4: Feed actions

**Depends on:** Tasks 1–3

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/HomeFeedActions.swift`
- Modify: `WatchtowerDesktop/Sources/Services/HomeCenter.swift` (hidden set, expanded flag, per-row error)
- Modify: `WatchtowerDesktop/Sources/App/AppState+Home.swift` (wire the performer)
- Test: `WatchtowerDesktop/Tests/HomeFeedActionTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor protocol HomeFeedPerforming { func perform(_ action: FeedAction, on ref: FeedRef, now: Date, calendar: Calendar) async throws }`
  - `@MainActor final class LiveHomeFeedPerformer: HomeFeedPerforming { init(runner: (any CLIRunnerProtocol)?, pool: DatabasePool) }` — inbox done → `runner.run(args: ["inbox", "resolve", "\(id)"])`, hide → `["inbox", "dismiss", "\(id)"]`; no runner → throws `HomeFeedActionError.cliUnavailable`; reminder done → `ReminderQueries.markDone`, hide → `ReminderQueries.snooze(until: tomorrow 09:00 local as UTC ISO)`; target done → `TargetQueries.updateStatus(id:status: "done")`, hide → `TargetQueries.snooze(id:until: tomorrow)`; proposal/event → no-op.
  - `HomeCenter`: `func act(_ action: FeedAction, on ref: FeedRef) async`, `func setFeedExpanded(_ on: Bool)`, `private(set) var feedErrors: [FeedRef: String]` (observable). `act` inserts `ref` into the hidden set, rebuilds, awaits the performer; on throw removes `ref`, sets `feedErrors[ref]`, rebuilds; on success `rereadNow()` and drops `ref` from the hidden set once the re-read no longer returns it.
  - `HomeCenter.init` gains `performer: any HomeFeedPerforming`.

Classify "already gone": a CLI non-zero exit whose stderr contains "not found" (Go's `ResolveInboxItem`/`DismissInboxItem` wrap `sql.ErrNoRows`) is success — verify the exact wording in `internal/db` while implementing and pin it in the test.

- [ ] **Step 1: Write the failing tests** (`HomeCenterTests`-style fixture with a fake performer and a temp `DatabasePool`):
  - `testDoneHidesAtOnceThenStaysGone` — row present → `act(.done, .inbox(1))` → snapshot has no row 1 before the performer returns.
  - `testCLIFailureBringsTheRowBack` — performer throws → row back, `feedErrors[.inbox(1)]` set.
  - `testDoneOnAnAlreadyResolvedItemIsQuiet` — live performer with a fake runner exiting 1 and "not found" → no error, row gone.
  - `testInboxDoneRunsResolve` — fake runner records `["inbox", "resolve", "1"]`; hide records `dismiss`.
  - `testReminderHideSnoozesToTomorrowNine` — reminder `remind_at` = tomorrow 09:00 local in UTC.
  - `testNoCLIIsAnError` — runner nil → `cliUnavailable`.
- [ ] **Step 2: Run** `make test-swift FILTER=HomeFeedActionTests` → FAIL.
- [ ] **Step 3: Implement** `LiveHomeFeedPerformer`, `HomeCenter.act`/`setFeedExpanded`/`feedErrors`; `AppState` builds the performer with `ProcessCLIRunner.makeDefault()` and `databaseManager.dbPool` where it builds `homeCenter`.
- [ ] **Step 4: Run** → PASS; also `make test-swift FILTER='HomeCenterTests|HomeCenterSurvivesNavigationTests'` → PASS.
- [ ] **Step 5: Commit** — `feat(home): Done and Hide from the feed (#717)`.

### Task 5: Snapshot and center wiring

**Depends on:** Tasks 2–4

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/Home.swift` (`HomeSnapshot`)
- Modify: `WatchtowerDesktop/Sources/Services/HomeCenter.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/HomeQueries.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/HomeTodayBuilder.swift`, `WatchtowerDesktop/Sources/App/AppState+Home.swift`
- Test: `WatchtowerDesktop/Tests/HomeCenterTests.swift`, `WatchtowerDesktop/Tests/Core/HomeTodayTests.swift`, `WatchtowerDesktop/Tests/Core/HomeQueriesTests.swift`

**Interfaces:**
- Produces: `HomeSnapshot` gains `feed: HomeFeed`; `today: [TodayCard]` stays for the cards the right column still shows in PR 1 (since you were away, briefing, agents waiting, instruction suggestion). `TodayCardKind` loses `.nextMeeting`, `.waitingOnYou`, `.myTargets`; `HomeTodayData` loses their fields; `homeCardTabs` loses `.nextMeeting`/`.waitingOnYou` (the feed's inbox/calendar parts follow tab visibility instead: inbox rows only while attention detection is on — `featureVisibility` has `secretary-inbox` — calendar rows only while the Calendar tab is visible; `HomeEnvironment` gains `feedSourcesAllowed: Set<FeedSource>`).
- `HomeCenter.reread` reads `HomeQueries.today` and `HomeFeedQueries.read` in one `pool.read`; the observation region adds `HomeFeedQueries.observedTables`.
- `nothingNeedsYou` keeps its meaning for the right-column cards; the feed's own empty line comes from `HomeFeed`.

- [ ] **Step 1: Update tests first**: delete the `HomeTodayTests` cases for the three removed kinds; add `HomeCenterTests.testFeedIsInTheSnapshot` (an inbox row in the DB → `snapshot.feed.waiting.count == 1`) and `testInboxRowsFollowAttentionDetection` (`feedSourcesAllowed` without `.inbox` → no inbox rows).
- [ ] **Step 2: Run** `make test-swift FILTER='HomeCenterTests|HomeTodayTests|HomeQueriesTests'` → FAIL.
- [ ] **Step 3: Implement** the snapshot/center/environment changes above.
- [ ] **Step 4: Run** the same filter → PASS.
- [ ] **Step 5: Commit** — `refactor(home): snapshot carries the feed; drop the old meeting/waiting/targets cards (#717)`.

### Task 6: Layout and feed views

**Depends on:** Task 5

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Home/FeedZoneView.swift` (zone + `FeedRowView` + `FeedEventRow` + `NowLine`)
- Modify: `WatchtowerDesktop/Sources/Views/Home/HomeView.swift` (two columns), `TodayZoneView.swift` (becomes the right column's card stack, header "Today" removed)
- Test: `WatchtowerDesktop/Tests/HomeViewTests.swift`

**Interfaces:**
- `struct FeedZoneView: View { let feed: HomeFeed; let errors: [FeedRef: String]; let onLink: (HomeLink) -> Void; let onAct: (FeedAction, FeedRef) async -> Void; let onExpand: (Bool) -> Void }`
- `HomeContent` gains `feedErrors`, `onAct`, `onExpand`; layout: `ViewThatFits(in: .horizontal)` over `HStack(alignment: .top, spacing: 20) { feed.frame(minWidth: 520) ; right.frame(width: 340) }` and a one-column `VStack`; drop the `maxWidth: 960` cap to 1180.
- Copy (exact): zone header "WAITING ON YOU · N" (no "· N" at 0), header link "Catch-Up →" (opens Catch-Up), "N more" / "Show less", empty "Nothing is waiting for you.", "Nothing else today.", failed source "Couldn't read <Slack and mail|reminders|proposals|targets|the calendar> — see the log.", row buttons "Open", "Done", "Hide".
- Row: hover shows the buttons; the row is focusable — Return = Open, ⌘Return = Done, Delete = Hide (only the actions in `row.actions`). Read row: `.secondary` foreground. NOW line: the `nowLabel` + a 1.5 pt orange rule. Styles: `HomeCardBackground`, `HomeZoneHeader`.

- [ ] **Step 1: Write the failing ViewInspector tests**: `testFeedShowsWaitingThenNowThenLater` (texts in order), `testNMoreExpands` (tap calls `onExpand(true)`), `testProposalRowHasNoDoneButton`, `testEmptyFeedLine`, `testFailedInboxShowsErrorNotAllClear`, `testTomorrowTitleNeverToday`.
- [ ] **Step 2: Run** `make test-swift FILTER=HomeViewTests` → FAIL.
- [ ] **Step 3: Implement** the views.
- [ ] **Step 4: Run** → PASS; `make lint-swift` → clean for touched files.
- [ ] **Step 5: Run the app** (`run` skill or `make run-desktop` as the repo's skill says) against a DB copy (never a repo-built CLI on the live DB — owner memory) and screenshot Home at 1280 and 800 pt wide; compare to mockup screens 1 and 4.
- [ ] **Step 6: Commit** — `feat(home): feed zone and two-column layout (#717)`.

### Task 7: PR 1 docs and gate

**Depends on:** Task 6

**Files:**
- Modify: `docs/guide/features/home.md` (the feed, NOW, Done/Hide, next day), `docs/features/first-run.md` ("Home (Desktop, P2)" → Today table rows for the three removed cards replaced by a "Feed" subsection), `docs/inventory/inbox-pulse.md` (header line: "Writers outside the detectors: Home's Done/Hide through `watchtower inbox resolve|dismiss` (owner ask #408, #717).")

- [ ] **Step 1: Edit the three docs** (guide per `docs/guide/WRITING.md`).
- [ ] **Step 2: Gate** — `make test`, `make test-swift`, `make lint-all`; record exit codes.
- [ ] **Step 3: Commit, push, open PR 1** into main.

---

# PR 2 — Workbench, links, numbers

### Task 8: Workbench zone

**Depends on:** PR 1

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/HomeWorkbenchBuilder.swift`, `WatchtowerDesktop/Sources/Views/Home/WorkbenchZoneView.swift`
- Modify: `HomeCenter.swift`/`HomeEnvironment` (`workbenchSessions: [SessionAgentStatus]` from `AppState.sessionAgentStateCenter?.statuses.values`), `Home.swift`
- Test: `WatchtowerDesktop/Tests/Core/HomeWorkbenchBuilderTests.swift`, `HomeViewTests`

**Interfaces:**
- `package struct HomeWorkbenchBlock: Equatable, Sendable { workbenchID: Int64; name: String; sessions: [SessionAgentStatus]; asks: [WorkbenchAskRow] }`
- `package enum HomeWorkbenchBuilder { package static let shownKinds: Set<SessionSwitcherPresentation.State.Kind> = [.needsApproval, .failed, .readyToCheck, .background, .working]; package static func blocks(sessions: [SessionAgentStatus], asks: WorkbenchAskRows) -> [HomeWorkbenchBlock] }` — sessions in `shownKinds` with a `workbenchID`; blocks sorted by name; sessions within a block by kind in the order above; asks oldest first.
- `HomeSnapshot` gains `workbench: [HomeWorkbenchBlock]`, `workbenchFailed: Bool` (unreadable asks), and the instruction suggestion moves into the zone (`HomeSnapshot.suggestion`).
- Labels/colours: `SessionStatePresentation.caption(for:oldestAskID:)` and `.color(for:)`. Click: session → `.workbench(WorkbenchRoute(projectID: workbenchID, pane: .terminal, subjectID: sessionID))`, ask → `.workbench(.forAsk(projectID:sessionID:askID:))` (`Workbench.swift:45`).

- [ ] **Step 1: Tests**: `testFinishedAndStoppedLeftOut`, `testBlocksByNameSessionsByKind`, `testWorkbenchWithOnlyAnAskShows`, `testNoBlocksHidesTheZone` (view), `testSuggestionIsTheLastRow` (view).
- [ ] **Step 2: Run** `make test-swift FILTER='HomeWorkbenchBuilderTests|HomeViewTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(home): Workbench zone (#717)`.

### Task 9: Links zone

**Depends on:** PR 1

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/HomeLinksBuilder.swift`, `WatchtowerDesktop/Sources/Views/Home/LinksZoneView.swift`
- Modify: `HomeQueries.swift` (read `BriefingQueries.fetchLatest`, today's `DayPlanQueries.fetchToday` + `fetchItems`), `Home.swift`, `AppState+Home.swift` (`homeLinksAllowed: Set<HomeLinkKind>` from `SidebarDestination.isVisible`)
- Test: `WatchtowerDesktop/Tests/Core/HomeLinksBuilderTests.swift`

**Interfaces:**
- `package enum HomeLinkKind: CaseIterable, Sendable { case briefing, catchUp, dayPlan, digests }`
- `package struct HomeLinkRow: Equatable, Sendable { kind: HomeLinkKind; title: String; status: String?; highlighted: Bool; link: HomeLink }`
- `package enum HomeLinksBuilder { package static func links(_ data: HomeTodayData, allowed: Set<HomeLinkKind>, now: Date, calendar: Calendar) -> [HomeLinkRow] }` — Briefing: today's → "ready HH:mm" (its `created_at` local), else latest → its weekday ("Fri"), none → nil; Catch-Up: unacknowledged ready recap → "new recap", highlighted; Day plan: today's plan → "n of m done"; Digests: nil. The "Since you were away" and "Briefing" TodayCards are removed (`TodayCardKind` keeps only `.agentsWaiting`/`.instructionSuggestion` until Task 8 removes them — delete `TodayCard`, `TodayCardView`, `HomeTodayBuilder.cards` once Tasks 8–9 land).

- [ ] **Step 1: Tests**: `testBriefingReadyTime`, `testBriefingFallsBackToLatestWeekday`, `testCatchUpBadgeOnlyWhenUnacknowledged`, `testDayPlanCounts`, `testHiddenTabLinkLeftOut`, `testNoLinksHidesZone` (view).
- [ ] **Step 2: Run** `make test-swift FILTER='HomeLinksBuilderTests|HomeViewTests'` → FAIL.
- [ ] **Step 3: Implement**; remove the leftover Today card code and tests.
- [ ] **Step 4: Run** `make test-swift FILTER='Home'` → PASS.
- [ ] **Step 5: Commit** — `feat(home): links zone; retire the Today cards (#717)`.

### Task 10: Today in numbers

**Depends on:** PR 1

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/HomeNumbersQueries.swift`, `WatchtowerDesktop/Sources/Views/Home/NumbersZoneView.swift`
- Modify: `HomeCenter.swift` (a second, separate read and observation for numbers so a sync's `messages` writes never rebuild the feed), `Home.swift`
- Test: `WatchtowerDesktop/Tests/Core/HomeNumbersQueriesTests.swift`

**Interfaces:**
- `package struct HomeNumbers: Equatable, Sendable { messagesToMe: Int?; messagesSent: Int?; meetings: Int?; meetingHours: Double?; aiSpendUSD: Double?; plan5h: Int?; planWeek: Int?; workbenchCreated: Int?; workbenchDone: Int?; meetingsRecorded: Int? }` — nil = source absent/off (left out); a failed read = the whole value `nil` plus `failed: Set<String>` of field names (rendered "—").
- `package enum HomeNumbersQueries { package static let observedTables = ["messages", "calendar_events", "pipeline_runs", "plan_usage_status", "target_status_history", "meeting_transcripts", "slack_accounts"]; package static func read(_ db: Database, now: Date, calendar: Calendar) -> HomeNumbers }`
- SQL per spec §8: to me = `messages` today, `is_deleted = 0`, `user_id NOT IN owners`, and (`channel_id` of a `channels.type IN ('dm','group_dm')` or `text LIKE '%<@' || raw_owner_id || '>%'` for any owner); sent = `user_id IN owners`; owners = `current_user_id` of `slack_accounts` with `status != 'removed'` (raw id = the part after ':'). Meetings/hours: today's events minus all-day/cancelled/declined (reuse Task 3's predicate as a `package static func isShownEvent(_:)` on `HomeFeedBuilder`), hours rounded to 0.5. AI: `TokenUsageQueries.fetchUsage(db, on: now)` total cost. Plan: `PlanUsageQueries.status` only when `state == "ok"`, the 5 h and 7 d limits' percentages. Workbench: `target_status_history` today, `from_status IS NULL` / `to_status = 'done'`. Recorded: `meeting_transcripts.created_at` today.

- [ ] **Step 1: Tests**: `testMessagesToMeCountsDMsAndMentionsNotChannelNoise`, `testSentCountsEveryOwnerAccount`, `testMeetingHoursSkipAllDayCancelledDeclined`, `testPlanLeftOutUnlessOK`, `testWorkbenchCreatedAndDone`, `testNoSlackLeavesMessagesNil`.
- [ ] **Step 2: Run** `make test-swift FILTER=HomeNumbersQueriesTests` → FAIL.
- [ ] **Step 3: Implement** the query, the separate observation in `HomeCenter`, and `NumbersZoneView` (muted: `.secondary` values, `.tertiary` captions, 2-column grid, header "TODAY IN NUMBERS").
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(home): today in numbers (#717)`.

### Task 11: PR 2 docs and gate

**Depends on:** Tasks 8–10

- [ ] **Step 1: Docs** — `docs/guide/features/home.md` (Workbench, links, numbers), `docs/features/first-run.md` Home section (zones replace Today cards; tests list), CLAUDE.md first-run index line mentions the zones.
- [ ] **Step 2: Run the app on a DB copy** and screenshot screens 1–4 of the mockups' states where data allows.
- [ ] **Step 3: Gate** — `make test`, `make test-swift`, `make lint-all`.
- [ ] **Step 4: Commit, push, open PR 2** into main.
