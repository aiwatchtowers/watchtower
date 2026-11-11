# Inbox Redesign — Phase 1 (the shell) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Inbox moves to the sidebar root and opens on what needs the owner: a three-column window (collapsible rail, a list of urgency sections with content-bearing rows, a centred reading pane that is never empty), one Morning brief row with past days inside it, counts the owner can bring to zero today (badge = Needs approval + people waiting today), and Needs approval grouped by kind with **Approve All N…**.

**Architecture:** Swift only, no migration, no Go code (one shared JSON fixture under `internal/inbox/testdata/` that phase 2's Go twin will read). Pure rules live in WatchtowerCore (`InboxToday`, `InboxRowContent` + `InboxFolderEntries.content`, `InboxRootSections`, `NeedsApprovalGroups`, `InboxBriefDays`/`InboxBriefLayout`, `InboxBulkPressModel`, the new count terms in `InboxFolderMenuSnapshot`), state stays on `ActionStripViewModel` (AppState-owned, survives navigation), the views in `Sources/Views/Inbox/` only render. `InboxFolderEntries` stays the single source of entries; sections, rows and groups are built over its output.

**Tech Stack:** SwiftUI + GRDB (WatchtowerCore), DesignKit / WatchtowerDesign tokens (Kit), XCTest + ViewInspector, DesignShotCatalog.

**Spec:** `docs/superpowers/specs/2026-11-11-inbox-redesign-design.md` (owner-approved, ask #638; inventory amendments approved in ask #634). Agreed mockup: `docs/design/mockups/inbox-redesign/inbox-redesign.html`. Read with it: `docs/features/inbox-folders.md`, `docs/features/inbox-card-blocks.md`, `docs/inventory/reaction-commands.md` (STRIP-01..03), `docs/inventory/inbox-folders.md` (APPROVAL-01, FOLDER-01), `docs/review/review-rules.md` ("Swift / Desktop conventions"), `docs/design/desktop-style-guide.md`, `docs/guide/WRITING.md`, `.claude/skills/add-desktop-feature`.

## Global Constraints

- Phase 1 is one PR into `feature/inbox-redesign`; no migration, no Go source change, no prompt, no phone change.
- "Today" = since local midnight; an item is from today when `MAX(created_at, mentioned_at)` (an empty `mentioned_at` = none) is at or after `Calendar.startOfDay(for: now)` — one rule, `InboxToday`, pinned by `internal/inbox/testdata/from_today.json`.
- Badge (sidebar) = open approvals in Needs approval (`awaitingOwnerCount` + due reminders + built-in notices, as today) + people waiting today. Mail, tracks, ideas, briefs, thread briefs and owner-folder artifacts never enter it.
- Inbox root count (rail) = people waiting today + 1 when today's brief is unread + the root's other artifacts counted as today (`InboxFolderCounts.artifactCount`), Waiting for me's own artifact excluded (its people are the first term). Owner folders count as today. Thread briefs never count.
- **Phase 1 alone (interim, stated in the PR):** Waiting for me still holds people and mail, so "people waiting today" counts every open Waiting for me item from today, mail included; there is no Mail waiting row; Track my threads and Idea finder rows show today's numbers (unread tracks, ideas to judge) in the new row layout. Phase 2 narrows the people term; phase 3 changes the tracks/ideas rules.
- Sidebar: `SidebarDestination.rootItems == [.home, .inbox, .workbench, .automations, .calendar]`; `SidebarSection.today.items == [.catchUp, .targets]`.
- Tokens (Kit, `WatchtowerKit/Sources/WatchtowerDesign/Tokens.swift`): `PaneWidth.inboxListMin = 320`, `PaneWidth.inboxListIdeal = 372`, `PaneWidth.inboxListMax = 460`, `IconSize.listTile = 30`. The reading column is `ReadableColumn.maxLineWidth` (760). No inline numbers.
- Tile tints through existing tones only: brief `Tone.amber`, people waiting / approvals `Tone.warning`, mail `Tone.success`, threads / Slack / owner artifacts `Color.accentColor`, ideas `Tone.status("purple")`. Pill tones: needs-you `Tone.warning`, news `Color.accentColor`, batch neutral (`Fill.card` plate, `.secondary` text).
- Rail collapse: View → **Hide Inbox Folders** / **Show Inbox Folders**, ⌥⌘S, remembered in `UserDefaults` `inbox.railHidden` (Bool, default false).
- Per-folder selection memory: `UserDefaults` `inbox.entry.<folderID>` (String entry id), written only by the owner's click.
- Copy (exact): section titles "Needs you", "Today", "Running", "Earlier"; Earlier line "Past briefs are inside Morning brief · N this month, M not opened" (", M not opened" dropped when M = 0); search prompt "Search the Inbox"; no-match line "No matches for “<query>”"; approval group titles "Messages", "Tracks to create", "Targets", "Confluence and Jira", "Reminders", "Other", plus "Built-in updates" (notices, first) and "Approved, still running" (in-flight rows, last); collapsed group rows "Create N tracks", "N target changes", "N Confluence and Jira changes"; bulk button "Approve All N…" (only for the allowlisted tools of Task 7); partial result "Closed N of M. <error>".
- Writes unchanged (STRIP-02/03): every read mark is an owner gesture — a click, the brief stepper or History, or the owner's arrival (opening the Inbox, picking a folder) on a default pick that puts an unread brief or artifact on screen; a poll, a refresh and the midnight rollover write nothing. Approve All goes through `AgentActionFeed.approve` one row at a time.
- Desktop rules: tokens only, `.kitRow`, no row dividers, one prominent action per screen, `PanelSplit`/`HSplitView` as today, empty states through `TabEmptyState`; every new view model or center has its own tests; no test orders a window on screen.
- Inner loop per task only: `make test-swift FILTER=<Class>`, `make kit-test FILTER=<Class>`, `make lint-swift`, `go test ./internal/learn/` for guide cards. The full gate (`make test`, `make test-swift`, `make lint-all`) runs once, by the controller, after Task 13.
- Public repo hygiene: fixtures and shots use `acme` / `example.com` and "Colleague A…" only.

## Review Focus

Added by the plan author (not in the spec):

- **Midnight and time zones.** An item at 23:59:59 local yesterday must not count; one created yesterday but mentioned after midnight must; a DST day's midnight is the local one. Fixture cases `before_midnight`, `mentioned_today`, `dst_spring_forward`, `utc_vs_local` in Task 1, and the SQL count parity test in Task 4.
- **A remembered entry that is gone** (artifact deleted, automation moved to another folder, the day rolled over) must fall back to today's brief / the first entry, never to an empty pane and never to a legacy list. Test `testRestoreFallsBackWhenTheSavedEntryIsGone` in Task 8.
- **Approve All while the group changes under it** (an item approved elsewhere between confirm and apply; a failure on item 2 of 4). Skipped rows are reported, the run stops at the first failure and that card is selected with its error. Tests `testApproveAllSkipsRowsClosedMeanwhile`, `testApproveAllStopsAtFirstFailureAndSelectsThatCard` in Task 7.
- **A bulk plan with nothing in it** (count 0) must not open a confirmation for zero items. Test `testEmptyPlanFinishesWithoutConfirming` in Task 5.
- **Search with no match, diacritics, or a query left over from another folder**: the list shows the no-match line, the Earlier line hides, and clearing the field brings every section back with the selection kept. Tests `testFilterIgnoresCaseAndDiacritics`, `testNoMatchKeepsSelection` in Task 9.

---

### Task 1: `InboxToday` and its shared fixture

**Depends on:** none

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxToday.swift`
- Create: `internal/inbox/testdata/from_today.json`
- Test: `WatchtowerDesktop/Tests/Core/InboxTodayTests.swift`

**Interfaces:**
- Produces:
  - `package enum InboxToday { static func startOfToday(now: Date, calendar: Calendar) -> Date; static func isFromToday(createdAt: Date, mentionedAt: Date?, now: Date, calendar: Calendar) -> Bool; static func sinceUTC(now: Date, calendar: Calendar) -> String }` — `sinceUTC` = `startOfToday` formatted `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC (`en_US_POSIX`), the form `inbox_items` stores, for SQL `MAX(created_at, mentioned_at) >= ?`.
  - Fixture shape (phase 2 adds the Go twin over the same file): `{"about": "...", "cases": [{"name", "now", "tz", "created_at", "mentioned_at", "expected"}]}`; times RFC 3339 UTC, `mentioned_at` `""` = none, `tz` an IANA name.

- [ ] **Step 1: Write the fixture** with at least these cases (names exact): `midnight_exact` (created at local 00:00:00 → true), `before_midnight` (local 23:59:59 yesterday → false), `mentioned_today` (created yesterday, mentioned today → true), `no_mention` (created today, `""` → true), `mention_before_creation` (mentioned earlier than created, created today → true), `utc_vs_local` (same instant `2026-11-10T22:30:00Z`, now `2026-11-11T08:00:00Z`: `Europe/Kyiv` → true, `UTC` → false, two cases), `dst_spring_forward` (`America/New_York`, now `2026-03-08T15:00:00Z`: created `2026-03-08T04:59:59Z` → false, `2026-03-08T05:00:00Z` → true, two cases).
- [ ] **Step 2: Write the failing tests** in `InboxTodayTests`:
  - `testFixtureCases`: reads `internal/inbox/testdata/from_today.json` through `#filePath` (up to the repo root, as the policy-cases tests do); for each case builds a Gregorian calendar in `tz` and asserts `isFromToday(...) == expected`, message = case name; asserts the file has ≥ 9 cases.
  - `testStartOfTodayIsLocalMidnight`: `Europe/Kyiv`, now `2026-11-11T08:00:00Z` → `2026-11-10T22:00:00Z`.
  - `testSinceUTCFormat`: same input → `"2026-11-10T22:00:00Z"`.
- [ ] **Step 3: Run** `make test-swift FILTER=InboxTodayTests` — FAIL (no type).
- [ ] **Step 4: Implement** `InboxToday` (`max(createdAt, mentionedAt ?? createdAt) >= startOfToday`).
- [ ] **Step 5: Run** the same command — PASS; `make lint-swift`.
- [ ] **Step 6: Commit** `feat(inbox): InboxToday rule and shared fixture (#1076)`.

### Task 2: Sidebar — Inbox to the root, Targets into FOCUS

**Depends on:** none

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/SidebarDestination.swift` (`rootItems` and its comment), `WatchtowerDesktop/Sources/App/SidebarSection.swift` (`today.items`, the `collapsedByDefault` comment)
- Modify tests: `WatchtowerDesktop/Tests/SidebarSectionTests.swift`, `WatchtowerDesktop/Tests/HomeLandingTests.swift`, `WatchtowerDesktop/Tests/SidebarAutomationsVisibilityTests.swift`, `WatchtowerDesktop/Tests/ConnectionsTabTests.swift`
- Modify: `docs/guide/features/home.md` (the menu paragraph)

**Interfaces:**
- Produces: `SidebarDestination.rootItems == [.home, .inbox, .workbench, .automations, .calendar]`; `SidebarSection.today.items == [.catchUp, .targets]`; `SidebarSection.containing(.inbox) == nil`, `containing(.targets) == .today`.

- [ ] **Step 1: Update the tests first:** `SidebarSectionTests` — the two order assertions to the values above; `containing(.inbox)` → nil, `containing(.targets)` → `.today`; `expandingSection(for: .targets, …)` now expands FOCUS; the collapsed-FOCUS aggregate fixture becomes `.catchUp: 2, .targets: 5` with its message rewritten; new `testAHiddenInboxEntryIsIgnoredAtTheRoot` (a `sidebar.hiddenItems` containing `"inbox"` still shows the Inbox: root items have no hide menu). `HomeLandingTests`/`SidebarAutomationsVisibilityTests`/`ConnectionsTabTests`: only the pinned orders and comments that name Targets as a root item.
- [ ] **Step 2: Run** `make test-swift FILTER='SidebarSectionTests|HomeLandingTests|SidebarAutomationsVisibilityTests|ConnectionsTabTests'` — FAIL on the order assertions.
- [ ] **Step 3: Implement** the two arrays; the `rootItems` comment says the Inbox sits in Targets' old place with its badge and Targets lives in FOCUS (2026-11 redesign, #1076); the FOCUS comment names Catch Up and Targets.
- [ ] **Step 4: Run** the same command — PASS; `make lint-swift`.
- [ ] **Step 5: Guide:** `docs/guide/features/home.md` — "The menu lists Home, Inbox, Workbench, Automations and Calendar…" and "**FOCUS**: Catch Up, Targets."; grep `docs/guide` for other "FOCUS: Catch Up, Inbox" statements and fix them.
- [ ] **Step 6: Commit** `feat(sidebar): Inbox at the root, Targets in FOCUS (#1076)`.

### Task 3: Tokens for the list column and the tile

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerDesign/Tokens.swift` (`PaneWidth`, `IconSize`)
- Modify: `WatchtowerKit/Tests/WatchtowerDesignTests/TokenTests.swift`
- Modify: `WatchtowerDesktop/Sources/DesignKitCatalog/CatalogPages/FoundationPages.swift` (show the new steps beside `sideList*`)

**Interfaces:**
- Produces: `PaneWidth.inboxListMin: CGFloat = 320`, `inboxListIdeal = 372`, `inboxListMax = 460` (doc: "The Inbox's list column: a fixed range, the reading pane takes the rest"); `IconSize.listTile: CGFloat = 30` (doc: "A list row's kind tile (the Inbox list)").

- [ ] **Step 1: Extend** `TokenTests.testPaneWidths` with the three values and `testIconSizes` with `IconSize.listTile == 30`.
- [ ] **Step 2: Run** `make kit-test FILTER=TokenTests` — FAIL.
- [ ] **Step 3: Implement** the tokens and the catalog steps.
- [ ] **Step 4: Run** `make kit-test FILTER=TokenTests` — PASS; `make test-swift FILTER=DesignTokensTests` stays green; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(design): Inbox list column and tile tokens (#1076)`.

### Task 4: Counts and the badge (STRIP badge amendment)

**Depends on:** Task 1

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/InboxQueries.swift`, `.../Database/Queries/BriefingQueries.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxFolderMenuModel.swift` (`InboxFolderMenuSnapshot`), `.../Services/Inbox/InboxFolderCounts.swift`, `.../Services/Actions/ActionStripViewModel.swift` (`badgeCount`, `legacyCounts`)
- Modify: `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift` (the badge comment; a recount at local midnight)
- Tests: `WatchtowerDesktop/Tests/Core/InboxFeedQueriesTests.swift`, `Tests/Core/InboxFolderCountsTests.swift`, `Tests/Core/ActionStripAutomationOutputTests.swift`, `Tests/Core/ActionStripAllKindsTests.swift`, `Tests/Core/InboxBriefEntryTests.swift`, `Tests/Core/InboxFolderEntriesTests.swift`, `Tests/SidebarCountsViewModelTests.swift`, new `Tests/Core/InboxPeopleTodayTests.swift`
- Modify: `docs/inventory/reaction-commands.md` (changelog)

**Interfaces:**
- Consumes: `InboxToday.sinceUTC(now:calendar:)`, the fixture of Task 1.
- Produces:
  - `InboxQueries.openMessageCount(_ db: Database, nowUTC: String, sinceUTC: String) throws -> Int` — `COUNT(*)` over `HomeFeedQueries.openMessageClause` with `MAX(created_at, mentioned_at) >= sinceUTC`.
  - `BriefingQueries.unreadCount(_ db: Database, date: String) throws -> Int` — 1 when that date's briefing exists with `read_at IS NULL`, else 0.
  - `InboxFolderMenuSnapshot.peopleWaitingToday: Int` (0 when `waitingForMe.turnedOff`; phase 1: every open item from today), `InboxFolderMenuSnapshot.approvalsCount: Int` (Needs approval's count; on a root-only tree the same approval terms), `InboxFolderMenuSnapshot.badge: Int { approvalsCount + peopleWaitingToday }`.
  - `InboxFolderMenuSnapshot.read(_ db: Database, nowUTC: String, disabledFeatures: Set<String> = [], calendar: Calendar = .current) throws -> Self`.
  - `ActionStripViewModel.badgeCount(_ db: Database, nowUTC: String, disabledFeatures: Set<String> = [], calendar: Calendar = .current) throws -> Int` = `snapshot.badge`.
  - `ActionStripViewModel.legacyCounts(_ db: Database, nowUTC: String, today: String, tree: InboxFolderTree, peopleWaitingToday: Int) throws -> [Int64: Int]` — root: `peopleWaitingToday + BriefingQueries.unreadCount(db, date: today)`; approvals unchanged (`awaitingOwnerCount` + `ReminderQueries.dueCount` + `BuiltinUpgradeNotice.load(db).count`, in the root on a root-only tree). Ideas, unread messages and the latest briefing leave it. Each term still `zeroIfTableMissing`.
  - `InboxToday.nextMidnight(after now: Date, calendar: Calendar) -> Date` (the next `startOfDay`, DST-safe through `calendar.nextDate`) — added to Task 1's enum here.
  - `SidebarCountsViewModel` re-reads the Inbox badge at `nextMidnight + 1 s` and schedules the next one (a cancellable `Task` with an injected clock/sleeper, cancelled on deinit): "today" changes at midnight without any database write, and its observation only fires on writes, so without this the badge would keep yesterday's people until the next change.
  - `InboxFolderCounts.counts(tree:artifacts:refs:refState:legacy:uncounted: Set<Int64> = [])` — artifacts whose `automationID` is in `uncounted` add nothing (the Waiting for me built-in's). `InboxFolderCounts.badge(counts:tree:)` is removed.

- [ ] **Step 1: Rewrite the STRIP guard** `InboxFeedQueriesTests::testBadgeCountsDecisionsUnreadMessagesLatestUnreadDayAndDueReminders` → renamed `testBadgeCountsApprovalsAndPeopleWaitingToday` (the rename is recorded in the inventory, Step 7). Fixture, all with explicit times and `calendar` = UTC, `now` fixed: 1 pending proposal, 1 due reminder, 2 open messages created today, 1 open message created yesterday and mentioned today, 1 open message from yesterday, 1 read open message from today, 1 proposed idea, the latest briefing unread (and an older unread one), 3 unread root artifacts, 1 unread artifact in an owner folder, 2 unread tracks. Assert `badgeCount == 6` (2 approvals + 4 people today: the read one counts — the term is "waiting", not "unread"); then a failed `builtin_migrations` row + a done one → `7`.
- [ ] **Step 2: Add tests:**
  - `InboxPeopleTodayTests.testOpenMessageCountMatchesInboxToday`: for each `from_today.json` case insert one open `inbox_items` row with its times, call `openMessageCount(db, nowUTC: case.now, sinceUTC: InboxToday.sinceUTC(now:calendar:))` → `expected ? 1 : 0`; delete it before the next case.
  - `InboxPeopleTodayTests.testTurnedOffWaitingForMeCountsNoPeople`: `secretary-inbox` disabled → `peopleWaitingToday == 0` and the badge is the approvals only.
  - `InboxPeopleTodayTests.testNextMidnight` (`Europe/Kyiv` and the `America/New_York` DST day); `SidebarCountsViewModelTests.testInboxBadgeRecountsAtMidnight` (fake clock just before midnight, one open item created yesterday evening: badge 1 → after the scheduled recount 0, with no database write in between); `InboxFolderCountsTests`: `testRootCountsPeopleTodayBriefAndArtifacts` (root = people today + today's unread brief + unread plain root artifact; ideas and an unread past brief add nothing); `testWaitingForMeArtifactIsNotCountedTwice` (a succeeded Waiting for me with 2 waiting refs from today → root 2, not 4); `testOwnerFolderArtifactsNeverReachTheBadge` (replaces the hidden-folder badge test: owner-folder and hidden-folder artifacts keep their own counts, badge unchanged).
- [ ] **Step 3: Update the other badge expectations** (none relaxed — each is the new rule applied to its own fixture, each message names the rule): `ActionStripAutomationOutputTests::testOpeningWritesOnlyReadAt` (STRIP-02 guard; keeps its full-row comparison) → `badgeAfter == badgeBefore` ("artifacts left the badge, redesign phase 1"); `testInboxBadgeCountsUnreadOutputs` → renamed `testInboxBadgeLeavesOutputsOut`, `== 2`; `testBadgeCountToleratesOnlyAMissingTable` unchanged (`1`); `InboxFolderCountsTests` `testUnreadMessagesLeaveTheRootOnceWaitingForMeSucceeded` / `testStaleWaitingForMeListLeavesTheBadgeAfterAFailedRun` with explicit `created_at` today → 1 / 2; `testBadgeWithoutTheFolderSeedRowsCountsEverythingInTheRoot` → `1` ("the proposal; the unread artifact is not a badge term"); `InboxFeedQueriesTests::testBadgeOnASchemaWithoutTheNewTables` → `1`; `ActionStripAllKindsTests::testTodaysPlaceholderIsListedButNeverCounted`, `InboxBriefEntryTests::testBriefsNeverCount`, the turned-off test in `InboxFolderEntriesTests` keep `0`; `SidebarCountsViewModelTests::testInboxBadgeCountsTheInboxCards` to its fixture's approvals + people today.
- [ ] **Step 4: Run** `make test-swift FILTER='InboxFeedQueriesTests|InboxFolderCountsTests|InboxPeopleTodayTests|ActionStripAutomationOutputTests|ActionStripAllKindsTests|InboxBriefEntryTests|InboxFolderEntriesTests|SidebarCountsViewModelTests'` — FAIL.
- [ ] **Step 5: Implement.** `read` computes `today = HomeFeedBuilder.dayString(now, calendar:)`, `peopleWaitingToday` (`zeroIfTableMissing`, 0 when turned off), passes `uncounted = [waitingForMe.automationID]` when it has one; `approvalsCount = legacy[(tree.approvals ?? tree.root).id]`'s approval part (compute it once and keep it on the snapshot, do not re-derive from the root sum). Rewrite the doc comments of `badgeCount`, `legacyCounts`, `InboxFolderCounts` and `SidebarCountsViewModel`'s badge line to the new terms.
- [ ] **Step 6: Run** the Step 4 command — PASS; `make test-swift FILTER='Approval01Tests|ActionStripViewModelTests'` stays green; `make lint-swift`.
- [ ] **Step 7: Inventory.** In `docs/inventory/reaction-commands.md` add a changelog entry at the top, dated the day the task lands: "(Inbox redesign phase 1, board #1076, spec `docs/superpowers/specs/2026-11-11-inbox-redesign-design.md` "Counts", **STRIP badge amendment approved by the owner in ask #634**): the Inbox badge (`ActionStripViewModel.badgeCount`, still read by `SidebarCountsViewModel`, one read, writing nothing) becomes Needs approval's open approvals (`awaitingOwnerCount`, due reminders, built-in upgrade notices — unchanged) + people waiting today (open attention items whose `MAX(created_at, mentioned_at)` is at or after local midnight, `InboxToday`; until phase 2 this includes mail; 0 while Waiting for me is turned off). Ideas, briefings, Messages' unread count and every artifact (root or owner folder) leave the badge; mail never enters it once phase 2 splits it out. The Inbox root's own count is people today + today's unread brief + its other artifacts. Guard changes, none relaxed: the C1 guard `InboxFeedQueriesTests::testBadgeCountsDecisionsUnreadMessagesLatestUnreadDayAndDueReminders` is rewritten to the new terms and renamed `testBadgeCountsApprovalsAndPeopleWaitingToday` (approved in ask #634); the STRIP-02 guard `ActionStripAutomationOutputTests::testOpeningWritesOnlyReadAt` changes only its badge expectation (opening an artifact no longer moves the badge) and keeps its full-row comparison; `testInboxBadgeCountsUnreadOutputs` became `testInboxBadgeLeavesOutputsOut` (not an inventory guard). New: `InboxPeopleTodayTests` (SQL count ↔ `InboxToday` over `internal/inbox/testdata/from_today.json`)." Also replace the old guard name wherever the file lists it as a test guard.
- [ ] **Step 8: Commit** `feat(inbox): badge = approvals + people waiting today (#1076)`.

### Task 5: `InboxBulkPressModel` and `InboxBulkPressButton`

**Depends on:** none

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxBulkPress.swift`
- Create: `WatchtowerDesktop/Sources/Views/Inbox/InboxBulkPressButton.swift`
- Tests: `WatchtowerDesktop/Tests/Core/InboxBulkPressModelTests.swift`, `WatchtowerDesktop/Tests/InboxBulkPressButtonTests.swift`

**Interfaces:**
- Produces (shared with phases 2 and 3 — names exact):
  - `package struct InboxBulkPlan: Equatable, Sendable { package let ids: [String]; package let count: Int }`
  - `package enum InboxBulkResult: Equatable, Sendable { case done(count: Int, skipped: Int); case partial(done: Int, of: Int, error: String); case failed(String) }`
  - `@MainActor package final class InboxBulkPressModel: ObservableObject` with `package enum State: Equatable { case idle, planning, confirming(InboxBulkPlan), running, finished(InboxBulkResult) }`, `@Published package private(set) var state: State`, `package init(plan: (() async throws -> InboxBulkPlan)? = nil, apply: (([String]) async throws -> InboxBulkResult)? = nil)`, `package func begin(plan: @escaping () async throws -> InboxBulkPlan)` (also stores it as the Try Again plan), `package func confirm(apply: @escaping ([String]) async throws -> InboxBulkResult)`, `package func cancel()`, `package func begin()` / `package func confirm()` (the stored closures — what the button calls; no-op without one).
  - Rules: `begin` from `idle`/`finished` only (ignored while `planning`/`confirming`/`running`); a plan whose `count == 0` → `.finished(.done(count: 0, skipped: 0))` without confirming; a thrown plan → `.finished(.failed(error.localizedDescription))`; `confirm` only from `.confirming(plan)`, passes exactly `plan.ids`; a thrown apply → `.finished(.failed(…))`; `cancel` from `confirming` → `idle`. Nothing retries by itself.
  - `struct InboxBulkPressButton: View { init(title: String, confirmTitle: @escaping (Int) -> String, model: InboxBulkPressModel) }` — `.kitSecondary` button (disabled with a small `ProgressView` while `planning`/`running`); a `confirmationDialog` titled `confirmTitle(count)` with that title as its confirm button and **Cancel**; under it `resultLine` and, for `.partial`/`.failed`, a `.kitQuiet` **Try Again** calling `model.begin()`.
  - `static func resultLine(_ result: InboxBulkResult) -> String?`: `.done(_, 0)` with count > 0 → nil; `.done(0, 0)` → "Nothing left to do."; `.done(n, s)` with s > 0 → "Done: n. s were already closed."; `.partial(d, m, e)` → "Closed d of m. e"; `.failed(e)` → e.

- [ ] **Step 1: Write the failing tests** — `InboxBulkPressModelTests`: `testBeginPlansThenConfirms` (states idle → planning → confirming(plan) → running → finished(.done(count: 3, skipped: 0)); apply received `["a","b","c"]`), `testEmptyPlanFinishesWithoutConfirming`, `testPlanErrorFinishesFailed`, `testApplyErrorFinishesFailed`, `testPartialResultIsKept`, `testBeginIgnoredWhileRunning` (a second `begin()` during a slow apply does not call the plan again), `testCancelReturnsToIdle`, `testTryAgainReRunsThePlan` (`begin()` after `.finished(.failed)` calls the stored plan a second time), `testConfirmOutsideConfirmingIsIgnored`. `InboxBulkPressButtonTests` (ViewInspector): `testResultLines` (the five strings above), `testTryAgainOnlyAfterPartialOrFailed`.
- [ ] **Step 2: Run** `make test-swift FILTER='InboxBulkPressModelTests|InboxBulkPressButtonTests'` — FAIL.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4: Run** — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(inbox): bulk press model and button (#1076)`.

### Task 6: Row content, root sections and the one-brief rule

**Depends on:** Task 1, Task 4

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxRowContent.swift` (`InboxRowKind`, `InboxRowPill`, `InboxRowContent`, `InboxRowTime`, `InboxRowText`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxRootSections.swift` (`InboxRootSection`, `InboxRootSections`, `InboxEarlierLine`)
- Modify: `.../Services/Inbox/InboxFolderEntries.swift` (`content(_:_:)` replaces `row`'s text; `Inputs.selectedDay` removed), `.../Services/Inbox/InboxListBuilder.swift` (`rootDays`), `.../Services/Inbox/InboxFolderListContent.swift` (`InboxFolderListRow`, `InboxListSection`, sections on `InboxFolderListContent`), `.../Services/Actions/ActionStripViewModel.swift` (`folderList` builds sections)
- Tests: new `Tests/Core/InboxRowContentTests.swift`, `Tests/Core/InboxRootSectionsTests.swift`; update `Tests/Core/InboxListBuilderTests.swift`, `Tests/Core/InboxFolderEntriesTests.swift`, `Tests/Core/InboxBriefEntryTests.swift`, `Tests/InboxLegacyEntryMenuTests.swift`

**Interfaces:**
- Consumes: `InboxToday`, `InboxFolderMenuSnapshot.peopleWaitingToday`.
- Produces (shared — names exact):
  - `package enum InboxRowKind: Equatable, Sendable { case brief, peopleWaiting, mailWaiting, slackToday, threads, ideas, approval, artifact }`
  - `package struct InboxRowPill: Equatable, Sendable { package enum Tone: Equatable, Sendable { case needsYou, news, batch }; package let count: Int; package let tone: Tone }`
  - `package struct InboxRowContent: Equatable, Sendable { kind: InboxRowKind; title: String; preview: String; meta: String; time: String; pill: InboxRowPill?; isUnread: Bool; symbol: String? = nil }` (`symbol` = an owner artifact's folder icon; nil = the kind's own).
  - `package enum InboxRowTime { static func label(_ date: Date, now: Date, calendar: Calendar) -> String }` — same day `HH:mm`; the day before "yesterday"; 2–6 days back `EEE` ("Mon"); older this year `d MMM`; another year `d MMM yyyy`; `en_US_POSIX`, the calendar's time zone; a future date reads as today.
  - `package enum InboxRowText { static func preview(_ body: String) -> String }` — non-empty lines with leading markdown markers (`#`, `>`, `-`, `*`, `+`, `1.`) and `**`/`__`/`` ` `` removed, joined by a space, whitespace collapsed, capped at 240 characters with "…".
  - `package enum InboxRootSection: String, CaseIterable, Sendable { case needsYou, today, running, earlier; var title: String }` (titles "Needs you", "Today", "Running", "Earlier").
  - `package enum InboxRootSections { static func build(entries: [InboxFolderEntry], folder: InboxFolderKind, waitingForMeAutomationID: Int64?, now: Date, calendar: Calendar) -> [(InboxRootSection, [InboxFolderEntry])]; static func earlierLine(days: [InboxDayCard], today: String, now: Date, calendar: Calendar) -> InboxEarlierLine? }`
  - `package struct InboxEarlierLine: Equatable, Sendable { package let pastThisMonth: Int; package let notOpened: Int; package var text: String }`
  - `InboxFolderEntries.content(_ entry: InboxFolderEntry, _ inputs: Inputs) -> InboxRowContent`
  - `package struct InboxFolderListRow: Identifiable, Equatable, Sendable { id: String; content: InboxRowContent; menu: [InboxMenuEntry] }` (its `kind`/`title`/`summary`/`detail`/`unread` go; `isArtifact: Bool` stays for the context menu).
  - `package struct InboxListSection: Identifiable, Equatable, Sendable { package let id: String; package let title: String; package let rows: [InboxFolderListRow] }`; `InboxFolderListContent` gains `sections: [InboxListSection]` and `earlierLine: InboxEarlierLine?`; `rows` becomes `sections.flatMap(\.rows)`.

Section rules (`build`):
- Root — **Needs you**: Waiting for me's artifact, the Messages stand-in, then thread briefs applied in the last 24 hours (newest first; the window is the one `InboxFeedSnapshot.briefs` already applies — `AgentActionQueries.fetchExecutedBriefs` by `applied_at`, ask #609 — and `build` re-checks it: a `.brief` entry whose `appliedAt` is more than 24 h before `now` is dropped, so Needs you never grows with old briefs); on a root-only tree (no Needs approval folder) the approvals and notices follow. **Today**: the Morning brief entry, then artifacts whose `changedAt` is from today (`InboxToday`), newest first. **Running**: Track my threads, Idea finder, then the other artifacts, newest first. Earlier is never an entry section in the root (the line).
- Owner folder — **Today** (`changedAt` from today) and **Earlier**, each keeping the incoming order.
- Needs approval — `[]` (Task 7 builds its groups).
- A section with no entries is left out.

Row content (`content`), phase 1:

| Entry | kind | title | preview | meta | time | pill | unread |
|---|---|---|---|---|---|---|---|
| Waiting for me artifact / Messages stand-in | `.peopleWaiting` | card title (stand-in "Messages") | newest open message from today: `<who> <where>: “<snippet>”`, + " · and N more today" when N > 0; none today → the newest open one without the suffix; none → "Nothing waits on you" | "N older" (open, not from today; empty when 0) | newest stamp | `peopleWaitingToday`, `.needsYou` (none at 0) | pill > 0 |
| Morning brief (today) | `.brief` | "Morning brief" | `InboxBriefLayout.lead` (Task 11; until then `Briefing.parsedAttention.first?.text ?? parsedYourDay.first?.text`), placeholder → "Not written yet" | `EEE d MMM` of the date | brief `createdAt` (placeholder: none) | none | `card.isUnread` |
| Track my threads | `.threads` | "Track my threads" | the two newest unread tracks' titles, one per line; none → "Nothing new in your threads" | "updated <ago>" | newest event | unread tracks, `.news` | unread > 0 |
| Idea finder | `.ideas` | "Idea finder" | "N ideas to judge. Top one: “<newest awaiting title>”"; none → "No ideas wait for a verdict" | "updated <ago>" | newest update | ideas awaiting a verdict, `.batch` | > 0 |
| Thread brief | `.threads` | reason or "Thread brief" | "" | "Thread brief" | `appliedAt` | none | false |
| Owner artifact | `.artifact`, `symbol` = its folder's icon (`""` → `folder`) | title or automation name | `InboxRowText.preview(card.body)` | living: "Your automation · updated <ago>"; else "Your automation · run #N" | `changedAt` | rows waiting (`InboxFolderCounts.artifactCount` when it has refs), `.needsYou`; none for a plain artifact | as today |

- [ ] **Step 1: Write the failing tests** — `InboxRowContentTests`: `testTimeLabels` (08:02 today, "yesterday", "Mon", "3 Nov", "3 Nov 2025", a future time → today's `HH:mm`, all in `Europe/Kyiv`), `testPreviewStripsMarkdown`, `testPreviewCapsAt240`, `testWaitingForMeRow` (2 today + 3 older, `peopleWaitingToday` 2 → preview "Colleague B in a DM: “Will you approve the budget?” · and 1 more today", meta "3 older", pill 2 `.needsYou`), `testWaitingForMeRowWithNothingToday` (no pill, preview of the newest), `testBriefRowHasNoPill`, `testTracksAndIdeasRows`, `testOwnerArtifactRowUsesFolderIcon`, `testThreadBriefNeverUnread`. `InboxRootSectionsTests`: `testRootOrder` (entries of every kind → needsYou [waiting, brief:1], today [day, artifact today], running [tracks, ideas, artifact yesterday]), `testEmptySectionsAreLeftOut`, `testOwnerFolderTodayAndEarlier`, `testRootOnlyTreeKeepsApprovalsInNeedsYou`, `testThreadBriefsOlderThan24HoursLeaveNeedsYou` (briefs applied 2 h and 25 h before `now` → only the first is listed), `testEarlierLineCountsPastThirtyDays` (5 past briefs in 30 days, 2 unread, 1 older than 30 days, today's excluded → "Past briefs are inside Morning brief · 5 this month, 2 not opened"), `testEarlierLineWithoutUnread` ("… · 5 this month"), `testNoEarlierLineWithoutPastBriefs`.
- [ ] **Step 2: Update** `InboxListBuilderTests` (`rootDays` returns today only, or the placeholder; an unread past day is no longer listed), `InboxFolderEntriesTests`/`InboxBriefEntryTests`/`InboxLegacyEntryMenuTests` to the new `InboxFolderListRow` shape and to "no `selectedDay`".
- [ ] **Step 3: Run** `make test-swift FILTER='InboxRowContentTests|InboxRootSectionsTests|InboxListBuilderTests|InboxFolderEntriesTests|InboxBriefEntryTests|InboxLegacyEntryMenuTests'` — FAIL.
- [ ] **Step 4: Implement.** `rootDays` keeps today's card (or the placeholder under today's rules) only; delete `Inputs.selectedDay` and `ActionStripViewModel.dayOfEntry`. `folderList` builds root/owner sections through `build` + `content`, the Earlier line from `feed.days` in the root only.
- [ ] **Step 5: Run** — PASS; `make lint-swift`. The old `InboxFolderListRowView` still compiles against the new row (read `row.content.title`/`isUnread`) until Task 9 replaces it.
- [ ] **Step 6: Commit** `feat(inbox): row content, urgency sections, one brief row (#1076)`.

### Task 7: Needs approval groups and Approve All

**Depends on:** Task 5, Task 6

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/NeedsApprovalGroups.swift`
- Modify: `.../Services/Actions/ActionStripViewModel.swift` (approval sections in `folderList`, Approve All)
- Tests: `Tests/Core/NeedsApprovalGroupsTests.swift`, `Tests/Core/ActionStripApproveAllTests.swift`
- Modify: `docs/inventory/inbox-folders.md` (APPROVAL-01 changelog)

**Interfaces:**
- Consumes: `InboxBulkPlan`, `InboxBulkResult`, `InboxBulkPressModel`, `InboxListSection`, `InboxRowContent`.
- Produces:
  - `package enum NeedsApprovalGroup: String, CaseIterable, Sendable { case messages, tracksToCreate, targets, confluenceJira, reminders, other; var title: String; static func of(_ item: NeedsApprovalItem) -> Self }` — `send_slack_message`, `add_jira_comment`, `add_linear_comment` → messages; `create_track` → tracksToCreate; `create_target`, `create_targets`, `update_target` → targets; `edit_confluence_page`, `connect_jira_board`, `create_jira_issue`, `update_jira_issue`, `transition_jira_issue`, `assign_jira_issue` → confluenceJira; a reminder → reminders; everything else (connector calls such as `claude_ai_connector_call`, Linear writes, `save_automation`, any tool added later) → other.
  - `package enum NeedsApprovalGroups { static let bulkTools: Set<String>; static func build(_ items: [NeedsApprovalItem]) -> [(NeedsApprovalGroup, [NeedsApprovalItem])]; static func approveAllIDs(_ group: NeedsApprovalGroup, _ items: [NeedsApprovalItem]) -> [Int64]? }` — groups ordered by their oldest item (`NeedsApprovalItem`'s listed order), items oldest first. **Approve All is an allowlist, never a denylist**: `bulkTools` = `create_track`, `create_target`, `create_targets`, `update_target`, `edit_confluence_page`, `connect_jira_board`, `create_jira_issue`, `update_jira_issue`, `transition_jira_issue`, `assign_jira_issue` — none of them sends text to a person. `approveAllIDs` is nil unless the group is tracksToCreate, targets or confluenceJira, every action in it has one and the same tool from `bulkTools`, and it has ≥ 2 approvable rows (an `.action` that `isPending` and is not session-applied). So Messages, Reminders (a reminder has no Approve, only Done / Snooze) and Other (connector sends, unknown tools) never get it.
  - `package enum NeedsApprovalListRow { case item(NeedsApprovalItem), group(NeedsApprovalGroup, [NeedsApprovalItem]) }` and `NeedsApprovalGroups.listRows(_ group:, _ items:) -> [NeedsApprovalListRow]` — as in the mockup, a group with a non-nil `approveAllIDs` is **one list row** (id `group:<raw>`; title per group: "Create N tracks", "N target changes", "N Confluence and Jira changes"; preview = the oldest item's title + " · and N−1 more"; meta = the oldest item's `InboxApprovalText.meta`; pill N, `.needsYou`); every other group lists one row per item. Selecting a group row scrolls the stack to that group's header; the stack in the reading pane still draws every card.
  - `package struct InboxApprovalText { static func preview(_ action: AgentAction) -> String; static func meta(_ action: AgentAction) -> String }` — preview: the first non-empty string among `args_json` keys `text`, `message`, `body`, `comment`, `title`, quoted, capped at 140; meta: `context_type == automation_run` → "Proposed by an automation"; surface `inbox` → "Proposed from the Inbox", `chat` → "Proposed in a chat", `workbench` → "Proposed by a workbench session"; else "Proposed by the assistant". A reminder row: title its note, preview "Due <InboxRowTime label>", meta "Reminder".
  - Needs approval's `folderList.sections`: "Built-in updates" (notices) first, then one section per group (title + " · N" count in the view) holding its `listRows`, then "Approved, still running" (in-flight rows), each row kind `.approval`. The two extra sections are not new kinds of approval: they are the rows the stack already draws today (notices first, approved-and-running last, inbox-folders.md "Approved and executing rows"), which need a heading once the list is grouped. **Approve All N…** sits on the group's header in the reading pane's stack (the mockup's pane header for a group), not in the list.
  - On `ActionStripViewModel`: `package func approveAllModel(_ group: NeedsApprovalGroup) -> InboxBulkPressModel` (one per group, kept on the view model so a run survives leaving the Inbox; built with `plan` = `approveAllPlan(group)` and `apply` = `approveAll(ids:)`); `package func approveAllPlan(_ group: NeedsApprovalGroup) -> InboxBulkPlan` (ids from the current entries, as strings; empty when not eligible); `package func approveAll(ids: [String]) async -> InboxBulkResult` — one `refresh()` first; each id no longer in `folderMenu.snapshot.openActions` is skipped; each other one goes through `actionFeed.approve(id, shownArgs: row.argsJSON)`; the first `actionFeed.rowErrors[id]` stops the run, sets `entrySelection = "approval:action:<id>"` and returns `.partial(done:, of: ids.count, error: message)`; ends with `refresh()`; otherwise `.done(count:, skipped:)`.

- [ ] **Step 1: Write the failing tests** — `NeedsApprovalGroupsTests`: `testToolsMapToGroups` (every tool listed above + an unknown tool → other + a reminder), `testGroupsSortByOldestItem`, `testMessagesNeverGetApproveAll` (3 Slack sends → nil), `testConnectorSendsNeverGetApproveAll` (3 pending `claude_ai_connector_call` rows → group other, nil), `testUnknownToolNeverGetsApproveAll`, `testRemindersNeverGetApproveAll`, `testMixedToolsGetNoApproveAll`, `testOneToolGroupGetsApproveAll` (3 pending `create_track` → 3 ids), `testSingleItemGetsNoApproveAll`, `testSessionAppliedAreLeftOut`, `testBulkGroupIsOneListRow` (4 `create_track` → one row "Create 4 tracks", pill 4; 3 Slack sends → three rows), `testApprovalPreviewAndMeta`. `ActionStripApproveAllTests` (fake CLI runner as in `ActionStripViewModelTests`): `testApproveAllApprovesEachThroughTheFeed` (3 `create_targets` rows → 3 `actions approve` calls each with `--args-sha256`, `.done(count: 3, skipped: 0)`), `testApproveAllSkipsRowsClosedMeanwhile`, `testApproveAllStopsAtFirstFailureAndSelectsThatCard` (runner fails on the 2nd → 1 approve after it is not run, `.partial(done: 1, of: 3, error: …)`, `entrySelection == "approval:action:<2nd>"`), `testEveryOpenApprovalStaysListed` (APPROVAL-01 supporting: grouped sections hold exactly the entries of `InboxFolderEntries.build`), `testApproveAllModelSurvivesLeavingTheInbox` (start, `setOnScreen(false)`, the same model instance finishes).
- [ ] **Step 2: Run** `make test-swift FILTER='NeedsApprovalGroupsTests|ActionStripApproveAllTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; `make test-swift FILTER='Approval01Tests|NeedsApprovalSelectionTests'` stays green; `make lint-swift`.
- [ ] **Step 5: Inventory.** `docs/inventory/inbox-folders.md` changelog, dated the day it lands: "(Inbox redesign phase 1, board #1076, spec "Needs approval"; relied on unchanged): Needs approval gains a list column grouped by kind (Messages, Tracks to create, Targets, Confluence and Jira, Reminders, Other; built-in notices first, approved-and-running rows last) beside the stack, which still draws every open approval's card. **Approve All N…** on a group of one allowlisted tool (tracks, targets, Confluence and Jira edits — never a tool that sends text to a person, never an unknown or connector tool) approves each row through `AgentActionFeed.approve` (the per-action path, args pinned), stops at the first failure and shows it on that card; such a group is one row in the list. Messages, Reminders and Other never get it. No semantic change to APPROVAL-01. Supporting: `NeedsApprovalGroupsTests`, `ActionStripApproveAllTests::testEveryOpenApprovalStaysListed`."
- [ ] **Step 6: Commit** `feat(inbox): Needs approval groups and Approve All (#1076)`.

### Task 8: Selection memory, the default entry and the brief's day

**Depends on:** Task 6

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxBriefDays.swift`
- Modify: `.../Services/Inbox/InboxFolderEntries.swift` (`defaultEntry`), `.../Services/Actions/ActionStripViewModel.swift` (`selectFolder`, `selectEntry`, first read, `open(folder:select:)`'s `.day`, brief day state)
- Tests: `Tests/Core/InboxBriefDaysTests.swift`, `Tests/Core/InboxEntrySelectionTests.swift`; update `Tests/InboxRouteTests.swift`, `Tests/Core/ActionStripAllKindsTests.swift`

**Interfaces:**
- Produces:
  - `InboxFolderEntries.defaultEntry(entries: [InboxFolderEntry], saved: String?, folder: InboxFolderKind, today: String) -> String?` — `saved` when listed and not a legacy-list entry (`legacyList == nil`); else in the root `"day:<today>"` when listed; else the first entry with `legacyList == nil`; else nil.
  - `ActionStripViewModel.entryKey(_ folderID: Int64) -> String` = `"inbox.entry.\(folderID)"`; `selectEntry(_:)` writes it (the owner's click only).
  - Default selection (`defaultEntry`) runs on the first read, on `selectFolder(_:)`, when `open(folder:select:)` gets a nil entry, and when the selected Morning brief entry left the list because the day rolled over (its id `day:<yesterday>` is gone and `day:<today>` is listed); a later poll never re-selects after the owner cleared it.
  - **Read marks of a default pick:** the pick is shown through `showEntry` (no write) inside `refresh()` — STRIP-02: a read writes nothing. The owner's arrival is a gesture, so `package func ownerArrived() async` — called by `ActionStripView.onAppear` (the owner opened the Inbox) and by `selectFolder(_:)` (the owner picked a folder) — waits for the first read, then, when the shown entry is a Morning brief day or an artifact that is still unread, writes its read mark through today's `select(_:)` path (the brief is on screen, so it is opened: "a brief is read once opened"). A pick made by a poll, a refresh or the midnight rollover writes nothing; the 30 s poll never calls `ownerArrived`.
  - `package enum InboxBriefDays { enum Step { case older, newer }; static func history(_ days: [InboxDayCard], today: String, now: Date, calendar: Calendar) -> [InboxDayCard]; static func step(from date: String, _ step: Step, in days: [InboxDayCard], today: String) -> String? }` — history = the days within the last 30 days that have a briefing or a plan, today included, newest first. **Coverage:** the feed's first page is `ActionStripViewModel.dayPage` (30) day cards, at most one per date, read newest first, so it always holds every card of the last 30 days; both History and the Earlier line (Task 6) are therefore complete, never "loaded so far". A test pins it (`testFirstPageCoversThirtyDays`), and a code comment on `dayPage` says History and the Earlier line rely on it (lowering it below 30 breaks them); `step` moves to the next listed date (older/newer), nil past the ends; newer never passes today.
  - On `ActionStripViewModel`: `package private(set) var briefDate: String?` (nil = today), `package var briefDay: InboxDayCard?` (the card for `briefDate ?? today`, the root entry's card for today), `package var briefHistoryShown: Bool`, `package func showBriefDay(_ date: String) async` (selects the Morning brief entry, sets `briefDate` — nil for today —, marks that day's briefing read through the existing `select(.day(date))` write when unread: the owner's pick), `package func stepBrief(_ step: InboxBriefDays.Step) async`, `package func openBriefHistory()` (selects Morning brief, `briefHistoryShown = true`). A `.day(date)` route (Home's link, a notification) calls `showBriefDay(date)` after the existing page loop.

- [ ] **Step 1: Write the failing tests** — `InboxBriefDaysTests`: `testHistoryIsThirtyDaysNewestFirst`, `testFirstPageCoversThirtyDays` (a briefing on each of 45 days → the first read's `feed.days` holds all 30 of the last 30 days and the Earlier line counts 29 past ones), `testStepOlderSkipsDaysWithoutACard`, `testStepNewerStopsAtToday`, `testStepFromThePlaceholderGoesToYesterday`. `InboxEntrySelectionTests` (pool + view model, `UserDefaults` suite): `testFirstReadSelectsTodaysBrief`, `testRefreshAloneWritesNoReadMark` (a `refresh()` with no `ownerArrived` leaves today's briefing `read_at` NULL — STRIP-02), `testOwnerArrivalMarksTheShownBriefRead` (`ownerArrived()` → `read_at` set, the root count drops by 1), `testPollAfterArrivalWritesNothing`, `testMidnightMovesTheBriefToToday` (clock moved past midnight, a refresh with no database change → the selection is `day:<new today>`, no read mark written, and `folderMenu.snapshot.peopleWaitingToday` drops yesterday's items), `testRestoreLastEntryPerFolder` (pick an artifact in the root and another in an owner folder, switch folders → each restores its own), `testRestoreFallsBackWhenTheSavedEntryIsGone` (saved artifact deleted → today's brief; owner folder → its first entry), `testRestoreNeverOpensALegacyList` (saved `tracks` → today's brief, `legacyList == nil`), `testEmptyFolderSelectsNothing`, `testShowBriefDayMarksThatDayRead`, `testDayRouteOpensTheBriefOnThatDay` (replaces the old "selected day stays listed" expectations in `InboxRouteTests`).
- [ ] **Step 2: Run** `make test-swift FILTER='InboxBriefDaysTests|InboxEntrySelectionTests|InboxRouteTests|ActionStripAllKindsTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; `make test-swift FILTER='ActionStripViewModelTests|ActionStripAutomationOutputTests'` stays green (STRIP-02: `testRefreshIsAPureRead`, `testRefreshIsStillOnePureRead`); `make lint-swift`.
- [ ] **Step 5: Commit** `feat(inbox): remember the entry per folder, open today's brief (#1076)`.

### Task 9: The list column — rows, sections, Earlier line, search

**Depends on:** Task 3, Task 5, Task 6, Task 7

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Inbox/InboxTile.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxListFilter.swift`
- Rename: the legacy lists' row `InboxListRow` (`Sources/Views/Inbox/InboxListRow.swift`) → `InboxLegacyListRow` in `Sources/Views/Inbox/InboxLegacyListRow.swift` (callers `InboxSplitView`, `InboxReadingPaneTests`)
- Create: `WatchtowerDesktop/Sources/Views/Inbox/InboxListRow.swift` (the new row, replacing `InboxFolderListRowView`)
- Modify: `.../Views/Inbox/Folders/InboxFolderContentList.swift` (sections, Earlier line, no-match line, approval group counts), `.../Views/Inbox/Folders/NeedsApprovalPane.swift` + the stack in `.../Views/Inbox/ActionStripView.swift` (a header per group with **Approve All N…**, scroll to a group), `.../Services/Actions/ActionStripViewModel.swift` (`listQuery`, filtered `folderList`)
- Tests: `Tests/Core/InboxListFilterTests.swift`, `Tests/InboxListRowTests.swift`, `Tests/InboxFolderContentListTests.swift` (create or extend), update `Tests/InboxLegacyEntryMenuTests.swift`

**Interfaces:**
- Consumes: `InboxRowContent`, `InboxListSection`, `InboxEarlierLine`, `NeedsApprovalGroup`, `ActionStripViewModel.approveAllModel(_:)`, `InboxBulkPressButton`, `PaneWidth.inboxList*`, `IconSize.listTile`.
- Produces:
  - `struct InboxTile: View { init(kind: InboxRowKind, symbol: String? = nil, size: CGFloat = IconSize.listTile); static func tint(_ kind: InboxRowKind) -> Color; static func symbol(_ kind: InboxRowKind) -> String }` — tints per Global Constraints; symbols: brief `sun.max`, peopleWaiting `person.2`, mailWaiting `envelope`, slackToday `number`, threads `bubble.left.and.bubble.right`, ideas `lightbulb`, approval `checkmark.seal`, artifact `folder`; tint fill at `ChipTint.fillOpacity`, `Radius.row` corners; selected rows draw the plate at `Fill.card` so the tile keeps its colour.
  - `struct InboxListRow: View { init(content: InboxRowContent, isSelected: Bool, menu: [InboxMenuEntry] = [], contextEntries: [InboxMenuEntry] = [], onMenu: @escaping (InboxMenuCommand) -> Void = { _ in }) }` — tile, title (body, semibold) with the accent unread dot (`IconSize.stateDot`) before it, preview (`.secondary`, 2 lines), meta (`.caption`, `.tertiary`, 1 line), trailing time (`.caption.monospacedDigit()`) above the pill; `.kitRow(isSelected:)`; `Spacing.tight` between rows; the row's ⋯ (Idea finder) is an overlay on the trailing edge shown on hover/focus by opacity, so the row never changes height; accessibility: one combined element "title, preview, N" plus "Unread".
  - `package enum InboxListFilter { static func matches(_ content: InboxRowContent, query: String) -> Bool; static func apply(_ sections: [InboxListSection], query: String) -> [InboxListSection] }` — trimmed query; empty matches all; case- and diacritic-insensitive `localizedStandardContains` on title + preview; empty sections dropped.
  - `ActionStripViewModel.listQuery: String` (one value for every folder, kept across navigation); `folderList` applies the filter and hides `earlierLine` while the query is non-empty; the selection is never cleared by filtering.
  - `InboxFolderContentList`: a `List` with one `Section` per `InboxListSection` (header: small caps title as in `SectionHeader`; for an approval group, its count); Needs approval's stack (`NeedsApprovalPane`) draws a header per group above its cards, and when `approveAllIDs` is non-nil that header carries `InboxBulkPressButton(title: "Approve All \(n)…", confirmTitle: { "Approve All \($0)" }, model:)`; a list row of id `group:<raw>` scrolls the stack to that header; the Earlier line as a last quiet row (a button calling `vm.openBriefHistory()`); while filtering with no rows, "No matches for “<query>”" in place of the folder's empty state.

- [ ] **Step 1: Write the failing tests** — `InboxListFilterTests`: `testFilterIgnoresCaseAndDiacritics` ("cafe" matches "Café"), `testFilterMatchesPreviewToo`, `testEmptyQueryKeepsEverything`, `testEmptySectionsAreDropped`. `InboxFolderContentListTests` (ViewInspector): `testSectionsDrawInOrder`, `testEarlierLineOpensHistory`, `testNoMatchKeepsSelection` (query with no match → no-match line; clearing it → rows back, selection unchanged), `testApproveAllOnlyOnEligibleGroups` (the stack's group header has the button for 3 `create_track`, none for 3 Slack sends or 3 connector calls), `testGroupRowScrollsToItsHeader`. `InboxListRowTests`: `testUnreadDotAndPill`, `testTileTintsPerKind` (the eight kinds → the tints above), `testHoverMenuKeepsRowHeight` (the row's frame height with and without the ⋯ is equal). Update `InboxLegacyEntryMenuTests` to `InboxListRow`.
- [ ] **Step 2: Run** `make test-swift FILTER='InboxListFilterTests|InboxFolderContentListTests|InboxListRowTests|InboxLegacyEntryMenuTests|InboxReadingPaneTests'` — FAIL.
- [ ] **Step 3: Implement** (rename first, then the new row, then the list).
- [ ] **Step 4: Run** — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(inbox): urgency sections and content rows in the list (#1076)`.

### Task 10: Layout — rail, columns, one title with search, pane header

**Depends on:** Task 2, Task 3, Task 8, Task 9

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Inbox/InboxPaneHeader.swift`, `WatchtowerDesktop/Sources/App/PanelToggleCommands.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/PanelToggleTarget.swift`
- Modify: `.../Views/Inbox/ActionStripView.swift` (columns, header row removed, `.searchable`, panes under `InboxPaneHeader`), `.../Views/Inbox/InboxSplitView.swift` (same column tokens; `inboxPaneWidth` removed), `.../Views/Inbox/InboxReadingPane.swift` (`InboxCardColumn.readableWidth` → `ReadableColumn.maxLineWidth`; an artifact's title row hidden under the pane header), `.../Views/Inbox/InboxArtifactCard.swift` (`showsTitleRow: Bool = true`), `.../Views/Inbox/Folders/InboxFolderMenu.swift` + `.../Services/Inbox/InboxFolderMenuContent.swift` (Folders heading rule, bottom row), `.../Views/Inbox/Folders/NeedsApprovalPane.swift` (`?` in its header), `WatchtowerDesktop/Sources/App/WatchtowerApp.swift` (register `PanelToggleCommands`), `WatchtowerDesktop/Sources/App/WorkbenchCommands.swift` (its ⌥⌘S item moves out), `.../WatchtowerCore/Models/KeyboardShortcutCatalog.swift` (Inbox area), `docs/guide/reference/keyboard-shortcuts.md`
- Tests: `Tests/InboxPaneHeaderTests.swift`, `Tests/Core/InboxFolderMenuContentTests.swift` (extend), `Tests/Core/KeyboardShortcutCatalogTests.swift` (extend), `Tests/Core/PanelToggleTargetTests.swift`, `Tests/InboxLayoutTests.swift`

**Interfaces:**
- Consumes: `InboxTile`, `InboxListRow`, `PaneWidth.inboxList*`, `ReadableColumn.maxLineWidth`, `ActionStripViewModel.listQuery`.
- Produces:
  - `struct InboxPaneHeader<Actions: View>: View { init(tile: InboxTile, title: String, subtitle: String, @ViewBuilder actions: () -> Actions) }` (shared — phases 2 and 3 use it): the tile at `IconSize.listTile`, title `.title3.weight(.semibold)`, subtitle `.callout` `.secondary` under it, actions trailing with `Spacing.small` between them; the subtitle wraps, the actions never do.
  - `InboxFolderMenuContent.showsFoldersHeading: Bool` — true iff at least one owner-folder row is drawn; the rail then shows "Folders" above the owner folders, else Inbox and Needs approval only. The bottom row: **New Artifact…** (`.kitQuiet`) and an icon button `folder.badge.plus` (help "New Folder") in one `HStack`.
  - **⌥⌘S checked against the existing shortcuts:** it is already the Workbench menu's Show Sessions Panel (`WorkbenchCommands.swift`). The chord keeps one meaning — "show or hide this screen's side panel" — and gets **one** menu item, so no two menu items ever carry the same key equivalent (no reliance on AppKit skipping a disabled duplicate). `package enum PanelToggleTarget: Equatable { case workbenchSessions(isShown: Bool), inboxFolders(isShown: Bool) ; var title: String; static func resolve(workbenchCanToggle: Bool, workbenchPanelShown: Bool, inboxOnScreen: Bool, inboxRailHidden: Bool) -> Self? }` — the workbench wins when its page has the keys (today's `canTogglePanel`), else the Inbox when `appState.selectedDestination == .inbox`, else nil. Titles: "Show Sessions Panel" / "Hide Sessions Panel" (today's `panelToggleTitle`), "Show Inbox Folders" / "Hide Inbox Folders".
  - `struct PanelToggleCommands: Commands` — `CommandGroup(after: .sidebar)` in the View menu (the `ItemShortcutCommands` precedent for a chord shared by two screens): one button titled by `resolve(...)`, ⌥⌘S, disabled when nil; it toggles the workbench's `panelVisible` or `inbox.railHidden`. The Workbench menu's own ⌥⌘S button is removed (its action is this item's); the Workbench catalog note says ⌥⌘S is in the View menu.
  - `KeyboardShortcutCatalog` Inbox area gains `Entry("⌥⌘S", "Show or hide the Inbox folders")`; the Workbench entry stays (same chord, its own area).
  - Columns in `ActionStripActionsView.body`: `HSplitView { rail (left out while hidden; kit side-list frame) ; list (minWidth inboxListMin, idealWidth inboxListIdeal, maxWidth inboxListMax) ; pane (minWidth PaneWidth.detailMin, maxWidth .infinity) }` for the root, owner folders and Needs approval (whose pane is the stack); the error banner stays above all three. `InboxSplitView` uses the same list frame.
  - The header row ("Inbox" + `?`) is removed; `ActionStripView` keeps `.navigationTitle("Inbox")` and adds `.searchable(text: $vm.listQuery, placement: .toolbar, prompt: "Search the Inbox")`. The `?` (reaction commands, id `actionStrip.cheatSheetButton`) moves to the trailing end of every `InboxPaneHeader` and of `NeedsApprovalPane`'s header; the empty root keeps its inline cheat sheet.
  - Panes in the root and owner folders: an artifact → `InboxPaneHeader(tile: InboxTile(kind: row.content.kind, symbol: row.content.symbol), title, subtitle: the card's provenance line, actions: **Run Now** (`.kitSecondary`, only when its ⋯ lists `.runNow`; `artifactMenu.perform(.runNow, on:)`), its ⋯ (`InboxMoreMenu`), `?`)` over the card with `showsTitleRow: false`; a thread brief → header with `?` only. The Morning brief's header is Task 11's.

- [ ] **Step 1: Write the failing tests** — `InboxFolderMenuContentTests`: `testFoldersHeadingOnlyWithOwnerFolders` (seed tree → false; one owner folder → true; only hidden owner folders with Show Hidden off → false). `KeyboardShortcutCatalogTests`: `testInboxRailChordIsListed`. `PanelToggleTargetTests`: `testWorkbenchWinsWhenItHasTheKeys`, `testInboxWhenOnScreen`, `testNilElsewhere`, `testTitles`. `InboxPaneHeaderTests` (ViewInspector): `testTitleSubtitleAndActions`, `testArtifactHeaderShowsRunNowOnlyWhenOffered`. `InboxLayoutTests`: `testRailHiddenLeavesTwoColumns` (default `inbox.railHidden = true` in a suite → no `InboxFolderMenuColumn` found), `testNoInboxTitleRowOverTheList` (no `Text("Inbox")` inside `ActionStripActionsView`), `testReadingColumnIsTheReadableWidth` (`InboxCardColumn.readableWidth == ReadableColumn.maxLineWidth`).
- [ ] **Step 2: Run** `make test-swift FILTER='InboxFolderMenuContentTests|KeyboardShortcutCatalogTests|PanelToggleTargetTests|InboxPaneHeaderTests|InboxLayoutTests'` — FAIL.
- [ ] **Step 3: Implement**; regenerate `docs/guide/reference/keyboard-shortcuts.md`'s "By area" from `KeyboardShortcutCatalog.markdown` (`testTheGuideMatchesTheTable`).
- [ ] **Step 4: Run** — PASS; `make test-swift FILTER='InboxReadingPaneTests|ActionStripFolderPaneTests|InboxArtifactCardTests'` stays green; `make lint-swift`.
- [ ] **Step 5: Manual check (Release build, noted in the PR):** ⌥⌘S on the Inbox hides and shows the rail; on a workbench page it still toggles the sessions panel; the View menu shows one item titled for the screen. The search field sits next to the one "Inbox" title.
- [ ] **Step 6: Commit** `feat(inbox): three-column layout, one title with search, pane header (#1076)`.

### Task 11: The Morning brief pane — stepper, History, the mockup's order

**Depends on:** Task 8, Task 10

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxBriefLayout.swift`, `WatchtowerDesktop/Sources/Views/Inbox/InboxBriefHistory.swift`
- Modify: `.../Views/Inbox/InboxDayPane.swift` (header → `InboxPaneHeader`, section order), `.../Views/Briefings/BriefingSectionsView.swift` (`parts`), `.../Views/Inbox/ActionStripView.swift` (`readingPane`'s `.legacyDay` uses `vm.briefDay`), `.../Services/Inbox/InboxFolderEntries.swift` (brief row preview through `InboxBriefLayout.lead`)
- Tests: `Tests/Core/InboxBriefLayoutTests.swift`, update `Tests/InboxDayPaneTests.swift`

**Interfaces:**
- Consumes: `InboxPaneHeader`, `InboxTile`, `InboxBriefDays`, `ActionStripViewModel.briefDate/briefDay/stepBrief/showBriefDay/briefHistoryShown`.
- Produces:
  - `package enum InboxBriefLayout { static func lead(_ briefing: Briefing) -> String?; static func startHere(_ briefing: Briefing) -> [AttentionItem]; static func waitingOnYou(_ messages: [HomeFeedInboxRow]) -> [HomeFeedInboxRow]; static func movedOvernight(_ tracks: [InboxTrackCard]) -> [InboxTrackCard] }` — lead = the first attention item's text, else the first your-day item's text, else nil; startHere = the first three attention items; waitingOnYou = the three newest open messages; movedOvernight = up to three unread tracks, newest event first.
  - `BriefingSectionsView(briefing:parts:onOpen:onMakeTask:)` with `enum BriefingPart: Equatable { case attention(from: Int, limit: Int?), yourDay, whatHappened, teamPulse, coaching }`; the default `parts` is today's order (`.attention(from: 0, limit: nil)`, `.yourDay`, `.whatHappened`, `.teamPulse`, `.coaching`), so other callers are unchanged.
  - Pane order: `InboxPaneHeader(tile: .brief, title: "Morning brief", subtitle: "<EEEE, d MMMM> · written HH:mm", actions: stepper ‹ date ›, **History**, Discuss in Chat (today's existing action), `?`)`; then the lead card (lead + **Start here**: attention 0..<3 with their existing actions); **Your day** (`InboxDayPlanBlock` + `.yourDay`, a `Chip` "N conflicts" in `Tone.error` when `plan.hasConflicts`); **Waiting on you** (three rows, link "All in Waiting for me" selecting that entry; left out when empty); **Moved overnight** (link "Track my threads" opening that entry; left out when empty); then `.attention(from: 3, limit: nil)` under "More for today", `.whatHappened`, `.teamPulse`, `.coaching`. Today's placeholder and Make buttons are unchanged.
  - Stepper: "‹" calls `stepBrief(.older)` (disabled when `step` is nil), "›" `stepBrief(.newer)` (disabled on today), the date label `EEE d MMM`. **History** = a button opening a popover (`.popoverSurface()`) bound to `vm.briefHistoryShown`, listing `InboxBriefDays.history` (date label, an accent dot on unread ones); a pick calls `showBriefDay(date)` and closes it. Waiting on you / Moved overnight are drawn on today's brief only.

- [ ] **Step 1: Write the failing tests** — `InboxBriefLayoutTests`: `testLeadFallsBackToYourDay`, `testLeadNilWhenEmpty`, `testStartHereIsTopThree`, `testWaitingOnYouTopThreeNewest`, `testMovedOvernightUnreadOnly`. `InboxDayPaneTests`: `testHeaderStepperDisablesNewerOnToday`, `testHistoryListsUnreadMarked`, `testSectionOrderFollowsTheMockup` (finds, in order, "Start here", "Your day", "Waiting on you", "Moved overnight"), `testPastDayHidesTodayOnlySections`, the existing Make-button tests kept.
- [ ] **Step 2: Run** `make test-swift FILTER='InboxBriefLayoutTests|InboxDayPaneTests|BriefingSectionsViewTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(inbox): one Morning brief with a day stepper and History (#1076)`.

### Task 12: Feature note, CLAUDE.md line, guide pages

**Depends on:** Task 4, Task 7, Task 10, Task 11

**Files:**
- Create: `docs/features/inbox-redesign.md`
- Modify: `CLAUDE.md` (Feature Notes), `docs/features/inbox-folders.md` (pointer lines), `docs/guide/features/inbox.md`, `docs/guide/features/briefings.md` (past briefs), any other `docs/guide` page a grep for "Morning brief", "badge" or "unread day" shows stating the old rule

**Interfaces:**
- Produces: the note's sections — header (board #1076 under #917, spec, mockup, shots `inbox-r-*`, guide pages), **Phase 1 (shell)**: Sidebar; Layout (tokens, rail collapse + key, one title + search, `InboxPaneHeader`, reading column); The list (`InboxRootSections`, `InboxRowContent` table, `InboxListFilter`); Counts and badge (the terms, `InboxToday` + fixture, the interim rule); Selection (`inbox.entry.<folderID>`, `defaultEntry`, a default pick marks read only on the owner's arrival, the midnight rollover and recount); Morning brief (`rootDays` today only, Earlier line, `InboxBriefDays`, stepper/History marks read on the owner's pick, `InboxBriefLayout` order); Needs approval (`NeedsApprovalGroups`, one row per bulk group, Approve All via `InboxBulkPressModel` over the tool allowlist); Shared components for phases 2–3 (`InboxToday`, `InboxBulk*`, `InboxListRow`/`InboxRowContent`, `InboxRootSections`, `InboxPaneHeader`); **Phase 1 alone** (the interim list from Global Constraints); v1 limits (search filters loaded rows only; Track my threads / Idea finder / Messages still open today's legacy lists; ⌥⌘S is one View-menu item shared with the Workbench's sessions panel; the mockup's All / Unread, By kind / Oldest and "updated N min ago" are not built); Inventory (STRIP badge amendment, APPROVAL-01 note). Later phases append their sections.
- CLAUDE.md line, after the "Built-in automations" line: "- [Inbox redesign — sections by urgency, one brief, counts you can act on (2026-11, board #1076; phase 1 shell)](docs/features/inbox-redesign.md) — Inbox at the sidebar root (Targets in FOCUS), rail collapse ⌥⌘S, list column tokens, one title + search filter, `InboxRootSections` (Needs you → Today → Running → Earlier line), `InboxRowContent`/`InboxListRow`, badge = Needs approval + people waiting today (`InboxToday`, shared fixture `internal/inbox/testdata/from_today.json`; STRIP badge amendment, ask #634), per-folder selection memory, one Morning brief row with stepper + History, Needs approval groups + Approve All (`InboxBulkPressModel`, reused by phases 2–3), `InboxPaneHeader`."

- [ ] **Step 1: Write the note and the CLAUDE.md line.** In `docs/features/inbox-folders.md`, under "The root and the legacy entries" and "v1 limits", add one line each: "Superseded by the Inbox redesign phase 1 (`inbox-redesign.md`): one Morning brief row with past days inside it; the badge rule." and drop the "A read past brief has no list entry" limit.
- [ ] **Step 2: Guide** (`docs/guide/WRITING.md` rules): `inbox.md` — "What the root holds" → the four sections and what each row shows; "What the badge counts" → Needs approval + people waiting today (since midnight), mail never; a new `### Read an earlier brief` (stepper, History, the Earlier line); "Needs approval" → groups and **Approve All N…** (never for messages); the rail's ⌥⌘S and the search field; state the phase-1 interim plainly ("Until Mail waiting arrives, Waiting for me counts mail from today too"). Learn cards: new `inbox-brief-history` (area communication, level next, kind tip, `since: next`, `action: nav:inbox`) and `inbox-approve-all` (kind feature); any existing card under a changed heading whose text states the old rule gets a new card with `replaces:`. `briefings.md`: where past briefs live now.
- [ ] **Step 3: Run** `go test ./internal/learn/` and `go test ./docs/guide/` — PASS.
- [ ] **Step 4: Commit** `docs(inbox): redesign phase 1 note, guide pages (#1076)`.

### Task 13: Design shots `inbox-r-*`

**Depends on:** Task 7, Task 9, Task 10, Task 11

**Files:**
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+InboxRedesign.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift` (append `InboxRedesignShotFixtures.shots`), `WatchtowerDesktop/Tests/DesignShots/DesignShotsTests.swift` (`testInboxRedesignShotsRender`)

**Interfaces:**
- Consumes: the wired `ActionStripActionsView` over a seeded test database (the `InboxApprovalsShotFixtures` pattern: own `UserDefaults` suite, fixed `now`, `cleanUp()`), sample data `acme` / `example.com` / "Colleague A…" only.
- Produces (each rendered light and dark by `make desktop-shots`): `inbox-r-root` (all sections, today's brief selected, Earlier line), `inbox-r-root-rail-hidden`, `inbox-r-brief-past-day` (stepper on a past day), `inbox-r-brief-history` (History open), `inbox-r-approvals-groups` (three Messages rows + one "Create 3 tracks" row, the stack's group header with **Approve All 3…**), `inbox-r-approve-all-partial` ("Closed 1 of 3. …" + Try Again), `inbox-r-owner-folder` (Today + Earlier), `inbox-r-search-no-match`, `inbox-r-sidebar` (the sidebar with Inbox at the root and its badge, Targets in FOCUS).

- [ ] **Step 1: Add the fixtures, catalog entries and the render test.**
- [ ] **Step 2: Run** `make test-swift FILTER=DesignShotsTests/testInboxRedesignShotsRender` — PASS (and `testShotNamesAreUnique`).
- [ ] **Step 3: Render** `make desktop-shots DESKTOP_SHOTS=<scratch dir>`, look at every `inbox-r-*` PNG in both modes against the mockup (tile keeps its tint when selected, no layout jump, one prominent action), and attach them to the PR.
- [ ] **Step 4: Commit** `test(inbox): redesign phase 1 design shots (#1076)`.

---

## Dependency graph

1 → 4 → 6; 5 + 6 → 7; 6 → 8; 3 + 5 + 6 + 7 → 9; 2 + 3 + 8 + 9 → 10; 8 + 10 → 11; 4 + 7 + 10 + 11 → 12; 7 + 9 + 10 + 11 → 13. Independent starts: 1, 2, 3, 5. Tasks 6–11 edit `ActionStripViewModel.swift` / `ActionStripView.swift`: they run in one lane in order 6 → 7 → 8 → 9 → 10 → 11 (7 and 8 may run in parallel lanes only if the controller merges their `ActionStripViewModel` hunks).

## Plan's calls (not settled by the spec)

- **Read marks of the automatic pick.** A default or restored pick made inside `refresh()` writes nothing (STRIP-02). The owner's arrival — opening the Inbox, picking a folder — is a gesture: the brief or artifact that the pick put on screen is marked read then, as "a brief is read once opened" says (Task 8, `ownerArrived`). Polls and the midnight rollover never mark anything.
- **A remembered legacy-list entry (Track my threads, Idea finder, Messages) is not restored** in phase 1: today those entries swap the list column for a legacy list and their reading pane is empty until a card is picked, so restoring one would break "never an empty pane". The Inbox opens today's brief instead. Phase 3 replaces those lists with in-pane views; its plan restores them.
- **Needs approval keeps its stack in the reading pane** (every open approval's card stays drawn, APPROVAL-01 wording untouched) and gains the grouped list column. As in the mockup, a group that can be approved in bulk is one list row; other groups list one row per item. The notices and the approved-and-running rows, already drawn by the stack today, get the headings "Built-in updates" (first) and "Approved, still running" (last). Reminders get no Approve All because a reminder has no Approve (Done / Snooze only).
- **Approve All is an allowlist** of tools that never send text to a person (Task 7); connector calls and any unknown or future tool fall in Other without it, so "messages to people one by one" holds for every tool.
- **⌥⌘S** was checked against the existing menus: the Workbench's Show Sessions Panel already uses it. It stays one chord with one meaning ("this screen's side panel") on one View-menu item resolved per screen (Task 10), so two menu items never share a key equivalent.

## Mockup elements left out of phase 1

- The list header's **All / Unread** switch and its "updated N min ago" line: the spec does not name them, and the unread dot plus urgency sections already answer "what is new"; a sync time is on Home and the status bar.
- Needs approval's **By kind / Oldest** switch: the spec fixes one order (by kind, groups by their oldest item, oldest first inside); a second order has no spec behaviour behind it.
- Each can come back as its own small change if the owner wants it; none is drawn half-working in phase 1.
