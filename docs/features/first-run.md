# First run — feature readiness, honest empty states, fresh-install first cycle (2026-10-14)

Board #779. Spec `docs/superpowers/specs/2026-10-14-first-run-home-design.md`
(§1 readiness + empty states = P1, §2 first cycle = P4); plan
`docs/superpowers/plans/2026-10-14-first-run-p1-p4.md`, whose "Spec corrections
found while planning" are folded in below. **P2 (Home) and P3 (Try this) are not
built:** they wait for the Home mockup (#784).

The problem it closes: right after onboarding most tabs were a blank page or "No
data", with no word on whether anything would ever land there, and the daemon's
first cycles held people cards back for 24 h and the first briefing and day plan
until the next morning's hour.

## Readiness model (Desktop, P1)

- **Pure evaluator.** `FeatureReadiness.evaluate(_:)`
  (`WatchtowerDesktop/Sources/WatchtowerCore/Services/FeatureReadiness.swift:19`)
  maps `ReadinessInputs` (`WatchtowerDesktop/Sources/WatchtowerCore/Models/Readiness.swift:146`) to a `Readiness` per
  `ReadinessFeature`. No GRDB, no AppState, no clock read: `now` is an input, so
  every rule is a table test in `WatchtowerDesktop/Tests/Core/FeatureReadinessTests.swift`.
- **Precedence** (`FeatureReadiness.swift:23-41`), first match wins:
  1. `off` — the feature's registry id is in `disabledFeatureIDs` (features
     without a switch — Slack sync, calendar, Jira — are never off);
  2. `needsSource(source)` — `ReadinessFeature.source` is not connected
     (`ReadinessSource.isConnected`, `Readiness.swift:77`);
  3. `ready` — the feature's content table has any row; content wins even while
     a new run is going;
  4. `preparing(detail)` — the newest `pipeline_runs` row is `running`, the
     daemon is running and `started_at` is under `preparingMaxAge` (2 h,
     `FeatureReadiness.swift:9`). An older `running` row is a dead process's
     leftover (`reapStalePipelineRuns` only reaps after 24 h) and falls through;
  5. `error(message)` — the newest run is `error` and there is no content;
  6. `waitingForSync(detail)` — the feature reads synced data, **Slack is
     connected** and `lastSyncTime == nil` (R7);
  7. `scheduled(Eta)` — the next run time from the feature's gate.
- **`lastSyncTime` means "the first Slack sync finished".** It is the mtime of
  `last_sync.json` (`DaemonManager.readLastSyncTime`,
  `WatchtowerDesktop/Sources/WatchtowerCore/Services/DaemonManager.swift:95`), which only the Slack sync paths
  write: the daemon's Slack sync phase (`internal/daemon/daemon.go:631`) and
  a foreground `watchtower sync` (`cmd/sync.go:608`, `:628`). Without Slack it stays nil for ever,
  so rule 6 applies only while Slack is connected (`FeatureReadiness.swift:37`);
  a mail/Jira-only install goes straight to `scheduled`.
- **`Eta` is a vocabulary, not a duration** (`Readiness.swift:91`):
  `afterCurrentSync`, `nextCycle(minutes:)` from `sync.poll_interval`
  (`parsePollInterval`, garbage → 15), `at(hour:tomorrow:)`, `inAboutADay` (the
  people 24 h throttle from `last_people.txt`), `inHours(n)` (ideas/streams 6 h
  from `last_ideas.txt`/`last_streams.txt`, rounded up). No countdowns. Phrases
  and the one-line state wording live in `FeatureReadiness.phrase`/`line`
  (`FeatureReadiness.swift:94-115`): "Off — Turn on", "Connect Slack to get
  this", "Preparing now", "Didn't work yet — retries automatically · <first line
  of error_msg, ≤ 80 chars>", "Starts after the first sync", "Within ~15 min",
  "Today at 08:00", "In about a day". The spec's "link to Usage → Pipelines" on
  `error` is not built.
