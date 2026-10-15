# First run P2 — Home: Getting ready + Today — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **House override (owner rule):** this plan has no code bodies. It gives
> exact type and function signatures, the named test cases and what each
> asserts. The implementer writes the bodies TDD-style from these.

**Goal:** The app opens on a new permanent first tab, **Home**. Its top zone,
**Getting ready**, shows what Watchtower is preparing from the owner's sources
and folds away once everything is ready. Below it, **Today** gathers what other
tabs already hold — who waits on you, the next meeting, the briefing, your
targets, agent asks, the recap — each card a link into its tab.

**Architecture:**
- **WatchtowerCore (pure, `Tests/Core`).**
  - `GettingReadyPolicy` turns the P1 readiness map plus a small persisted
    memory (hidden / first shown / completed) into one `GettingReadyZone`.
  - `HomeQueries.today` reads every Today source in one `pool.read`, through
    existing queries plus four new ones (`TargetQueries.homeSummary`,
    `OwnerAskQueries.openAsksAllWorkbenches`, `AgentActionQueries.awaitingOwner`,
    `CalendarQueries.hasPrep`).
  - `HomeTodayBuilder` turns that read into the ordered `[TodayCard]`;
    `HomeSnapshot` holds both zones.
- **Desktop.**
  - `HomeCenter` on `AppState` owns the snapshot. It re-reads on a GRDB
    `ValueObservation` of the Today tables, on a 30 s tick (the daemon writes
    from another process), and on any change of `ReadinessCenter.readiness` or
    the other observable inputs it reads. It survives tab switches.
  - `HomeView` renders the header, the two zones and the empty line, and
    routes every click through `AppState.openHomeLink`.
  - `SidebarDestination.home` is the first root item, the launch default, the
    fallback and the onboarding landing.
- **No writes, no CLI, no AI.** The only state Home writes is three per-install
  `UserDefaults` keys for Getting ready.

**Tech Stack:** SwiftUI macOS 14+, GRDB, XCTest + ViewInspector (`ViewRenderProbe` pattern). No Go change, no migration.

