# First run — feature readiness, honest empty states, fresh-install first cycle (2026-10-14)

Board #779. Spec `docs/superpowers/specs/2026-10-14-first-run-home-design.md`
(§1 readiness + empty states = P1, §2 first cycle = P4); plan
`docs/superpowers/plans/2026-10-14-first-run-p1-p4.md`, whose "Spec corrections
found while planning" are folded in below. **P2 (Home: Getting ready + Today,
board #783)** is built from `docs/superpowers/plans/2026-10-15-first-run-p2-home.md`
(section "Home (P2)" below). **P3 (Try this → Recent work) is not built** (#785).

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
  3a. `needsSource(.jiraBoards)` — Jira's features only (`source == .jira`):
     a site is connected but no board is selected on a non-removed site
     (`ReadinessQueries.jiraBoardsSelected`, `jira_boards` is in the observed
     region). The daemon's Jira sync skips an account with no selected board
     (`internal/jira/sync.go`), so an ETA would never come true (#572). The
     line is "Choose Jira boards to get this" (`ReadinessSource.actionTitle`),
     and the action (`performEmptyStateAction(.connect(.jiraBoards))`, Home's
     Getting ready card) opens the **Boards** tab, not Settings. Stream
     Digests (`jiraOrMail`) waits on boards only while mail is not connected.
     Only enabled, not removed sites count, and v1 is install-wide (one
     site with a picked board counts for all; Go skips per account). On Home
     it is a waiting card, never a source row, so it keeps the Getting ready
     zone open (`GettingReadyPolicy.entries`);
  3b. `needsDigests` (#575, after 3a; the two never meet: their features are disjoint) — no content, the feature `runsOnlyWithDigests`
     (tracks, people cards) and `slack-digests` is in `disabledFeatureIDs`.
     Dual path with the daemon's compound gates (`phaseTracksAndRollups`,
     `phaseCustomTrackScan`, `phasePeopleCards` in `internal/daemon/daemon.go`,
     the people backfill hook in `history_backfill.go`); the Go guard rows
     `tracks_starved_without_digest` / `people_starved_without_digest` pin the
     gates, and `FeatureReadinessTests.testRunsOnlyWithDigestsMatchesTheDaemonGates`
     scans every non-test `internal/daemon/*.go` file (any line joining
     `Digest.Enabled` with another `X.Enabled` by `&&`/`||`) and fails when
     such a gate appears or goes without a matching `runsOnlyWithDigests`
     entry. Content beats it so
     a tab with data keeps showing it and Home keeps "Ready — Open". Line
     "Needs Slack Digests" (every place that shows it follows it with a
     **Turn on Slack Digests** button, named because it starts a heavy,
     different feature). `FeatureReadiness.turnOnFeatureID` picks what Turn on
     switches on and keys its progress/error by: `slack-digests` while the
     feature waits on it **and** while a Slack Digests Turn on has an error
     (an enable whose restart failed leaves Digests on, the state moves on to
     `scheduled`, and only the retry restarts — the tab and the Home card keep
     the error and **Try again**). A failed restart's error
     (`featureWasOn`) is cleared by any later successful restart or start:
     `AppState.clearRestartFailedTurnOnErrors` runs from the start queue's
     `DaemonStartQueue.onSuccess` (every successful `restart`, so
     `restartOnChain` and the account-change `restartLogging` too, and every
     start the app reports with `succeeded()`: the banner's Start/Retry, the
     background bring-up, `ensureDaemonRunning`, the LLM-data reset), from
     `DaemonManager.onRunningChanged(true)`, and after a successful empty-state
     Turn on — so a stop timeout (old daemon still running, no flip) clears on
     the next successful restart too. Home shows that error and its
     **Try again** once, on the first card it concerns
     (`GettingReadyZoneView.digestsOfferingCards`). Home's card button goes through
     `HomeLink.turnOn` → `performEmptyStateAction(.turnOn)` with the same busy,
     progress and error (`AppState.digestsTurnOnState`). Onboarding's Customize
     row of a feature on while Slack Digests is off shows **Needs Slack
     Digests** with a **Turn on Slack Digests** button
     (`OnboardingFeatureSelection.waitsOnSlackDigests`) — an offer, never a
     silent switch. Settings → Features' cascade dialog for Slack Digests adds
     "Tracks and People Cards stop running too while Slack Digests is off"
     (`FeatureManagerSection.cascadeMessage`). The launch is not decoupled
     (owner, ask #307), so token spend changes only when the owner turns Slack
     Digests on;
  4. `daemonStopped` (#577, owner ask #307 q4) — the daemon is not running and
     has been seen down for `daemonDownGrace` (30 s) or longer
     (`ReadinessInputs.daemonNotRunningSince` = `DaemonManager.notRunningSince`,
     set by the first status read or stop that finds it down, cleared when it
     runs, nil before the first read). Every later state is a promise a stopped
     daemon does not keep, so it wins over all of them; the grace keeps a
     restart (stop, then start) from flickering. The 30 s readiness tick
     re-evaluates the clock, so it shows 30–60 s after the daemon went down.
     The state is a line only ("Watchtower isn't running"); the one Start
     control is the app-wide banner (below). With the owner unknown,
     `honoringOwner` drops it for the owner-gated features like any promise,
     so the owner gap is what Home names;
  5. `preparing(detail)` — the newest `pipeline_runs` row is `running`, the
     daemon is running and `started_at` is under `preparingMaxAge` (2 h,
     `FeatureReadiness.swift:9`). An older `running` row is a dead process's
     leftover (`reapStalePipelineRuns` only reaps after 24 h) and falls through;
  6. `error(message)` — the newest run is `error` and there is no content;
  7. `waitingForSync(detail)` — the feature reads synced data, **Slack is
     connected** and `lastSyncTime == nil` (R7);
  8. `scheduled(Eta)` — the next run time from the feature's gate.
- **Linear (`ReadinessFeature.linear`, 2026-10-18).** No switch, no
  pipeline run (`phaseLinearSync` writes no `pipeline_runs` row), content
  `linear_issues`, source `ReadinessSource.linear`; `.anySource` counts a
  Linear workspace. Home never shows a Connect Linear row (the Jira row is the
  tracker prompt), only a card once Linear is connected. Blockers reads both
  trackers, so its `.jira` empty-state row is evaluated through
  `FeatureReadiness.trackerReadiness(jira:linear:)`.
- **`lastSyncTime` means "the first Slack sync finished".** It is the mtime of
  `last_sync.json` (`DaemonManager.readLastSyncTime`,
  `WatchtowerDesktop/Sources/WatchtowerCore/Services/DaemonManager.swift:95`), which only the Slack sync paths
  write: the daemon's Slack sync phase (`internal/daemon/daemon.go:631`) and
  a foreground `watchtower sync` (`cmd/sync.go:608`, `:628`). Without Slack it stays nil for ever,
  so rule 7 applies only while Slack is connected (`FeatureReadiness.swift:37`);
  a mail/Jira-only install goes straight to `scheduled`.
- **`Eta` is a vocabulary, not a duration** (`Readiness.swift:91`):
  `afterCurrentSync`, `nextCycle(minutes:)` from `sync.poll_interval`
  (`parsePollInterval`, garbage → 15), `at(hour:tomorrow:)`, `inAboutADay` (the
  people 24 h throttle from `last_people.txt`), `inHours(n)` (ideas/streams 6 h
  from `last_ideas.txt`/`last_streams.txt`, rounded up), `afterHistoryLoads`
  (memory only, "Waiting for history to load": before memory's first `done`
  run, a `running` history-backfill row started < 24 h ago and the backfill not
  switched off; beats an older memory error; dual path with Go's memory gate, see
  `history-backfill.md` § Memory gate, #578). No countdowns. Phrases
  and the one-line state wording live in `FeatureReadiness.phrase`/`line`
  (`FeatureReadiness.swift:94-115`): "Off — Turn on", "Connect Slack to get
  this", "Watchtower isn't running", "Preparing now", "Didn't work yet — retries automatically · <first line
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

### The daemon banner (#577)

One banner over every tab (`MainNavigationView`'s top inset,
`DaemonBannerView`, `AppState.daemonBanner` → `DaemonBanner.current`), first
match wins:

- `starting` — the banner's Start is waiting for the daemon
  (`AppState.isStartingDaemon`): "Starting Watchtower…" with a spinner, no
  buttons; a second Start meanwhile is ignored.
- `failed(reason)` — `AppState.daemonStartFailure`, stored on the start queue
  (`DaemonStartQueue.failure`) so restarts made outside AppState land here too:
  a start that exited non-zero ("The background sync did not start:
  <reason>."), a detach that exited 0 but no daemon within
  `daemonStartWaitBound` (60 s, polled every second — a first start after an
  update runs migrations first; `daemonDiedAfterStartText`), a background
  restart that failed (`DaemonStartQueue.restartLogging`, the Calendar tab's
  restart), the launch start failing (with a daemon still running after it —
  the old one, still exiting or not stopped — it reads as a restart failure,
  `daemonOldStillRunningText`), or a `watchtower` call stopped at its bound. **Retry**, **Open
  Logs** (the Logs window), **Dismiss**. Only a successful start or restart
  clears it (`DaemonStartQueue.restart`, the banner's Start, a bring-up, the
  Calendar restart, Reset LLM data), or a daemon newly up
  (`DaemonManager.onRunningChanged` fires on a flip only): a poll that merely
  sees the old daemon still running after a failed restart leaves it.
- `stopped` — `ReadinessCenter.daemonDown`, the same
  `FeatureReadiness.isDaemonDown` rule as the readiness state (30 s grace):
  "Watchtower isn't running, so nothing new arrives." with **Start** and
  **Dismiss**.

Dismiss hides both at once: it clears the failure and records this down
stretch (`stoppedBannerDismissedFor` = `DaemonManager.notRunningSince`); a
start and a new stop bring "isn't running" back. That is also how an owner who
stopped sync on purpose (`watchtower sync stop`) keeps it away; there is no
separate "stopped on purpose" state.

Start and Retry run `AppState.startDaemonFromBanner`. With a daemon running
and a failure on the banner, the failure is a restart that did not take (the
old daemon kept running, so a new account or feature is not wired in): Retry
runs a real restart (`restartWaiting`) and clears only on success. A running
daemon with nothing on the banner needs nothing. With no daemon,
`startDetached`, then the wait above.

**One start queue.** Every daemon start, stop-then-start and restart the app
makes runs on `DaemonStartQueue`, one item at a time. The entry point is
`AppState.enqueueDaemonStart` (and `restartOnChain` for a plain restart)
wherever `AppState` is at hand; the account view models and Google sign-in,
which have no `AppState`, use `LiveDaemonRestarter` /
`DaemonManager.restartLoggingQueued` on `DaemonStartQueue.shared`, the queue
`AppState` uses in production. Items:
the launch `ensureDaemonRunning`, onboarding's and Run setup again's
`bringUpDaemonInBackground`, the banner, a tab's Turn on and the feature offer
(`restartOnChain`), the Calendar tab's restart, every account and grant change
(`LiveDaemonRestarter`, Email/Calendar accounts, `GoogleAuthService`,
`GoogleConnectFlow`), Settings → Features and Confluence spaces, the Inbox
action strip, Reset LLM data (stop, wait for the exit, wipe and restart as one
item), Settings → Slack disconnect (stop, disconnect, start as one item; the
config and the Workspaces list are re-read whatever the outcome) and the full
reset (`AppState.stopDaemonAndRemoveEverything`: stop through `daemonControl`,
wait for the exit, and only then delete — a daemon that did not stop deletes
nothing and Settings shows `resetDaemonDidNotStopText`).

Items have no timeout of their own, so they never overlap. Every `watchtower`
call inside one is bounded where it runs (`DaemonManager.cliCallTimeout`,
60 s: past it the CLI process gets SIGTERM, SIGKILL 2 s later, and is reaped
before the call throws `.timedOut`; a daemon already handed off by `--detach`
is not touched), and the pid waits are bounded too (`restartStopGrace`,
`daemonStartWaitBound`), so an item always ends; Reset LLM data and the full
reset include the 60 s stop wait. Non-CLI work inside an item (the Slack
disconnect's `auth logout` runner) is not bounded here. An item never enqueues
onto the queue and awaits it. Outside it:
the launch-time CLI-store stop and the quit stop. The Google reconnect alert
no longer restarts on its own (a successful connect already does). The
Calendar tab has no message of its own while the daemon is down or after a failed restart (its restart goes through `restartOnChain`): the app-wide
banner says it.

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
  table's action ("Change the hour" for the hours, which opens Settings →
  Features — owner, ask #299 —, "Build a recap", "New target", "Add a folder"). Turn on and Connect
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
- **Day Plan, established install** (owner, ask #299): with day-plan rows
  (`.dayPlan` ready) but no plan for the date, `DayPlanView.emptyState` shows
  only "Today's plan at or after HH:00" (`todaysPlanLine`, the day-plan hour)
  instead of the first-run screen; a fresh install keeps the shared empty state.
- **Catch Up** reads the readiness of `.digests` only (R10; the spec said digests
  + inbox, the component takes one feature).
- **Spec §1.5 deviation as built:** the Inbox row has no button — the reaction
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

## Home (Desktop, P2)

Board #783, spec §3. Home is the page the app opens on: a **Getting ready**
zone while the install is still filling up, then **Today** — what needs the
owner now. It composes nothing: no AI call, no CLI call, no DB write; every
Today card reads an existing table, and Getting ready reads P1's readiness.

### Destination and landing

- `SidebarDestination.home` (`WatchtowerDesktop/Sources/App/SidebarDestination.swift:5`)
  is the first root item (`rootItems`, `:93`), has no feature or source gate
  and so shows on every install, and is exempt from the shared empty state
  (`EmptyStateCopyTable.exempt`, `EmptyStateCopy.swift:75`).
- **Launch default** — `AppState.selectedDestination` starts at `.home`
  (`AppState.swift:19`).
- **Fallback** — `SidebarDestination.fallbackDestination` (`:162`) returns
  Home for any tab that is no longer visible (it was Inbox, else Workbench).
  A Home link to a tab hidden right now is left to that fallback, so a stale
  link lands back on Home.
- **Onboarding** — a first run lands on Home for every goal set
  (`landOnHome`, `AppState.swift:1237`, called at `:875`); a setup re-run keeps
  the current tab. `OnboardingFinishPlan.landing` (Catch-Up / Workbench / AI
  Chat by goal) is gone.
- Existing deep links are unchanged: notifications, the mobile hub and Quick
  Capture land where they did.
- The first sync's line moved to `AppState.firstSyncLine`
  (`WatchtowerDesktop/Sources/App/AppState+Home.swift:18`), shared by
  Catch-Up's empty pane and Home's Getting ready.

### `HomeCenter`

`HomeCenter` (`WatchtowerDesktop/Sources/Services/HomeCenter.swift:70`) holds
the `HomeSnapshot` on `AppState` (`AppState.swift:65`), so a read survives tab
switches (`HomeCenterSurvivesNavigationTests`); `HomeView` only binds it and
never reads on its own. It is started with the main app's DB wiring right
after `ReadinessCenter` (`AppState.swift:1466`), which both launch and
`completeOnboarding()` reach, and stopped on quit.

- **Inputs.** The Today read (`HomeQueries.today`), `ReadinessCenter`'s map and
  hours, and `HomeEnvironment` (`HomeCenter.swift:8`): `now`, `calendar`,
  `ownerKnown`, `firstSync` (`AppState.firstSyncLine`) and `allowedTodayCards`
  (`AppState.homeTodayCardsAllowed`, `AppState+Home.swift:33`).
- **When it reads.** A GRDB `ValueObservation` over the Today tables that exist
  (`HomeQueries.observedTables`; a table missing mid-migration is left out of
  the region) sees this process' writes; a 30 s tick re-reads for the daemon's
  writes (another process) and keeps the meeting eyebrow's minutes current. A
  readiness, owner, first-sync or visibility change rebuilds from the last read
  without touching the DB (`withObservationTracking`). A failed pool read is
  logged and publishes the last read (or an empty one, before any good read)
  with every card marked failed: Home shows the read error and Getting ready,
  never an endless spinner, and stale content never passes as the all-clear;
  the next tick tries again. Until the first read lands the snapshot is nil
  and Home shows a spinner.
- **Getting ready memory** — `GettingReadyStore` (`HomeCenter.swift:23`), per
  install in `UserDefaults`; `HomeCenter` is its only writer:

  | Key | Type | Meaning |
  |---|---|---|
  | `home.gettingReady.hidden` | Bool | the owner's × — the zone is gone for good |
  | `home.gettingReady.firstShownAt` | Double, unix s | first time the zone was shown (the 3-day fold anchor) |
  | `home.gettingReady.completedAt` | Double, unix s | every card reached ready/error |

  A missing key, or a value of another type, reads as false/nil.

### Getting ready — `GettingReadyPolicy`

`GettingReadyPolicy.step`
(`WatchtowerDesktop/Sources/WatchtowerCore/Services/GettingReadyPolicy.swift:13`)
is pure: readiness, owner, memory, `sawUnready` (launch-scoped) and `now` in;
the zone and the memory to persist out. Rules, first match wins:

1. Readiness not evaluated yet (empty map) → hidden; no flicker before P1's
   first evaluation.
2. The owner's × (`hidden`) → hidden.
3. `completedAt` set → "Everything's ready" if the zone showed unready cards
   during this launch, else hidden (gone on the next launch).
4. `firstShownAt` more than 3 days ago (`foldAfter`) → hidden, whatever is
   still scheduled or failing.
5. Cards = the features whose readiness (through
   `FeatureReadiness.honoringOwner`, OWNER-02) is neither `off` nor
   `needsSource`, in `ReadinessFeature.allCases` order. Each `needsSource`
   feature goes into one row per missing source ("Connect Jira to get Boards,
   Workload, Blockers, Project Map and Releases", with **Connect Jira**). The
   zone opens on a card with a source (`source != .none`) or on a Connect row
   that a switched-on feature (`featureID != nil`) waits for — goals picked,
   Connect skipped, so every feature waits on a source and there is no card.
   Neither → hidden: a Development-only install (the knowledge-index card,
   Connect rows for the bare Slack/Calendar/Jira sources) does not open it.
6. Some card with a source, and every card terminal (ready or error) →
   (`daemonStopped` is not terminal — tone `waiting` — so a stopped daemon
   never completes the zone; its cards only carry the line, Start is the
   app-wide banner's)
   `completedAt = now`; "Everything's ready" if the zone showed unready cards
   during this launch, else hidden. A zone of Connect rows only (perhaps with
   the knowledge-index card) is never complete: it stays until a source
   connects.
7. Otherwise → shown, `firstShownAt` set once.

A ready card stays in the zone with **Ready** + **Open** until every card is
terminal (owner, ask #304); other cards show P1's `FeatureReadiness.line` —
no new ETA phrase, no countdown, no counters. `off` features are not cards
(they are P3's). Card text is `EmptyStateCopyTable.featureCard`
(`EmptyStateCopy.swift:147`). **Open** goes to the feature's tab
(`AppState.homeDestination`, `AppState+Home.swift:61`; Slack sync →
Statistics, knowledge index → Search, Jira → Boards); **Connect** runs the
empty states' `performEmptyStateAction(.connect)`. While the first sync runs,
its line (Catch-Up's) shows on top of the cards.

### Today — `HomeQueries.today` + `HomeTodayBuilder`

`HomeQueries.today`
(`WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/HomeQueries.swift:18`)
reads every card's source in one pass, each card on its own: a missing table
is that card having no content; a thrown error is logged (`NSLog`, card kind
+ message) and marks only that card `failed`. `HomeTodayBuilder.cards`
(`WatchtowerDesktop/Sources/WatchtowerCore/Services/HomeTodayBuilder.swift:12`)
is pure: each card shows only with content, in this fixed order (owner ask
#308; `TodayCardKind`'s case order), and only
while its tab is visible (`homeTodayCardsAllowed`; My targets and Agents
waiting have no tab gate).

| Card | Source | Shows when | Click |
|---|---|---|---|
| Since you were away | `CatchUpQueries.newestUnacknowledgedReady` | a ready, unacknowledged recap exists (the Catch-Up badge, `hasUnacknowledgedReady`) — the newest such, so a newer building or failed run does not hide it; eyebrow "SINCE THU 18:00", body = `tldr` | Catch-Up |
| Next meeting | `CalendarQueries.fetchNextEvent` + `hasPrep` | the event starts within 24 h; eyebrow "IN N MIN", "HH:MM" or "TOMORROW HH:MM"; line = time range · up to two attendees +N · "Prep ready" | the event in Calendar (`navigateToCalendarEvent`) |
| Waiting on you · N | `AgentActionQueries.awaitingOwnerCount` + `awaitingOwner(limit: 3)` (pending/failed, not workbench rows) and `ReminderQueries.fetchDue`; N = the badge's count | N > 0; top 3 items, newest first, chips Proposal / Failed / Reminder | Inbox (follows the Inbox tab) |
| Briefing | `BriefingQueries.fetchByDate(today)` | today's briefing has an item; body = the first item of the first non-empty section | that briefing (`navigateToBriefing`) |
| My targets | `TargetQueries.homeSummary` (limit 5) | any row; detail "Overdue · Oct 12", "Due today", "Due HH:MM" or "In progress" | the target (`navigateToTarget`); header → Targets |
| Agents waiting · N | `OwnerAskQueries.openAsksAllWorkbenches` (open asks joined to `projects.name`; an unreadable row is logged, named and left out, and marks the card failed) | any readable open ask; 3 oldest, chip = ask kind, detail = workbench | `WorkbenchRoute.forAsk` — the ask's session terminal, or the board for an ask filed outside the app; header → Workbench |

- `TargetQueries.homeSummary` (`TargetQueries.swift:237`): `project_id IS
  NULL` (PROJ-01 — workbench targets stay on their board), ownership `mine`,
  status todo/in_progress/in_review/blocked, and due on or before today or
  `in_progress`; due/overdue first by due date, then in-progress by
  `updated_at DESC`.
- **Read errors.** `HomeSnapshot.showsReadError` (`Home.swift:241`): no card
  to show and at least one allowed card failed → "Couldn't read today's items
  — see the log." `nothingNeedsYou` (`:247`) — "Nothing needs you right now."
  — only with no card, no failed read and no Getting ready zone shown. One
  failed card never hides the others and is never read as the all-clear; an
  unreadable open ask counts as Agents waiting's failed read, while the
  readable asks still show.

### Resolutions made while planning

1. **Feature card text.** `EmptyStateCopy` is keyed by tab and several tabs
   share a feature, so `featureCard` is keyed by feature: it reuses the tab's
   `landsHere` where one tab owns the feature and has its own sentence for
   Slack sync, stream digests, knowledge index and Jira.
2. **Development-only installs** show no zone (rule 5), keeping spec §3.1;
   an install whose goals switched features on but connected nothing shows
   the Connect rows (rule 5, final review ruling 2026-10-15).
3. **Existing installs** (decision 2) whose cards are all ready at the first
   look never see "Everything's ready"; it shows only when the zone completed
   during this launch.
4. **3-day fold anchor** is `firstShownAt`: onboarding completion has no
   stored time.
5. **`needsSource` rows** — one row per missing source, listing the tabs it
   unlocks.
6. **Briefing summary** (decision 3) — a briefing has no prose field; the
   first item of the first non-empty section in the detail view's order
   (attention, your day, what happened, team pulse, coaching), two lines.
7. **Since you were away** uses the unacknowledged recap's own window; no
   `CatchUpQueries.autoWindowStart`.
8. **Next meeting** — 24 h horizon; "Prep ready" from a non-empty
   `meeting_prep_cache` row (`CalendarQueries.hasPrep`), no prep text decoded.
9. **Waiting on you** items are what the badge counts (pending/failed
   proposals, due reminders), not the strip's 24 h tail of applied rows.
10. **Agents waiting** — count + the 3 oldest asks, routed by
    `WorkbenchRoute.forAsk` (`Workbench.swift:45`), the rule
    `WorkbenchNotificationPolicy` now shares.
11. **Calendar deep link** — `navigateToCalendarEvent` +
    `pendingCalendarEventID` (`AppState.swift:511`, `:371`), consumed by
    `CalendarEventsView.openPendingEvent` (`:205`) through
    `openLinkedEvent`.
12. **Today cards follow tab visibility** — a card whose tab is hidden is
    not shown, so no link leads to a hidden tab.

### Tests

Core: `GettingReadyTests`, `FeatureCardCopyTests`, `HomeTodayTests`,
`HomeQueriesTests` (`testOneFailingCardKeepsTheOthers`),
`WorkbenchTargetExclusionTests.testProj01_HomeSummaryNeverReturnsAProjectTarget`.
Desktop: `HomeCenterTests` (`testAllReadsFailedIsNotAllClear`),
`HomeCenterSurvivesNavigationTests`, `HomeLandingTests` (landing, launch
default, fallback, re-run keeps the tab), `HomeLinkTests`, `HomeViewTests`.

## Contracts and tests

- **No inventory file changes** (P1, P4 and P2). P2 adds a PROJ-01 guard
  case for `homeSummary` and changes no contract. P1/P4 touched no guard test:
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

## History backfill

The first cycle stays shallow on purpose; a background phase then loads a month of Slack, Gmail and IMAP history behind it, with a status-bar/tray progress line. See [history-backfill.md](history-backfill.md).

## Pending

- **P3 Try this → Recent work** (spec §4, #785): the `off` features Home's
  Getting ready leaves out are P3's.