- **Pipeline names and content tables.** `ReadinessFeature.pipelineName`
  (`Readiness.swift:28`) and `ReadinessQueries.contentTable`
  (`WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ReadinessQueries.swift:11`). Calendar is the one untracked
  feature (no pipeline name, so never `preparing`/`error`). Day plan **is**
  tracked, as `day_plan` (plan correction 1; the spec said it was not). Content
  is whole-table `EXISTS` (one owner per workspace); briefing and day plan count
  **any** row, not today's (plan correction 4 — "today's" is a Home concern). A
  table missing mid-migration reads as no content.
- **`ReadinessCenter`** (`WatchtowerDesktop/Sources/Services/ReadinessCenter.swift`)
  is app-wide on `AppState` (`WatchtowerDesktop/Sources/App/AppState.swift:53`), so a reading survives tab
  switches. It re-evaluates on a GRDB `ValueObservation` of the content tables
  and `pipeline_runs`, on any change of the observable inputs it reads
  (`DaemonManager` status poll, `FeatureVisibilityStore`) and on a 30 s tick
  that re-reads the DB. The observation sees only this process' writes; the
  daemon's (another process) reach readiness through the tick's re-read, so a
  daemon write shows within ~30 s. A failed observation or re-read keeps the
  last reading, and the next tick tries again; before the first DB read the map
  is empty and the empty states show no readiness line and no state-gated
  button (`FeatureEmptyState.swift:106`).

- **Owner gate (OWNER-02).** The daemon skips briefing, day plan and inbox
  while the owner is unknown, so `AppState.emptyStateContext` passes their
  readiness through `FeatureReadiness.honoringOwner`: a `scheduled` or
  `waitingForSync` state reads nil then (no line); off, needs-source, error,
  preparing and ready stay.

### Fresh-install rule — Go ↔ Swift dual path

The daemon skips the hour gate for the first briefing and the first day plan;
the Desktop must say "within ~15 min", not "today at 08:00", for the same state.
Change both sides together.

| | Go (decides the run) | Swift (says when) |
|---|---|---|
| Briefing | `briefingFresh` `internal/daemon/daemon.go:1781`, used at `:1767` | `FeatureReadiness.swift:47-52` |
| Day plan | `dayPlanFresh` `internal/daemon/daemon.go:2078`, used at `:2050` | `FeatureReadiness.swift:53-59` |

- **Briefing fresh** = no `last_briefing.txt` stamp **and** no `briefings` row
  at all, for any user (`db.HasAnyBriefing`, `internal/db/briefings.go:43`;
  Swift: `contentPresent` lacks `.briefing` and `stamps.lastBriefing == nil`).
  Owner-agnostic (plan correction 3): `shouldRunBriefing` has no owner in scope.
  The row check is what keeps a wiped stamp (Reset LLM data,
  `DaemonStampFiles.clear`) from re-triggering an early briefing on an old
  install (`TestShouldRunBriefingAt_StampWipedRowsExistKeepsHourGate`).
- **Day plan fresh** = no `day_plans` row at all (`db.HasAnyDayPlan`,
  `internal/db/dayplans.go:207`). DB-only: `lastDayPlanDate` is in memory and
  lost on restart (plan correction 2), so Swift reads no stamp for it.
- **A DB error, or no DB, reads as not fresh** in Go: the hour gate keeps
  applying and the error is logged. The freshness query runs only when the hour
  gate refuses. Everything else is unchanged: same-day check, attempt budget
  (`maxDailyAIAttempts`), owner check, the pipelines' own "no data → (0, nil)"
  skip. A no-data first briefing spends no budget and the next cycle tries
  again (`TestDaemon_FirstBriefingNoDataKeepsBudget`).
- `shouldRunBriefing` is split into `shouldRunBriefingAt(now)`
  (`daemon.go:1757`) so the gate tests don't depend on the hour they run at
  (plan correction 7).