**Spec:** `docs/superpowers/specs/2026-10-14-first-run-home-design.md` §3 (Home), §5 P2 tests, §6 decisions 2, 3, 5, 7. Built on P1 as described in `docs/features/first-run.md`. Visual design: owner-approved Home mockup (ask #304, board #784). P3 (Try this → Recent work, spec §3.3/§4) is **out of scope**; nothing is stubbed for it.

## Global Constraints

- UI text is English only. Board, asks and comments are in Russian; the repo is English.
- Public repo hygiene: fixtures use `acme`, `example.com`, "Colleague A"; no real ids or names.
- Home composes nothing: no AI call, no CLI call, no DB write. Every Today card reads an existing table.
- No counters anywhere ("N of M", progress bars, scores). A count in a Today card's eyebrow ("WAITING ON YOU · 4") is the size of a list the owner must act on, not progress, and is allowed by the mockup.
- Readiness wording is P1's (`FeatureReadiness.line`/`phrase`). Home never invents a new ETA phrase or a countdown for readiness. The Next meeting eyebrow ("IN 25 MIN") is a calendar time, not a readiness ETA.
- Readiness on Home goes through `FeatureReadiness.honoringOwner` exactly like the tabs' empty states (OWNER-02): while the owner is unknown, a briefing/day plan/inbox card has no readiness line.
- Async state lives on `AppState` (`HomeCenter`), never in a view; the test exercises start → navigate away → result lands (review-rules "Lifecycle & state").
- A Today card shows only with content. Order is fixed: Waiting on you, Next meeting, Briefing, My targets, Agents waiting, Since you were away.
- Every read error is logged (`NSLog`) and hides only its own card; it never blanks the page and never shows as "Nothing needs you right now" by itself (see Review Focus 3).
- Inner loop only per task: `make test-swift FILTER=<Class>`, `make lint-swift` (and `make lint-diff` if Go is touched — it is not planned). The full gate runs once at the end (Task 11).

## Review Focus

1. **Existing installs open on Home** (decision 2). An established install whose features are all ready must not see a one-off "Everything's ready" line on its first launch with Home — it never was getting ready. Pinned in Task 4: `testAllReadyAtFirstLookIsHiddenNotAllReady`.
2. **Getting ready never sticks.** A feature that stays `scheduled`/`error` for days (memory off-cycle, a broken Jira token) must not pin the zone open: error counts as terminal, and the zone folds 3 days after it was first shown (decision 5). Pinned in Task 4: `testErrorCountsAsTerminal`, `testFoldsThreeDaysAfterFirstShown`.
3. **A failing read is not "nothing needs you".** If the Today read throws for one card, the other cards still show and the error is logged; if every card read failed, Home shows the read error, not the all-clear line. Pinned in Task 5: `testOneFailingCardKeepsTheOthers`; Task 6: `testAllReadsFailedIsNotAllClear`.
4. **Workbench targets stay off Home** (PROJ-01). `homeSummary` filters `project_id IS NULL`. Pinned in Task 2: `testProj01_HomeSummaryNeverReturnsAProjectTarget`.
5. **Navigation.** The landing, the launch default and the fallback all become Home; a setup re-run still keeps the tab; the existing deep links (notifications, mobile hub, Quick Capture) keep landing where they did. Pinned in Task 1.

---

## File Structure

**WatchtowerCore**
- `Sources/WatchtowerCore/Database/Queries/TargetQueries.swift`: add `homeSummary`.
- `Sources/WatchtowerCore/Database/Queries/OwnerAskQueries.swift`: add `WorkbenchAskRow`, `WorkbenchAskRows`, `openAsksAllWorkbenches`.
- `Sources/WatchtowerCore/Database/Queries/AgentActionQueries.swift`: add `awaitingOwner(_:limit:)`.
- `Sources/WatchtowerCore/Database/Queries/CalendarQueries.swift`: add `hasPrep(_:eventID:)`.
- `Sources/WatchtowerCore/Models/Workbench.swift`: add `WorkbenchRoute.forAsk(projectID:sessionID:askID:)`.
- `Sources/WatchtowerCore/Services/WorkbenchNotificationPolicy.swift`: use `WorkbenchRoute.forAsk` (no behaviour change).
- `Sources/WatchtowerCore/Services/EmptyStateCopy.swift`: add `FeatureCardCopy`, `EmptyStateCopyTable.featureCard(_:briefingHour:dayPlanHour:)`; add `"home"` to `exempt`.
- `Sources/WatchtowerCore/Services/OnboardingFinishPlan.swift`: delete `Landing` and `landing(goals:catchUpVisible:)`.
- `Sources/WatchtowerCore/Models/Home.swift` (new): `GettingReadyMemory`, `GettingReadyCard`, `GettingReadySourceRow`, `GettingReadyZone`, `ReadinessTone`, `HomeLink`, `TodayCardKind`, `TodayCard` and its row types, `HomeTodayData`, `HomeSnapshot`.
- `Sources/WatchtowerCore/Services/GettingReadyPolicy.swift` (new).
- `Sources/WatchtowerCore/Database/Queries/HomeQueries.swift` (new).
- `Sources/WatchtowerCore/Services/HomeTodayBuilder.swift` (new): the cards and their wording.

**Desktop**
- `Sources/App/SidebarDestination.swift`: `.home`, `rootItems`, `fallbackDestination`.
- `Sources/App/AppState.swift`: default `.home`; `land(after:)`; `homeCenter`; `pendingCalendarEventID` + `navigateToCalendarEvent`; start/stop wiring.
- `Sources/App/AppState+Home.swift` (new): `openHomeLink(_:)`, `firstSyncLine`, `homeTodayCardsAllowed`, `homeDestination(for:)`.
- `Sources/App/Navigation.swift`: `case .home`; `catchUpFirstSync` → `appState.firstSyncLine`.
- `Sources/Views/Calendar/CalendarEventsView.swift`: consume `pendingCalendarEventID` through the existing `openLinkedEvent` path.
- `Sources/Services/HomeCenter.swift` (new): `HomeCenter`, `HomeEnvironment`, `LiveHomeEnvironment`, `GettingReadyStore`.
- `Sources/Views/Home/HomeView.swift`, `GettingReadyZoneView.swift`, `TodayZoneView.swift`, `TodayCardView.swift` (new).
- Tests (Desktop target): `HomeLandingTests`, `HomeCenterTests`, `HomeCenterSurvivesNavigationTests`, `HomeLinkTests`, `HomeViewTests`; updated `SidebarSectionTests`, `AppStateTests`, `EmptyStateCopyCoverageTests`.
- Tests (`Tests/Core`): `HomeQueriesTests` (new queries + `HomeQueries.today`), `GettingReadyTests`, `HomeTodayTests`, `FeatureCardCopyTests`; updated `OnboardingFinishPlanTests`, `WorkbenchTargetExclusionTests`, `WorkbenchNotificationPolicyTests` (unchanged assertions, run only).

**Docs:** `docs/features/first-run.md`, `docs/app-guide.md`, `docs/features/onboarding-v2.md`, `docs/onboarding-flow.md`, `CLAUDE.md`.

**Lanes.** Everything is Swift, so this is **one lane**, one Swift build at a time (CLAUDE.md: heavy Swift work stays one lane). The order below respects the dependencies; Tasks 2, 3 and 4 have no dependency on each other or on Task 1 and may be taken in any order inside the lane. Only Task 10 (docs, no build) may run in parallel with Task 9, in its own worktree, once Task 8's interfaces are merged.

---

## Task 1: `SidebarDestination.home` + landing on Home

**Goal:** Home exists as the first root item and is where the app opens, falls back and lands after onboarding. The view is a placeholder title so the switch compiles; Task 8 fills it.

**Files:**
- Modify: `Sources/App/SidebarDestination.swift` — `case home` (raw value `"home"`, title "Home", icon `house`); `rootItems` = `[.home, .targets, .tracks, .workbench, .calendar]`; `fallbackDestination` returns `.home` for any hidden `current` (the Inbox-else-Workbench rule goes; its doc comment says why: Home has no gate).
- Modify: `Sources/App/AppState.swift` — `selectedDestination` defaults to `.home` (line 19); `land(after:)` (line 1213) becomes `landOnHome()` setting `.home`; the call site at line 851 keeps `if !isRerun`.
- Modify: `Sources/WatchtowerCore/Services/OnboardingFinishPlan.swift` — delete `Landing` and `landing(goals:catchUpVisible:)`; the enum doc comment drops "Where the app opens".
- Modify: `Sources/WatchtowerCore/Services/EmptyStateCopy.swift` — `exempt` gains `"home"` (spec §1.5: Home is never empty).
- Modify: `Sources/App/Navigation.swift` — `case .home: HomeView()` (placeholder: `Text("Home")` with `navigationTitle`), so `detailView` stays exhaustive.
- Create: `Sources/Views/Home/HomeView.swift` (placeholder).
- Test: `Tests/HomeLandingTests.swift` (new); update the tests listed below.

**Interfaces:**
- Consumes: `OnboardingRoute`, `SidebarVisibility`.
- Produces:
  ```swift
  // SidebarDestination
  case home                          // first case, raw value "home"
  static var rootItems: [Self]       // [.home, .targets, .tracks, .workbench, .calendar]
  static func fallbackDestination(current:disabled:connected:) -> SidebarDestination? // nil while current shows, else .home
  // AppState
  var selectedDestination: SidebarDestination = .home
  private func landOnHome()          // replaces land(after:)
  ```
- `home.requiredFeatures` and `home.requiredSources` stay nil (the `default` arms), so Home is always visible and never hideable (root items have no hide menu).

**Existing tests to update (grep `landing(`, `fallbackDestination`, `rootItems`, `exempt`):**
- `Tests/Core/OnboardingFinishPlanTests.swift:51` `testLanding` — deleted with the API (its cases move to `HomeLandingTests`).
- `Tests/AppStateTests.swift:755` `testFinishLandsOnTheGoalsTab` — replaced by `HomeLandingTests.testFinishLandsOnHomeForEveryGoalSet` (same fixture loop, every case expects `.home`).
- `Tests/SidebarSectionTests.swift`:
  - `:32` `testRootItems` → `[.home, .targets, .tracks, .workbench, .calendar]`;
  - `:246` `testDevOnlyInstallSeesExactlyTheUngatedTabs` → the set gains `.home`;
  - `:253` `testDevOnlyFallbackIsWorkbench` → renamed `testDevOnlyFallbackIsHome`, expects `.home`;
  - `:262` `testFallbackPrefersInboxWhenItShows` → renamed `testFallbackIsHomeEvenWhenInboxShows`, expects `.home`;
  - `:303` `testJiraOnlyFallbackIsInbox` → renamed `testJiraOnlyFallbackIsHome`, expects `.home`;
  - `:384` `testFallbackDestinationSwitchesAwayWhenCurrentBecomesHidden` → expects `.home`;
  - `testEveryDestinationIsPlacedExactlyOnce` and `testRailGroupIconsAreDistinctFromItemIcons` pass unchanged (`house` is no rail icon) — run them.
- `Tests/EmptyStateCopyCoverageTests.swift:16` `testExemptListIsExactlyTheSpecs` → `["search", "usage", "mcpServer", "chat", "home"]`.
- Unchanged, must stay green: `AppStateTests.testUnchangedRerunFinishKeepsTheDaemonAndTheTab` (`:1088`), `NotificationRouteTests` (deep links), `FeatureEmptyStateViewTests` (CaseIterable sweeps).

- [ ] **Step 1: Write the failing tests** — `Tests/HomeLandingTests.swift`:
  - `testFinishLandsOnHomeForEveryGoalSet`: the old `testFinishLandsOnTheGoalsTab` fixture matrix plus `goals: []`. Asserts `selectedDestination == .home` for every case.
  - `testRerunKeepsTheCurrentTab`: a re-run that changed something (restart path) from `.targets`. Asserts `.targets` after finish.
  - `testLaunchDefaultIsHome`: `AppState.isolated(...)`. Asserts `selectedDestination == .home`.
  - `testFallbackIsHomeForAnyHiddenTab`: for every destination hidden under dev-only and under `connected: .none`. Asserts the fallback is `.home`.
  - `testHomeIsAlwaysVisible`: every disabled set × `connected` in `.none`, `.all`. Asserts `SidebarDestination.home.isVisible(...)`.
  - `testHomeIsTheFirstRootItem`: asserts `rootItems.first == .home` and `SidebarDestination.home.icon == "house"`.
- [ ] **Step 2: Run, expect FAIL.** `make test-swift FILTER='HomeLandingTests' > /tmp/p2t1.log 2>&1; echo "exit=$?"`
- [ ] **Step 3: Implement**, then update the existing tests listed above.
- [ ] **Step 4: Run, expect PASS.** `make test-swift FILTER='HomeLandingTests|SidebarSectionTests|OnboardingFinishPlanTests|AppStateTests|EmptyStateCopyCoverageTests|FeatureEmptyStateViewTests|NotificationRouteTests' > /tmp/p2t1.log 2>&1; echo "exit=$?"` — read XCTest failures above the swift-testing tail.
- [ ] **Step 5: Lint.** `make lint-swift`
- [ ] **Step 6: Commit.** `feat(desktop): Home tab — first root item, launch default, fallback and onboarding landing`

**Depends on:** none.

---

## Task 2: Spec-named queries — `homeSummary` and `openAsksAllWorkbenches`

**Goal:** The two new reads spec §3.2 names.

**Files:**
- Modify: `Sources/WatchtowerCore/Database/Queries/TargetQueries.swift`
- Modify: `Sources/WatchtowerCore/Database/Queries/OwnerAskQueries.swift`
- Test: `Tests/Core/HomeQueriesTests.swift` (new), `Tests/Core/WorkbenchTargetExclusionTests.swift` (add one guard)

**Interfaces:**
- Consumes: `Target`, `OwnerAsk(row:)`, `OwnerAskRows.fetch`'s row-by-row rule.
- Produces:
  ```swift
  extension TargetQueries {
      /// Home's "My targets": not on a board (PROJ-01), ownership 'mine', status in
      /// todo/in_progress/in_review/blocked, and (due_date set and due on or before
      /// `today`) or status = 'in_progress'. Due/overdue first by due_date, then
      /// in-progress by updated_at DESC. `today` is "yyyy-MM-dd" (local, like
      /// `todayDateString()`); the bound is `today + "T24:00"`, as `fetchCounts`.
      package static func homeSummary(_ db: Database, today: String, limit: Int = 5) throws -> [Target]
  }
  package struct WorkbenchAskRow: Equatable, Sendable {
      package let ask: OwnerAsk
      package let workbenchName: String
  }
  package struct WorkbenchAskRows: Equatable, Sendable {
      package var rows: [WorkbenchAskRow]
      package var unreadableIDs: [Int64]
  }
  extension OwnerAskQueries {
      /// Every workbench's open asks, oldest first (the order `openAsks` uses),
      /// joined to `projects.name`; a row `OwnerAsk(row:)` refuses is named in
      /// `unreadableIDs`, never blanks the others.
      package static func openAsksAllWorkbenches(_ db: Database) throws -> WorkbenchAskRows
  }
  ```
  `homeSummary` carries the `// BEHAVIOR PROJ-01` comment like `fetchAll`. Snoozed, done and dismissed targets never show.

- [ ] **Step 1: Write the failing tests.**
  - `Tests/Core/HomeQueriesTests.swift` (`TestDatabase.create()`; dates built from `Date()`, never hard-coded):
    - `testHomeSummaryPicksDueTodayOverdueAndInProgressMine`: rows due yesterday, due today 15:00, due tomorrow, in progress with no due date, todo with no due date. Asserts exactly the first, second and fourth, in that order.
    - `testHomeSummarySkipsOthersOwnership`: `delegated` and `watching` rows due today. Asserts empty.
    - `testHomeSummarySkipsClosedAndSnoozed`: done, dismissed, snoozed rows due today. Asserts empty.
    - `testHomeSummaryLimitsToFive`: seven due today. Asserts 5.
    - `testOpenAsksAllWorkbenchesSpansWorkbenches`: two workbenches, one open ask each, one answered ask. Asserts 2 rows, oldest first, each with its workbench's name.
    - `testOpenAsksAllWorkbenchesNamesUnreadableRows`: one row with an unknown `kind` written by raw SQL. Asserts it is in `unreadableIDs` and the readable row is still returned.
    - `testOpenAsksAllWorkbenchesEmpty`: asserts `rows.isEmpty && unreadableIDs.isEmpty`.
  - `Tests/Core/WorkbenchTargetExclusionTests.swift`: `testProj01_HomeSummaryNeverReturnsAProjectTarget` — a workbench target, mine, due today. Asserts `homeSummary` omits it (adds a guard; the contract is unchanged).
- [ ] **Step 2: Run, expect FAIL.** `make test-swift FILTER='HomeQueriesTests|WorkbenchTargetExclusionTests' > /tmp/p2t2.log 2>&1; echo "exit=$?"`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.** Same command, plus `OwnerAskQueriesTests`.
- [ ] **Step 5: Lint.** `make lint-swift`
- [ ] **Step 6: Commit.** `feat(core): Home queries — my targets due today, open asks across workbenches`

**Depends on:** none.

---

## Task 3: Supporting reads — awaiting proposals, meeting prep, ask route

**Goal:** The small reads and the shared route Today's other cards need, without copying view code.

**Files:**
- Modify: `Sources/WatchtowerCore/Database/Queries/AgentActionQueries.swift`
- Modify: `Sources/WatchtowerCore/Database/Queries/CalendarQueries.swift`
- Modify: `Sources/WatchtowerCore/Models/Workbench.swift`, `Sources/WatchtowerCore/Services/WorkbenchNotificationPolicy.swift` (line ~224 uses the new factory)
- Test: `Tests/Core/HomeQueriesTests.swift` (extend)

**Interfaces:**
- Consumes: `AgentActionQueries.notWorkbenchRow`, `ReminderQueries.fetchDue/dueCount`.
- Produces:
  ```swift
  extension AgentActionQueries {
      /// The rows `awaitingOwnerCount` counts (pending/failed, `notWorkbenchRow`), newest first.
      package static func awaitingOwner(_ db: Database, limit: Int) throws -> [AgentAction]
  }
  extension CalendarQueries {
      /// Whether `meeting_prep_cache` holds a non-empty prep for the event.
      package static func hasPrep(_ db: Database, eventID: String) throws -> Bool
  }
  extension WorkbenchRoute {
      /// An ask's landing: its session's terminal pane, or the board when it was
      /// filed outside the app (the rule `WorkbenchNotificationPolicy` uses).
      package static func forAsk(projectID: Int64, sessionID: Int64?, askID: Int64) -> WorkbenchRoute
  }
  ```
  Reading `agent_actions`/`reminders` this way is a pure read over the strip's two tables: STRIP-01/02 hold (`docs/inventory/reaction-commands.md`).

- [ ] **Step 1: Write the failing tests** (in `HomeQueriesTests`):
  - `testAwaitingOwnerMatchesTheBadgeCount`: pending, failed, applied, executing and one workbench-context row. Asserts `awaitingOwner(limit: 10).count == awaitingOwnerCount` and only pending/failed, newest first.
  - `testAwaitingOwnerLimit`: 5 pending, limit 3. Asserts 3.
  - `testHasPrepFalseForEmptyResult`: a cache row with `result_json = ''`. Asserts false; no row → false; a non-empty row → true.
  - `testAskRouteSessionOpensTerminal`: `forAsk(projectID: 1, sessionID: 7, askID: 3)`. Asserts `.terminal`, subject 7, ask 3; `sessionID: nil` → `.board`, no subject.
- [ ] **Step 2: Run, expect FAIL.** `make test-swift FILTER='HomeQueriesTests' > /tmp/p2t3.log 2>&1; echo "exit=$?"`
- [ ] **Step 3: Implement**; switch `WorkbenchNotificationPolicy.openedAsks` to `forAsk`.
- [ ] **Step 4: Run, expect PASS.** Same, plus `FILTER='WorkbenchNotificationPolicyTests|AgentActionQueriesTests'` (unchanged assertions).
- [ ] **Step 5: Lint.** `make lint-swift`
- [ ] **Step 6: Commit.** `feat(core): reads for Home — awaiting proposals, meeting prep, ask route`

**Depends on:** none.

---

## Task 4: Getting ready — feature card copy + `GettingReadyPolicy`

**Goal:** The pure rule for the Getting ready zone: which cards, which source rows, and when the zone is shown, collapsed to "Everything's ready", or gone.

**Files:**
- Modify: `Sources/WatchtowerCore/Services/EmptyStateCopy.swift` (feature card copy)
- Create: `Sources/WatchtowerCore/Models/Home.swift` (the Getting ready types)
- Create: `Sources/WatchtowerCore/Services/GettingReadyPolicy.swift`
- Test: `Tests/Core/FeatureCardCopyTests.swift`, `Tests/Core/GettingReadyTests.swift` (new)

**Interfaces:**
- Consumes: `ReadinessFeature` (its `allCases` order is the pipeline order), `Readiness`, `ReadinessSource`, `FeatureReadiness.honoringOwner`.
- Produces:
  ```swift
  package struct FeatureCardCopy: Equatable, Sendable {
      package let title: String      // "Digests"
      package let whatItIs: String   // one sentence
  }
  extension EmptyStateCopyTable {
      /// The Getting ready card text per tracked feature. Where a tab's row shows
      /// this feature, `whatItIs` IS that row's `landsHere` (hour filled in); the
      /// four features with no tab row of their own (slackSync, streamDigests,
      /// knowledgeIndex, jira) have their own sentence here.
      package static func featureCard(_ feature: ReadinessFeature, briefingHour: Int, dayPlanHour: Int) -> FeatureCardCopy
  }

  package enum ReadinessTone: Equatable, Sendable { case ready, preparing, waiting, error }
  package struct GettingReadyCard: Equatable, Sendable {
      package let feature: ReadinessFeature
      package let copy: FeatureCardCopy
      package let readiness: Readiness?   // nil = no line (before evaluation, or the owner gate)
      package var tone: ReadinessTone     // ready → .ready, preparing → .preparing, error → .error, else .waiting
      package var isTerminal: Bool        // ready or error
  }
  package struct GettingReadySourceRow: Equatable, Sendable {
      package let source: ReadinessSource
      package let features: [ReadinessFeature] // pipeline order
  }
  package enum GettingReadyZone: Equatable, Sendable {
      case hidden
      case allReady                                   // "Everything's ready", this launch only
      case shown(cards: [GettingReadyCard], sourceRows: [GettingReadySourceRow])
  }
  /// Persisted per install (UserDefaults, Task 6): the owner's ×, when the zone
  /// was first shown, when it completed.
  package struct GettingReadyMemory: Equatable, Sendable {
      package var hiddenByOwner: Bool
      package var firstShownAt: Date?
      package var completedAt: Date?
  }
  package struct GettingReadyStep: Equatable, Sendable {
      package let zone: GettingReadyZone
      package let memory: GettingReadyMemory   // what to persist
      package let sawUnready: Bool             // launch-scoped; fed back next step
  }
  package enum GettingReadyPolicy {
      package static let foldAfter: TimeInterval = 3 * 24 * 60 * 60
      package static func step(
          readiness: [ReadinessFeature: Readiness],  // P1 map; empty = not evaluated yet
          ownerKnown: Bool,
          memory: GettingReadyMemory,
          sawUnready: Bool,
          now: Date,
          briefingHour: Int,
          dayPlanHour: Int
      ) -> GettingReadyStep
  }
  ```
  Rules, in order (first match wins):
  1. `readiness` empty → `.hidden`, memory unchanged (no flicker before P1's first evaluation).
  2. `memory.hiddenByOwner` → `.hidden`.
  3. `memory.completedAt != nil` → `.allReady` if `sawUnready` (it completed during this launch), else `.hidden` ("gone on the next launch").
  4. `memory.firstShownAt` older than `foldAfter` → `.hidden` (decision 5).
  5. Cards = features whose readiness (after `honoringOwner`) is not `.off` and not `.needsSource`, in `allCases` order. Source rows = the `.needsSource` features grouped by source, sources in first-feature order. If no card's feature has a source (`source != .none`) → `.hidden` — a Development-only install's lone knowledge-index card does not open the zone.
  6. Every card terminal → set `completedAt = now`; `.allReady` if `sawUnready`, else `.hidden` (an install that was already ready, Review Focus 1).
  7. Otherwise → `.shown`, `sawUnready = true`, `firstShownAt = firstShownAt ?? now`.

  A `ready` card stays in the zone until every card is terminal (owner, ask #304). `off` features are not cards (they belong to Try this, P3).

- [ ] **Step 1: Write the failing tests.**
  - `Tests/Core/FeatureCardCopyTests.swift`:
    - `testEveryFeatureHasCardCopy`: `ReadinessFeature.allCases`. Asserts non-empty title and a `whatItIs` ending with ".".
    - `testCardCopyReusesTheTabSentence`: for `.digests`, `.briefing`, `.peopleCards`, `.memory`. Asserts `whatItIs` equals the matching tab row's `landsHere` from `copy(for:)` (Digests tab for `.digests`).
    - `testBriefingCardNamesTheHour`: hour 7. Asserts "07:00" is present.
  - `Tests/Core/GettingReadyTests.swift` (a `now` from `Date()`; readiness maps built inline):
    - `testCardsOnlyForEnabledAndSourcedFeatures`: digests ready, memory `.off`, jira `.needsSource(.jira)`, tracks preparing. Asserts cards = digests, tracks; one source row (jira, [.jira]).
    - `testCardsFollowPipelineOrder`: asserts card order equals `allCases` order filtered.
    - `testSourceRowsGroupBySource`: slack missing for digests, tracks, peopleCards, ideas. Asserts one `.slack` row listing all four in order.
    - `testCollapsesToAllReadyWhenEveryCardReadyOrError`: first step with one card preparing (`.shown`, `sawUnready`), second step all ready/error. Asserts `.allReady` and `completedAt == now`.
    - `testErrorCountsAsTerminal`: cards ready + error only, after a shown step. Asserts `.allReady`.
    - `testAllReadyAtFirstLookIsHiddenNotAllReady`: first step all ready, `sawUnready = false`. Asserts `.hidden` and `completedAt` set (Review Focus 1).
    - `testCompletedIsGoneOnNextLaunch`: `completedAt` set, `sawUnready = false`. Asserts `.hidden`.
    - `testOwnerHideWins`: `hiddenByOwner = true` with preparing cards. Asserts `.hidden`.
    - `testFoldsThreeDaysAfterFirstShown`: `firstShownAt = now − 3 d − 1 s`, a card scheduled. Asserts `.hidden`; at `now − 3 d + 60 s` asserts `.shown`.
    - `testFirstShownIsSetOnce`: two shown steps. Asserts `firstShownAt` equals the first step's `now`.
    - `testDevelopmentOnlyShowsNothing`: every switchable feature `.off`, slack/calendar/jira `.needsSource`, knowledgeIndex scheduled. Asserts `.hidden`.
    - `testNotEvaluatedYetIsHidden`: empty map. Asserts `.hidden` and memory unchanged.
    - `testOwnerUnknownCardHasNoLine`: `ownerKnown = false`, briefing `.scheduled`. Asserts the briefing card's `readiness == nil`, tone `.waiting`, not terminal.
    - `testToneMapping`: ready → `.ready`, preparing → `.preparing`, error → `.error`, waitingForSync/scheduled/nil → `.waiting`.
- [ ] **Step 2: Run, expect FAIL.** `make test-swift FILTER='FeatureCardCopyTests|GettingReadyTests' > /tmp/p2t4.log 2>&1; echo "exit=$?"`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.** Same, plus `EmptyStateCopyTests`.
- [ ] **Step 5: Lint.** `make lint-swift`
- [ ] **Step 6: Commit.** `feat(core): Getting ready — feature cards, source rows and the fold rule`

**Depends on:** none.

---

## Task 5: Today — `HomeQueries.today` + `HomeTodayBuilder`

**Goal:** One read for all six Today sources and the pure builder that turns it into the ordered cards and their wording.

**Files:**
- Modify: `Sources/WatchtowerCore/Models/Home.swift` (Today types, `HomeLink`, `HomeSnapshot`)
- Create: `Sources/WatchtowerCore/Database/Queries/HomeQueries.swift`
- Create: `Sources/WatchtowerCore/Services/HomeTodayBuilder.swift`
- Test: `Tests/Core/HomeQueriesTests.swift` (extend), `Tests/Core/HomeTodayTests.swift` (new)

**Interfaces:**
- Consumes: Task 2 and 3 queries; `ReminderQueries.fetchDue/dueCount`; `AgentActionQueries.awaitingOwnerCount`; `CalendarQueries.fetchNextEvent`; `BriefingQueries.fetchByDate`; `CatchUpQueries.fetchRecaps(limit: 1)`; `ReactionToolCatalog.title(for:)`; `CalendarEvent.parsedAttendees`; `Briefing.parsed*`.
- Produces:
  ```swift
  package enum TodayCardKind: CaseIterable, Sendable {
      case waitingOnYou, nextMeeting, briefing, myTargets, agentsWaiting, sinceYouWereAway // the fixed order
  }
  /// Where a click goes. Core has no SidebarDestination; AppState.openHomeLink maps these.
  package enum HomeLink: Equatable, Sendable {
      case inbox
      case calendarEvent(id: String)
      case briefing(id: Int)
      case targets
      case target(id: Int)
      case workbench(WorkbenchRoute)
      case workbenches
      case catchUp
      case feature(ReadinessFeature)      // Getting ready's Open
      case connect(ReadinessSource)       // Getting ready's Connect row
  }
  package struct TodayItem: Equatable, Sendable {
      package let chip: String?           // "Proposal", "Failed", "Reminder", "Review", "Check", "Question"
      package let title: String
      package let detail: String?         // workbench name, "Due today", "Overdue · Oct 12", "In progress"
      package let tone: TodayItemTone?    // targets' status dot
      package let link: HomeLink
  }
  package enum TodayItemTone: Equatable, Sendable { case overdue, dueToday, inProgress }
  package struct TodayCard: Equatable, Sendable {
      package let kind: TodayCardKind
      package let eyebrow: String         // "WAITING ON YOU · 4", "NEXT MEETING · IN 25 MIN"
      package let title: String?          // meeting title
      package let body: String?           // meeting line, briefing summary, recap line
      package let items: [TodayItem]
      package let link: HomeLink          // the card's own target (header click)
  }
  package struct HomeTodayData: Equatable, Sendable {
      package var awaitingCount: Int
      package var actions: [AgentAction]          // awaitingOwner(limit: 3)
      package var reminders: [Reminder]           // fetchDue
      package var nextEvent: CalendarEvent?
      package var nextEventHasPrep: Bool
      package var briefing: Briefing?             // today's
      package var targets: [Target]               // homeSummary
      package var asks: WorkbenchAskRows
      package var latestRecap: CatchUpRecap?
      package var failed: Set<TodayCardKind>      // a card whose read threw (logged)
  }
  package enum HomeQueries {
      /// Tables the Today read uses, for HomeCenter's ValueObservation region.
      package static let observedTables: [String]
      /// Every Today source in one read. Each card's read is caught separately:
      /// its error is logged (NSLog, card kind + message) and its kind added to
      /// `failed`; the others still read. A table missing mid-migration reads as
      /// that card having no content, not as a failure.
      package static func today(_ db: Database, now: Date, calendar: Calendar) -> HomeTodayData
  }
  package struct FirstSyncLine: Equatable, Sendable {      // OnboardingFinishPlan.firstSyncText's pair, named
      package let title: String
      package let detail: String
  }
  package struct HomeSnapshot: Equatable, Sendable {
      package let gettingReady: GettingReadyZone
      package let firstSync: FirstSyncLine?                    // shown on top of a .shown zone
      package let today: [TodayCard]
      package let todayReadFailed: Bool                        // every allowed card's read failed
      package var nothingNeedsYou: Bool  // today.isEmpty && !todayReadFailed && zone is .hidden or .allReady
  }
  package enum HomeTodayBuilder {
      package static let nextMeetingHorizon: TimeInterval = 24 * 60 * 60
      package static func cards(_ data: HomeTodayData, allowed: Set<TodayCardKind>, now: Date, calendar: Calendar) -> [TodayCard]
      package static func briefingSummary(_ briefing: Briefing) -> String?   // first item of the first non-empty section
      package static func meetingEyebrow(start: Date, now: Date, calendar: Calendar) -> String
      package static func targetDetail(_ target: Target, today: String) -> (String, TodayItemTone)
  }
  ```
  Card rules (each card appears only when `kind ∈ allowed` and it has content):
  - **Waiting on you** — content: `awaitingCount + reminders.count > 0` (the Inbox badge's sum). Eyebrow "WAITING ON YOU · N". Items: up to 3 of actions and due reminders merged newest first; chip "Proposal" (pending) / "Failed" (failed) / "Reminder"; title `reason` when set else `ReactionToolCatalog.title(for: tool)`, a reminder's `note` else "Reminder". Every link `.inbox`.
  - **Next meeting** — content: `nextEvent` starting within `nextMeetingHorizon`. Eyebrow "NEXT MEETING · IN N MIN" under 60 min, "NEXT MEETING · HH:MM" later today, "NEXT MEETING · TOMORROW HH:MM" otherwise. Title = event title. Body = "HH:MM–HH:MM · <people> · Prep ready" — people = up to 2 attendee display names (email local part when blank) and "+N"; "Prep ready" only when `nextEventHasPrep`. Link `.calendarEvent(id)`.
  - **Briefing** — content: today's row with a non-nil `briefingSummary`. Eyebrow "BRIEFING". Body = the summary (the view clamps it to 2 lines, decision 3). Link `.briefing(id)`.
  - **My targets** — content: `targets` non-empty. Eyebrow "MY TARGETS". Items: title = target text, detail/tone from `targetDetail`: "Overdue · <MMM d>" / "Due today" (or "Due HH:MM" when the due has a time) / "In progress". Item link `.target(id)`; card link `.targets`.
  - **Agents waiting** — content: `asks.rows` non-empty. Eyebrow "AGENTS WAITING · N". Items: up to 3, oldest first; chip = kind ("Review"/"Check"/"Question"); detail = workbench name; link `.workbench(.forAsk(...))`. Card link `.workbenches`. Unreadable rows are not counted.
  - **Since you were away** — content: `latestRecap` is `ready` and unacknowledged (the Catch-Up badge condition). Eyebrow "SINCE YOU WERE AWAY · SINCE <EEE HH:mm>" from the recap's `periodFrom`. Body = `tldr`. Link `.catchUp`.

- [ ] **Step 1: Write the failing tests.**
  - `HomeQueriesTests` (extend):
    - `testTodayEmptyDatabaseReadsNoContent`: asserts every field empty/nil/0 and `failed.isEmpty`.
    - `testTodayReadsEverySource`: one row per source. Asserts each field is filled.
    - `testOneFailingCardKeepsTheOthers`: drop `owner_asks` *and* make `briefings` unreadable (rename a column via the table-recreate dance in the fixture). Asserts `failed == [.briefing]`, asks read as empty (missing table ≠ failure), and the targets are still read (Review Focus 3).
  - `Tests/Core/HomeTodayTests.swift`:
    - `testCardShowsOnlyWithContent`: data with targets only. Asserts exactly one card, `.myTargets`.
    - `testFixedOrder`: every source filled. Asserts kinds equal `TodayCardKind.allCases`.
    - `testAllowedFiltersCards`: all filled, `allowed` without `.sinceYouWereAway`. Asserts it is absent.
    - `testWaitingOnYouCountsLikeTheBadge`: 2 pending + 1 failed + 2 due reminders. Asserts eyebrow "WAITING ON YOU · 5" and 3 items, newest first.
    - `testAsksAcrossAllWorkbenches`: asks in two workbenches. Asserts both rows, each detail is its workbench name, link is the `forAsk` route.
    - `testNextMeetingEyebrow`: start in 25 min → "NEXT MEETING · IN 25 MIN"; in 3 h today → "NEXT MEETING · HH:MM"; tomorrow 09:00 → "NEXT MEETING · TOMORROW 09:00".
    - `testNextMeetingBeyondHorizonHidden`: start in 30 h. Asserts no card.
    - `testNextMeetingLine`: 3 attendees, prep present. Asserts body "HH:MM–HH:MM · Colleague A, Colleague B +1 · Prep ready".
    - `testBriefingSummaryIsFirstItemOfFirstNonEmptySection`: attention empty, yourDay `["Standup at 10"]`. Asserts "Standup at 10"; all sections empty → no card.
    - `testTargetDetail`: overdue → "Overdue · <MMM d>", `.overdue`; due today → "Due today", `.dueToday`; in progress without due → "In progress", `.inProgress`.
    - `testRecapCardNeedsReadyUnacknowledged`: building → none; ready+acknowledged → none; ready+unacknowledged → card with `tldr`.
    - `testEmptyDataIsNothingNeedsYou` (degenerate): empty data, zone `.hidden`. Asserts `today.isEmpty` and `nothingNeedsYou`.
    - `testAllReadyZoneStillNothingNeedsYou`: zone `.allReady`, no cards. Asserts `nothingNeedsYou`.
    - `testShownZoneIsNotNothingNeedsYou`: zone `.shown`, no cards. Asserts `!nothingNeedsYou`.
- [ ] **Step 2: Run, expect FAIL.** `make test-swift FILTER='HomeQueriesTests|HomeTodayTests' > /tmp/p2t5.log 2>&1; echo "exit=$?"`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Lint.** `make lint-swift`
- [ ] **Step 6: Commit.** `feat(core): Today — one read and a pure card builder for Home`

**Depends on:** Tasks 2, 3, 4 (`Home.swift` is created in Task 4).

---

## Task 6: `HomeCenter` on `AppState`

**Goal:** The app-wide owner of the Home snapshot: live, cheap, surviving navigation, and the only place the Getting ready memory is persisted.

**Files:**
- Create: `Sources/Services/HomeCenter.swift`
- Create: `Sources/App/AppState+Home.swift` (environment pieces only in this task: `firstSyncLine`, `homeTodayCardsAllowed`)
- Modify: `Sources/App/AppState.swift` — `homeCenter` (lazy, like `readinessCenter`, line 53); `homeCenter.start(pool:)` right after `readinessCenter.start` in `wireAppDatabase` (line 1449); `homeCenter.stop()` beside `readinessCenter.stop()` on quit (line 631)
- Modify: `Sources/App/Navigation.swift` — `catchUpFirstSync` (line 222) reads `appState.firstSyncLine` (moved, not copied)
- Test: `Tests/HomeCenterTests.swift`, `Tests/HomeCenterSurvivesNavigationTests.swift` (new)

**Interfaces:**
- Consumes: `ReadinessCenter.readiness/briefingHour/dayPlanHour`; `HomeQueries`; `HomeTodayBuilder`; `GettingReadyPolicy`; `OnboardingFinishPlan.firstSyncText`; `SidebarDestination.isVisible`.
- Produces:
  ```swift
  @MainActor
  protocol HomeEnvironment: AnyObject {
      var now: Date { get }
      var calendar: Calendar { get }
      var ownerKnown: Bool { get }
      var firstSync: FirstSyncLine? { get }                        // AppState.firstSyncLine
      var allowedTodayCards: Set<TodayCardKind> { get }           // AppState.homeTodayCardsAllowed
  }
  @MainActor final class LiveHomeEnvironment: HomeEnvironment { init(appState: AppState) } // unowned/weak reads only
  /// The three per-install keys: home.gettingReady.hidden (Bool),
  /// home.gettingReady.firstShownAt, home.gettingReady.completedAt (Double, unix seconds).
  @MainActor final class GettingReadyStore {
      init(defaults: UserDefaults = .standard)
      var memory: GettingReadyMemory { get set }   // a missing key reads as false/nil
  }
  @MainActor @Observable
  final class HomeCenter {
      private(set) var snapshot: HomeSnapshot?     // nil until the first read
      init(readiness: ReadinessCenter, environment: any HomeEnvironment,
           store: GettingReadyStore, tickInterval: Duration = .seconds(30))
      func start(pool: DatabasePool)   // ValueObservation over HomeQueries.observedTables that exist + the tick
      func stop()
      func refresh()                   // rebuilds from the last Today read + current readiness; tracks its observable inputs
      func hideGettingReady()          // × → memory.hiddenByOwner = true, then refresh
  }
  // AppState+Home
  var firstSyncLine: FirstSyncLine? { get }  // was Navigation.catchUpFirstSync (CatchUpView adapts)
  var homeTodayCardsAllowed: Set<TodayCardKind> { get }       // waitingOnYou ⇔ .inbox visible; nextMeeting ⇔ .calendar; briefing ⇔ .briefings; sinceYouWereAway ⇔ .catchUp; myTargets and agentsWaiting always
  ```
  Behaviour: the same shape as `ReadinessCenter` — `start` replaces a previous run (generation counter), the observation region leaves out tables missing mid-migration, the tick re-reads the DB (the daemon's writes and the meeting eyebrow's minutes), `refresh` uses `withObservationTracking` over the readiness map, `ownerKnown`, `allowedTodayCards` and `firstSync`, so a readiness change rebuilds without a DB read. `sawUnready` is a launch-scoped `private var`; memory changes from `GettingReadyPolicy.step` are written back to the store only when they differ. `todayReadFailed` = every allowed kind is in `failed`.

- [ ] **Step 1: Write the failing tests** (`TestDatabase.createPool()`, a fake `HomeEnvironment`, a `ReadinessCenter` with the fake readiness environment from `ReadinessCenterTests`, `UserDefaults(suiteName: UUID().uuidString)`; awaits are bounded expectations, never `sleep`):
  - `HomeCenterTests`:
    - `testFirstReadPublishesSnapshot`: start on an empty pool. Asserts a non-nil snapshot with `nothingNeedsYou`.
    - `testInsertingATargetAddsMyTargets`: insert a mine/due-today target after start. Asserts the `.myTargets` card appears once the observation fires.
    - `testTickPicksUpWritesTheObservationMisses`: a second `DatabasePool` on the same file writes an ask (stands in for the daemon). Asserts `.agentsWaiting` appears after the tick (tick interval 50 ms in the test).
    - `testReadinessChangeRebuildsWithoutDBRead`: readiness flips digests preparing → ready. Asserts the card's tone changes.
    - `testHideGettingReadyPersists`: `hideGettingReady()`. Asserts `.hidden` now and `store.memory.hiddenByOwner` in the defaults suite.
    - `testCompletedThisLaunchShowsAllReadyThenGoneOnRelaunch`: preparing → ready gives `.allReady`; a new `HomeCenter` on the same defaults gives `.hidden`.
    - `testAllReadsFailedIsNotAllClear`: an environment allowing only `.myTargets`, `targets` table made unreadable. Asserts `todayReadFailed` and `!nothingNeedsYou` (Review Focus 3).
    - `testStopCancelsObservationAndTick`: after `stop()`, inserts change nothing.
    - `testStartTwiceKeepsOneObservation`: start, start again, insert. Asserts the snapshot updates once per write (no duplicate loops).
    - `testGarbageDefaultsReadAsEmpty`: a string under `home.gettingReady.firstShownAt`. Asserts `firstShownAt == nil`, no crash.
  - `HomeCenterSurvivesNavigationTests`:
    - `testSnapshotLandsAfterNavigatingAway`: `AppState` with the test DB; `selectedDestination = .home`, start, switch to `.targets` before the first read lands. Asserts `appState.homeCenter.snapshot` is filled and switching back shows it without a new read.
- [ ] **Step 2: Run, expect FAIL.** `make test-swift FILTER='HomeCenterTests|HomeCenterSurvivesNavigationTests' > /tmp/p2t6.log 2>&1; echo "exit=$?"`
- [ ] **Step 3: Implement and wire into `AppState`.**
- [ ] **Step 4: Run, expect PASS.** Also `FILTER='AppStateTests|ReadinessCenterTests|EmptyStateTabWiringTests'` (wiring; Catch-Up's first-sync line moved).
- [ ] **Step 5: Lint.** `make lint-swift`
- [ ] **Step 6: Commit.** `feat(desktop): HomeCenter — live Home snapshot on AppState`

**Depends on:** Tasks 1, 5.

---

## Task 7: Home links — `openHomeLink` and the calendar event deep link

**Goal:** Every Home click lands on its tab or item through the existing navigation helpers; the one missing helper (a calendar event) is added.

**Files:**
- Modify: `Sources/App/AppState+Home.swift` — `openHomeLink`, `homeDestination(for:)`
- Modify: `Sources/App/AppState.swift` — `pendingCalendarEventID`, `navigateToCalendarEvent(_:)` beside `navigateToTarget` (line 483)
- Modify: `Sources/Views/Calendar/CalendarEventsView.swift` — on appear and on change of `pendingCalendarEventID`, resolve it with `CalendarQueries.fetchEventLink` and run the existing `openLinkedEvent` (line 184), then clear it
- Test: `Tests/HomeLinkTests.swift` (new)

**Interfaces:**
- Consumes: `navigateToTarget`, `navigateToBriefing`, `navigateToWorkbench`, `performEmptyStateAction(.connect)`, `HomeLink`.
- Produces:
  ```swift
  // AppState
  var pendingCalendarEventID: String?
  func navigateToCalendarEvent(_ eventID: String)        // sets pending + selectedDestination = .calendar
  func openHomeLink(_ link: HomeLink)
  static func homeDestination(for feature: ReadinessFeature) -> SidebarDestination
  // slackSync → .statistics, digests/streamDigests → .digests, tracks → .tracks, peopleCards → .people,
  // briefing → .briefings, dayPlan → .dayPlan, ideas → .ideas, memory → .memory, inbox → .inbox,
  // knowledgeIndex → .search, calendar → .calendar, jira → .boards
  ```
  `.feature(f)` opens `homeDestination(for: f)`; `.connect` goes through `performEmptyStateAction(.connect(source))` (Settings → Connections, as the empty states do); `.workbenches` selects `.workbench` with no route; `.catchUp`/`.inbox`/`.targets` select the tab. A destination that is hidden right now still goes through `applyFeatureFallback` (Navigation), so a stale link lands on Home, not on a hidden tab.

- [ ] **Step 1: Write the failing tests.**
  - `testEveryLinkLandsOnItsTab`: each `HomeLink` case. Asserts `selectedDestination` and the matching pending field (`pendingTargetID`, `pendingBriefingID`, `pendingWorkbenchRoute`, `pendingCalendarEventID`).
  - `testAskLinkCarriesTheRoute`: `.workbench(.forAsk(projectID: 2, sessionID: nil, askID: 9))`. Asserts `pendingWorkbenchRoute` equals it.
  - `testConnectOpensConnections`: asserts `settingsTab == .connections` and `openSettingsWindow` called once.
  - `testEveryFeatureHasADestination`: `ReadinessFeature.allCases` map without a crash, and each destination's `EmptyStateCopy.feature` (when it has one) is that feature or the Jira/digest sibling.
  - `testCalendarPendingEventIsConsumedOnce`: render `CalendarEventsView` via `ViewRenderProbe` with a pending id. Asserts the meeting is selected and `pendingCalendarEventID == nil` afterwards.
- [ ] **Step 2: Run, expect FAIL.** `make test-swift FILTER='HomeLinkTests' > /tmp/p2t7.log 2>&1; echo "exit=$?"`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.** Also `FILTER='CalendarEventsViewTests|NotificationRouteTests'`.
- [ ] **Step 5: Lint.** `make lint-swift`
- [ ] **Step 6: Commit.** `feat(desktop): Home links — open the tab or item, calendar event deep link`

**Depends on:** Tasks 1, 5.

---

## Task 8: `HomeView` — header, Getting ready, Today, all-clear line

**Goal:** The approved mockup (ask #304) in SwiftUI, values and closures only so ViewInspector can drive it.

**Files:**
- Replace: `Sources/Views/Home/HomeView.swift` (reads `appState.homeCenter.snapshot`, `appState.daemonManager.syncProgress` via the snapshot, and calls `openHomeLink`/`hideGettingReady`)
- Create: `Sources/Views/Home/GettingReadyZoneView.swift`, `TodayZoneView.swift`, `TodayCardView.swift`
- Test: `Tests/HomeViewTests.swift` (new)

**Interfaces:**
- Consumes: `HomeSnapshot`, `GettingReadyZone`, `TodayCard`, `FeatureReadiness.line`, `ReadinessSource.displayName`, `AppState.homeDestination(for:)` (for the source rows' tab titles).
- Produces:
  ```swift
  struct HomeView: View                                  // binds AppState → HomeContent
  struct HomeContent: View {                             // no @Environment(AppState.self)
      init(snapshot: HomeSnapshot?, today: Date, onLink: @escaping (HomeLink) -> Void, onHideGettingReady: @escaping () -> Void)
  }
  struct GettingReadyZoneView: View { init(zone: GettingReadyZone, firstSync: FirstSyncLine?, onLink: ..., onHide: ...) }
  struct TodayZoneView: View { init(cards: [TodayCard], nothingNeedsYou: Bool, readFailed: Bool, onLink: ...) }
  struct TodayCardView: View { init(card: TodayCard, onLink: ...) }
  ```
  Layout (mockup):
  - **Header:** large title "Home" and the date line (`today` formatted "EEEE, MMMM d"). `navigationTitle("Home")` on the content, not inside a branch.
  - **Getting ready (`.shown`):** header "Getting ready", subtitle "Watchtower is preparing these from your sources", an × button (help "Hide") calling `onHide`. On top, while `firstSync` is non-nil, a highlighted line: its title plus the heartbeat detail line. Then a `LazyVGrid` (`.adaptive(minimum: 250)`): per card — title, `whatItIs`, a status dot (tone colours: ready green, preparing blue, waiting grey, error orange) and `FeatureReadiness.line`, except a ready card, which shows "Ready" and an **Open** link (`.feature`). A nil readiness shows no line. Then one dashed row per source row: "Connect <Source> to get <tab titles joined with commas and 'and'>" + a "Connect <Source>" button (`.connect`). For Jira it reads "Connect Jira to get Boards, Workload, Blockers, Project Map and Releases" — the Jira feature expands to the five Jira tabs, every other feature to `homeDestination(for:)`'s title.
  - **Getting ready (`.allReady`):** one line "Everything's ready" with a check. `.hidden`: nothing.
  - **Today:** a `LazyVGrid` (`.adaptive(minimum: 320)`) of `TodayCardView`s in snapshot order. Each card: the eyebrow (small caps style), optional title, optional body (`lineLimit(2)` for the briefing), item rows (chip, status dot for targets, title, trailing detail), each row a button to its link; the card header is a button to `card.link`.
  - **All clear:** when `snapshot.nothingNeedsYou`, one line "Nothing needs you right now." with `checkmark.circle`. When `readFailed`, "Couldn't read today's items — see the log." instead. Before the first snapshot: a `ProgressView`, no all-clear line.
  - No counters, no badges, nothing for Try this (P3 adds its zone below Today).

- [ ] **Step 1: Write the failing tests** (`ViewRenderProbe` + ViewInspector, like `FeatureEmptyStateViewTests`):
  - `testHeaderShowsHomeAndDate`
  - `testGettingReadyShownRendersCardsInOrder`: three cards. Asserts their titles in order and the subtitle text.
  - `testReadyCardShowsOpenAndCallsLink`: tap Open. Asserts `onLink(.feature(.digests))`.
  - `testPreparingCardShowsReadinessLine`: asserts the `FeatureReadiness.line` text.
  - `testFirstSyncLineOnTop`: asserts the "Syncing Slack for the last 30 days — usually 3–5 min" title and its detail.
  - `testJiraSourceRowText`: asserts "Connect Jira to get Boards, Workload, Blockers, Project Map and Releases" and the Connect button calls `.connect(.jira)`.
  - `testHideButtonCallsHide`
  - `testAllReadyLine`: `.allReady`. Asserts "Everything's ready".
  - `testTodayCardsInSnapshotOrder`: asserts eyebrows in order.
  - `testItemRowCallsItsLink`: tap a target row. Asserts `.target(id)`.
  - `testNothingNeedsYouLine`: empty today, `.hidden`. Asserts "Nothing needs you right now.".
  - `testReadFailedIsNotAllClear`: asserts the read-failure line and no all-clear line.
  - `testNoCounterText`: a shown zone with 5 cards. Asserts no text matches `\d+ of \d+`.
- [ ] **Step 2: Run, expect FAIL.** `make test-swift FILTER='HomeViewTests' > /tmp/p2t8.log 2>&1; echo "exit=$?"`
- [ ] **Step 3: Implement.** Check the layout against the mockup in light and dark mode with `make app-dev` (screenshot for the PR body).
- [ ] **Step 4: Run, expect PASS.** Also `FILTER='HomeLandingTests|HomeCenterTests|HomeLinkTests'`.
- [ ] **Step 5: Lint.** `make lint-swift`
- [ ] **Step 6: Commit.** `feat(desktop): Home view — Getting ready and Today`

**Depends on:** Tasks 6, 7.

---

## Task 9: Owner pass — manual check on a fresh and an established install

**Goal:** What tests cannot show: the first minutes on a fresh workspace and the first launch of an existing one.

**Files:** none (findings become fixes in this lane or board items).

- [ ] **Step 1:** Fresh workspace (`make app-dev`, a throw-away workspace, Slack connected): onboarding lands on Home; the first-sync line and the cards tick from "Starts after the first sync" to ready; the zone turns into "Everything's ready" and is gone after relaunch; × hides it for good.
- [ ] **Step 2:** Established workspace: the app opens on Home; no Getting ready zone (or only for a feature not ready yet); Today cards match the Inbox badge, Calendar, Briefings, Targets, the workbench asks and Catch-Up; every click lands on the right item.
- [ ] **Step 3:** Record the result as an owner ask with a checklist (manual check, board #783) — the owner verifies on their install; nothing from a live install goes into the repo.

**Depends on:** Task 8.

---

## Task 10: Docs — feature note, app guide, onboarding notes, CLAUDE.md

**Files:**
- `docs/features/first-run.md`: a "Home (P2)" section — destination and landing rules; `HomeCenter` (inputs, observation + tick, survives navigation); `GettingReadyPolicy` rules 1–7 and the three `UserDefaults` keys; Today card table (source → content rule → link); the spec resolutions below; "Pending" now lists only P3 (#785).
- `docs/app-guide.md`: a new "### Home" section first under "Tabs & Features" (what each zone shows, when Getting ready folds, × hides it, each Today card and where it leads); "First launch: setup" says setup ends on Home; "Menu" lists Home first.
- `docs/features/onboarding-v2.md`: "Finish landing" → Home for every goal set (re-runs keep the tab; Catch-Up's first-sync line also shows in Getting ready); the "falls back to Inbox" sentence (line 83) → falls back to Home.
- `docs/onboarding-flow.md`: lines 57 and 122 (the landing tab) → Home.
- `CLAUDE.md`: the first-run index line — "(2026-10-14, P1 + P4; Home/Try this pending #784)" → "(2026-10-14 P1 + P4, 2026-10-15 P2 Home; Try this pending #785)", and append the P2 names (`SidebarDestination.home`, `HomeCenter`, `GettingReadyPolicy`, `HomeTodayBuilder`, `TargetQueries.homeSummary`, `OwnerAskQueries.openAsksAllWorkbenches`).
- No inventory file changes (see Contracts).

- [ ] **Step 1:** Write the docs; every file:line cited is re-checked against the merged code.
- [ ] **Step 2:** `bash scripts/leak-check.sh origin/main..HEAD > /tmp/p2leak.log 2>&1; echo "exit=$?"`
- [ ] **Step 3: Commit.** `docs: first run P2 — Home (Getting ready + Today)`

**Depends on:** Task 8 (may run beside Task 9).

---

## Task 11: Gate

- [ ] `bash scripts/dev-health.sh` — stop if `HEALTH: overloaded`.
- [ ] `make test > /tmp/p2gate-go.log 2>&1; echo "exit=$?"` (no Go change expected; the gate still runs once).
- [ ] `make test-swift > /tmp/p2gate-swift.log 2>&1; echo "exit=$?"` (includes the Kit).
- [ ] `make lint-all > /tmp/p2gate-lint.log 2>&1; echo "exit=$?"`
- [ ] `local-review` (round 1 panel), then `debate-review` on the final PR into `main`; the PR body lists the spec resolutions and says no inventory contract changed.

**Depends on:** Tasks 9, 10.

---

## Task summary

| # | Task | Depends on |
|---|---|---|
| 1 | `SidebarDestination.home` + landing on Home | none |
| 2 | `homeSummary`, `openAsksAllWorkbenches` | none |
| 3 | `awaitingOwner`, `hasPrep`, `WorkbenchRoute.forAsk` | none |
| 4 | Feature card copy + `GettingReadyPolicy` | none |
| 5 | `HomeQueries.today` + `HomeTodayBuilder` | 2, 3, 4 |
| 6 | `HomeCenter` on `AppState` | 1, 5 |
| 7 | `openHomeLink` + calendar event deep link | 1, 5 |
| 8 | `HomeView` | 6, 7 |
| 9 | Owner pass (manual check) | 8 |
| 10 | Docs | 8 |
| 11 | Gate | 9, 10 |

---

## Review checklist (implementers self-review before hand-back)

From `docs/review/review-rules.md`:
- **Swift / Desktop conventions → Lifecycle & state:** Home state lives on `AppState` (`HomeCenter`), tested start → navigate away → lands; `HomeCenter` is started in `wireAppDatabase`, which both launch and `completeOnboarding()` reach, so Home is live on every path that reveals it.
- **Swift / Desktop conventions → Error handling:** a failed card read is logged and named (`failed`), never folded into "no content"; a missing table is the only "absent" case (the third-state rule). `UserDefaults` garbage reads as absent.
- **Swift / Desktop conventions → Tests:** `HomeCenter` (a new `@Observable` center) ships with its own suite in the same change; Core logic is table-tested in `Tests/Core`.
- **§7 Test quality + race risk:** no `sleep`; bounded expectations; dates from `Date()`, never hard-coded; temp `UserDefaults` suites.
- **§8 Regression / blast radius:** landing, launch default and fallback changes are covered by the updated tests listed in Task 1; deep links from notifications and the mobile hub keep their destinations.
- **§9 DRY:** `WorkbenchRoute.forAsk` and `AppState.firstSyncLine` are moved, not copied; the Inbox count reuses `awaitingOwnerCount` + `dueCount`; card text reuses `EmptyStateCopy` sentences.
- `.claude/skills/add-desktop-feature/SKILL.md`: navigation wiring (4 spots), cross-process writes need the tick, VM/center `@MainActor`, reads off-main in `pool.read`.

## Contracts

- **No inventory contract is amended.** Home only reads:
  - PROJ-01 (`docs/inventory/workbench.md`): `homeSummary` filters `project_id IS NULL`; a new Desktop guard `testProj01_HomeSummaryNeverReturnsAProjectTarget` is added beside `testProj01_FetchAllNeverReturnsAProjectTarget` (a stronger guard, no assertion relaxed).
  - STRIP-01/02 (`docs/inventory/reaction-commands.md`): Waiting on you reads `agent_actions`/`reminders` only, through `notWorkbenchRow`; Home writes nothing.
  - PROJ-13: Home reads open asks; answering stays in the workbench.
  - CATCHUP-01: Home never acknowledges a recap; it links to Catch-Up.
  - OWNER-02: readiness passes through `FeatureReadiness.honoringOwner`.
- **Feature-note contracts changed (owner-approved in the spec, decisions 2 and 7):** `docs/features/onboarding-v2.md` "Finish landing" and the Inbox fallback; `OnboardingFinishPlan.landing` is deleted.

## Spec resolutions made while planning

1. **Feature card text.** `EmptyStateCopy` is keyed by tab, not by feature, and several tabs share a feature (five Jira tabs, Digests/Catch-Up). A feature-keyed `featureCard` reuses the tab sentence where one tab owns the feature and adds a sentence for the four features without one (Slack sync, stream digests, knowledge index, Jira).
2. **Development-only installs.** Knowledge search is on there and needs no source, so it would be a lone card. The zone shows only when at least one card reads a source (rule 5), which keeps spec §3.1's "Development only never shows it".
3. **Existing installs** (decision 2). An install whose cards are all ready at the first look never sees "Everything's ready"; that line shows only when the zone completed during this launch.
4. **3-day fold anchor.** "Folds after 3 days" counts from the first time the zone was shown (`home.gettingReady.firstShownAt`), since onboarding completion has no stored time.
5. **`needsSource` rows.** "One combined row" is read as one row per missing source, each listing the tabs it unlocks (the mockup's Jira row is one instance).
6. **Briefing "first paragraph"** (decision 3). A briefing row has no prose field, only item sections; the summary is the first item of the first non-empty section in the detail view's order (attention, your day, what happened, team pulse, coaching), clamped to two lines.
7. **Since you were away.** The card shows when the newest recap is ready and not acknowledged (the Catch-Up badge condition), with that recap's window start and `tldr`. `CatchUpQueries.autoWindowStart` is not needed: an unacknowledged recap already carries its window.
8. **Next meeting horizon.** Only an event starting within 24 h is shown, so "Today" never advertises next week's meeting. The prep line is "Prep ready" when `meeting_prep_cache` holds a non-empty prep (a new `CalendarQueries.hasPrep`); no prep text is decoded on Home.
9. **Waiting on you items.** The top 3 are pending/failed proposals and due reminders (what the badge counts), not the strip's 24 h tail of applied rows.
10. **Agents waiting.** Shows the count and the 3 oldest asks; a click opens the ask's session terminal, or the board for an ask filed outside the app (`WorkbenchRoute.forAsk`, the notification rule).
11. **Calendar deep link.** There was no "open this event" helper; `navigateToCalendarEvent` + `pendingCalendarEventID` reuse `CalendarEventsView.openLinkedEvent`.
12. **Today cards follow tab visibility.** A card whose tab is hidden (e.g. Catch-Up with its features off) is not shown, so no link leads to a hidden tab.