- After the first one exists Swift's `daily` (`FeatureReadiness.swift:75`)
  mirrors `shouldRunBriefing`: ran today → "tomorrow at HH:00"; before the hour
  → "today at HH:00"; otherwise the next cycle.

### Stamp-file parsing contract

`LiveReadinessEnvironment.stamp` (`WatchtowerDesktop/Sources/Services/ReadinessCenter.swift:200`) reads
`last_people.txt`, `last_briefing.txt`, `last_ideas.txt`, `last_streams.txt`
from the active workspace directory. Format = what Go's `saveLast*` writes
(`internal/daemon/daemon.go:1692`, `:1716`, `:1740`, `:1816`): decimal unix
seconds, whitespace trimmed. Missing, unreadable or not an integer → nil ("no
stamp"), the same as Go's `loadLast*` (`daemon.go:1679`, `:1803`) and pinned by
`ReadinessCenterTests.testGarbageStampReadsNil`.

## Honest empty states (Desktop, P1)

- **Copy table.** `EmptyStateCopyTable`
  (`WatchtowerDesktop/Sources/WatchtowerCore/Services/EmptyStateCopy.swift:39`)
  is the one owner of each tab's empty-state text: icon (the tab's sidebar
  symbol), title, "what lands here", whose readiness shows and the primary
  action. Keyed by `SidebarDestination.rawValue` because `SidebarDestination`
  lives in the Desktop target (plan correction 5); Workbench's key is
  `"projects"`, its persisted raw value (R1). `{hour}` is filled from
  `briefing.hour`/`day_plan.hour`. Exempt tabs, which keep their own states:
  `search`, `usage`, `mcpServer`, `chat` (`EmptyStateCopy.swift:61`).
  `EmptyStateCopyCoverageTests` sweeps `SidebarDestination.allCases`: every tab
  has copy XOR is exempt, and the icon matches the sidebar's.
- **Views.** `FeatureEmptyState` (`WatchtowerDesktop/Sources/Views/Components/FeatureEmptyState.swift`) is
  values and closures only (ViewInspector-driven, no `@Environment(AppState)`);
  `TabEmptyState` (`WatchtowerDesktop/Sources/Views/Components/TabEmptyState.swift`) binds it to one tab
  from an `EmptyStateContext` that `AppState.emptyStateContext`
  (`WatchtowerDesktop/Sources/App/AppState+EmptyState.swift:8`) builds. Tab-specific content stays inside
  as `extra`: Catch-Up's first-sync line, the Inbox reaction cheat sheet,
  `NoOwnerEmptyState` and Generate on Briefings/Day Plan, Ideas' Find
  Ideas/Create, Calendar's connect options, Targets' "React with an emoji in
  Slack" line (R11). `ContentAwareEmptyState` (`TabEmptyState.swift:86`) keeps a
  tab's own "nothing here" (no blockers, nothing upcoming) while its feature is
  `ready` — Blockers, Project Map, Releases, Calendar's empty list. Boards pins
  Jira to `needsSource(.jira)` while the view knows Jira is not connected, so
  Connect Jira shows even before the first evaluation. A tab's read error shows
  before its empty state. "No matches" filter states are untouched.
- **The one button** (`FeatureEmptyState.visibleAction`, `:103`): Turn on while
  `off` — for **any** off feature with a registry id, hiding the tab's own
  action while off (R13); Connect <source> while `needsSource`; otherwise the
  table's action (Open Settings → Features for the hours — R14 keeps the generic
  label —, "Build a recap", "New target", "Add a folder"). Turn on and Connect
  never show in a state that doesn't call for them.
- **Turn on** goes through `AppState.turnOnFeatureFromEmptyState`
  (`WatchtowerDesktop/Sources/App/AppState.swift:1215`, plan correction 6): `FeatureManagerService.enableNow`
  (the direct `features enable` path, FEAT-03 fast-forward included, never
  Settings → Features' staged changes) and one daemon restart, like
  `acceptFeatureSuggestion`. One at a time: a second click elsewhere says
  "Another feature is turning on — try again in a moment". Errors are keyed by
  feature id (R15, `AppState.swift:1193`), so one tab's error never shows under
  another's Turn on. A failed restart leaves the feature on; the button stays
  as **Try again** and only restarts. An error recorded while the feature was
  off goes stale once it is on another way (`emptyStateTurnOnError`, `:1201`).
- **Catch Up** reads the readiness of `.digests` only (R10; the spec said digests
  + inbox, the component takes one feature).
- **Spec §1.5 deviations as built:** Briefings/Day Plan offer "Open Settings →
  Features", not "Change the hour"; the Inbox row has no button — the reaction
  cheat sheet is inline (spec row updated).

## Fresh-install first cycle (Go daemon, P4)

- **People cards no longer lock out for 24 h after a no-data cycle.**
  `guide.Pipeline` reports why it returned zero: `RunOutcome`
  (`internal/guide/pipeline.go:83`) — `OutcomeGenerated`, `OutcomeCovered` (every
  active user already has a card for the window), `OutcomeNoData` (no active
  users with enough messages, or no situations yet; `:236`, `:268`).
- **A no-data cycle writes nothing.** `phasePeopleCards`
  (`internal/daemon/daemon.go:1213`) asks `Pipeline.HasData`
  (`internal/guide/pipeline.go:189`, the negation of `OutcomeNoData`) **before**
  `trackedPipelineRun` (`daemon.go:1235`), so a workspace without data writes no
  empty `people` row in `pipeline_runs` every cycle (the `phaseCustomTrackScan`
  precedent). A failed check logs and runs anyway, so the error lands in a
  tracked row. `LastOutcome() == OutcomeNoData` after the run (`daemon.go:1250`)
  is the backstop for a window that moved between the check and the run: no
  stamp. Either way a no-data cycle does not stamp `last_people.txt`, records no
  attempt and retries next cycle. Generated and covered runs stamp as before.
- **The first run's window ends now.** Run's window is the 7 days ending at
  the start of today, and a fresh install's first digests end now
  (`period_to` = the digest run), so they would only count after midnight.
  Until the first stamped run (`lastPeople` zero) the daemon sets
  `Pipeline.FirstRun` and the window ends now instead. Limit: a first run that
  fails part-way retries over a new window (it ends at the next cycle's now),
  so the users it already carded are carded again — bounded by the attempt
  budget, and only before the first stamp.
- **Briefing and day plan** — the fresh-install bypass above. One briefing and
  possibly one day plan move earlier on day one; people cards run in the first
  cycle that has situations. Runs per day do not grow.
- `docs/daemon-pipeline.md` (people first-cycle note, briefing throttling,
  cadence table) carries the same rules.

## Contracts and tests

- **No inventory file changes.** No guard test is touched:
  `TestShouldRunBriefing_*`, `*Backoff_*` and `TestOwner02_*` are as they were.
  `TestDaemon_RunSyncInvokesAllTrackedPhases` (`internal/daemon/daemon_test.go:1088`)
  got fixture data only — active users and a digest situation in people's window
  (R6) — its assertions are unchanged.
- Go: `internal/daemon/daemon_first_run_test.go` (no-data people runs, the
  briefing/day-plan bypass and its limits), `internal/guide/pipeline_outcome_test.go`
  (`RunOutcome`, `HasData` ≡ not `OutcomeNoData`), `internal/db/first_run_test.go`.
- Swift: `WatchtowerDesktop/Tests/Core/FeatureReadinessTests.swift`, `ReadinessQueriesTests`,
  `EmptyStateCopyTests` (Core); `ReadinessCenterTests`, `FeatureEmptyStateViewTests`,
  `EmptyStateTabWiringTests`, `EmptyStateCopyCoverageTests` (Desktop).

## Pending

- **P2 Home and P3 Try this** (spec §3–§4) wait for the Home mockup (#784).
