# First run — Home, feature readiness, honest empty states, Try this (2026-10-14)

Board: #779 (spec #780; P1 #781, P4 #782, P2 #783 with design #784, P3 #785),
under #739 (live onboarding feedback). Owner decisions: asks #278, #279, #282,
#283.

---

## Business summary (one page, for the owner)

**Problem.** A new user finishes onboarding and lands in an empty app.
Catch-Up says "Syncing… 3–5 min". The other ~20 tabs are blank or say
"No data", and nothing says what the product is for or where to start.
People decide within the first minute, not the first ten, and a user who
sees nothing deletes the app. Today the new users are colleagues the owner
installs for. The design must still work without the owner sitting next
to them.

**What the colleague sees after this ships**

- **Minute 1.** The app opens on **Home**, a new permanent first tab.
  - The top zone, **Getting ready**, shows what Watchtower is preparing
    right now: "Reading Slack — 1,240 messages so far". Each card has an
    honest time ("after this sync", "today at 08:00") and a one-line
    explanation of what the card will contain.
  - Below it, **Try this** cards list what works right now without waiting:
    record a meeting, dictate, ask the chat, bind a folder to Workbench.
  - Every other tab, opened early, says what will appear there, when, and
    what to do now. It never shows a blank page.
- **Hour 1.** Getting ready ticks over as digests, tracks, people cards
  and the first briefing arrive. On a fresh install the people cards and
  briefing are no longer held back for 24 h or until 08:00. When
  everything is ready, the zone folds away.
- **Day 2 and after.** Home is a **Today** page that only gathers what
  other tabs already have, each item a link into its tab:
  - who is waiting for you;
  - your next meeting and its prep;
  - the morning briefing;
  - your targets due or in progress;
  - agent asks waiting in Workbench;
  - what you missed since last time.

  The Try this cards give way to **Recent work** (recent sessions, chats,
  targets, recordings) as you use the product.

**What we are not doing**

- **No demo or sample data.** Fake rows get confused with real ones.
- **No score, points, badges or "N of 12".** Try this is just cards
  (owner, ask #283).
- **No new AI pipeline on Home.** The old Dashboard was removed on
  2026-09-14 because it was its own LLM-composed feed ("situations"):
  - it cost tokens every cycle;
  - it duplicated Catch-Up and the inbox strip;
  - nobody opened it.

  Home composes nothing. It reads existing tables and links into them.
- **We keep all the tabs** (owner, ask #279). We make their empty states
  honest instead of hiding them.

**Cost.** Home and readiness add no AI calls. The first-cycle acceleration
(P4) moves one people-card run and one briefing forward on a fresh
install. It does not add runs.

**Order.** P1 (readiness + empty states) and P4 (first cycle, Go) run in
parallel. P2 (Home: Getting ready + Today) follows. P3 (Try this → Recent
work) comes last. Home's visual design (#784) is approved before P2's code
starts.

---

## Technical spec

### 0. Terms

- **Fresh install:** a workspace whose pipeline has never produced its
  output. It is defined per pipeline (P4 below), not by the onboarding
  flag. A re-run of setup is not "fresh".
- **Tracked feature:** a feature with readiness. These are the AI and sync
  outputs a tab shows: Slack sync, digests (`slack-digests`), stream
  digests, tracks, people cards, briefing, day plan, ideas, memory,
  Attention detection/inbox, knowledge index, calendar, Jira.

### 1. Readiness model (P1)

**Where.** A pure value type in WatchtowerCore:
`FeatureReadiness.evaluate(_ inputs: ReadinessInputs) -> [ReadinessFeature: Readiness]`.
It has no GRDB, no AppState, no clock reads (`now` is an input). That makes
every rule a table test in `Tests/Core`. A `ReadinessCenter` on `AppState`
assembles the inputs and publishes the result. It lives on `AppState`, not
in a view, so a reading survives tab switches, per the house rule on async
state. It refreshes:

- on a GRDB `ValueObservation` over `pipeline_runs` and the content tables
  in §1.3;
- on `DaemonManager.syncProgress` / `lastSyncTime` changes (already polled);
- on `FeatureVisibilityStore` changes;
- on a 60 s timer, so scheduled times roll over.

**States** (`Readiness`), evaluated in this precedence:

| # | State | Rule | Shown as |
|---|---|---|---|
| 1 | `off` | feature disabled (`FeatureVisibilityStore`) | "Off — Turn on" |
| 2 | `needsSource(kind)` | the source it reads is not connected (`ConnectedSources`) | "Connect Slack to get this" |
| 3 | `ready` | its content exists (§1.3 count > 0) — content wins even while a new run is going | "Ready — Open" |
| 4 | `preparing(detail)` | newest `pipeline_runs` row for its pipeline is `running`, the daemon is running, and `started_at` is under 2 h old | "Preparing now" + `detail` |
| 5 | `error(message)` | newest finished run is `error` and no content | "Didn't work yet — retries automatically", short `error_msg`, link to Usage → Pipelines |
| 6 | `waitingForSync` | it reads synced data and no sync has finished (`lastSyncTime == nil`) | "Starts after the first sync" + sync detail |
| 7 | `scheduled(Eta)` | none of the above; the next run time follows from a gate (§1.2) | "Today at 08:00" / "After the next sync" |

Why the 2 h bound on `preparing`: a `running` row from a process that
died stays until `reapStalePipelineRuns` reaps it after 24 h
(`stalePipelineRunAfter`, `internal/daemon/daemon.go`). An older row, or
one seen while no daemon runs, falls through to rules 5–7.

**ETA vocabulary (honest, no fake precision).** `Eta` is an enum, not a
duration:

- `afterCurrentSync`: sync running, the pipeline is in the same cycle;
- `nextCycle`: about 15 min, from `sync.poll_interval`; shown "within
  ~15 min";
- `at(hour:)`: "today at 08:00" or "tomorrow at 08:00";
- `inAboutADay`: the people 24 h throttle;
- `inHours(n)`: ideas/streams every 6 h, rounded up to whole hours.

There is never a countdown and never minutes beyond "~15 min". The live
part is the sync heartbeat line (`SyncProgress.summary`), which is real.

#### 1.2 Per-feature inputs

| Feature (pipeline name in `pipeline_runs`) | Needs source | Gate → `Eta` | Content (§1.3) |
|---|---|---|---|
| Slack sync (`slack-sync`) | Slack | — (live heartbeat `sync_progress.json`) | `messages` |
| Digests (`digests`) | Slack | `afterCurrentSync` / `nextCycle` | `digests` |
| Stream digests (`stream-digests`) | Jira/mail | `last_streams.txt` + 6 h → `inHours` | `stream_digests` |
| Tracks (`tracks`) | Slack | `nextCycle` | `tracks` |
| People cards (`people`) | Slack | `last_people.txt` + 24 h → `inAboutADay`; on a fresh install (P4) `nextCycle` | `people_cards` |
| Briefing (`briefing`) | any | `briefing.hour` (default 8) → `at(hour:)`; fresh install (P4) → `nextCycle` | today's `briefings` row |
| Day plan (no `pipeline_runs`; `day_plans` + `day_plan_attempts.txt`) | any | `day_plan.hour` → `at(hour:)`; fresh install (P4, see Q1) → `nextCycle` | today's `day_plans` row |
| Ideas (`ideas`) | Slack | `last_ideas.txt` + 6 h → `inHours` | `ideas` |
| Memory (`memory`) | any | `nextCycle` | `memory_nodes` |
| Inbox / Attention detection (`inbox`) | any | `nextCycle` | `inbox_items` |
| Knowledge index (`knowledge-index`) | — | `nextCycle` | `kb_documents` |
| Calendar | calendar | `nextCycle` | `calendar_events` |
| Jira (`jira-boards`) | Jira | `nextCycle` | `jira_issues` |

Hours come from `ConfigService` (`briefingHour`, `dayPlanHour`), which
already parses `config.yaml`. Stamp files are read by name from the
workspace directory (`DaemonStampFiles.names`). For day plan, the absence
of a `pipeline_runs` row means only rules 1–3, 6 and 7 apply. It is never
`preparing` or `error`.

#### 1.3 Content counts

One new read-only query, `ReadinessQueries.contentCounts(_ db:) -> ReadinessCounts`.
It is a single `SELECT` of `EXISTS(...)` subselects over the tables above
(today's row for briefing/day plan, the owner's for owner-scoped ones). It
uses existence, not `COUNT(*)`, so a large workspace stays cheap. A
missing table (an install mid-migration) reads as "no content", never as
an error.

#### 1.4 Shared empty-state component

`FeatureEmptyState(feature:, copy:)` is a view in `Views/Components`. It
renders, in order:

1. an icon and a title ("No briefings yet");
2. **what lands here** (one sentence);
3. the **readiness line** for its feature (state + `Eta`, and for
   `preparing`/`waitingForSync` the live sync line);
4. **what to do now**: one primary button (Turn on / Connect / Open
   Settings → Features / the tab's own action) and at most one secondary
   link.

`off` uses `FeatureManagerService.enableNow([id])`, the same path as the
related-features offer (restart once). It never goes through the staged
Settings changes. Copy is a static table `EmptyStateCopy` in WatchtowerCore
keyed by `SidebarDestination` raw value, so a CaseIterable sweep test
proves no tab is missing. It replaces the private empty states. Existing
specialised ones (Catch-Up's first-sync line, the Inbox reaction cheat
sheet, `NoOwnerEmptyState`) are kept and composed inside it, not deleted.
The "No matches" search-result states are untouched: they are a different
state (filter, not emptiness).

#### 1.5 Per-tab copy

UI text is English only. "Readiness" = the line from §1.1.

| Tab | What lands here | Readiness of | Do now |
|---|---|---|---|
| Home (P2) | — (never empty, §3) | — | — |
| Catch Up | A recap of what you missed while away, built from Slack, mail, Jira and the calendar | digests + inbox | "Build a recap" (existing) |
| Briefings | A morning briefing: meetings, what needs you, what changed. **Generated once a day at or after HH:00** (replaces the wrong "after sync completes") | briefing | Change the hour (Settings → Briefing) |
| Day Plan | Your day in time blocks, from the calendar, targets and the briefing. Once a day at or after HH:00 | day plan | Change the hour |
| Inbox | Proposals and due reminders that need you, plus reaction shortcuts | inbox | — (no button; the existing reaction cheat sheet is shown inline, as built) |
| Ideas | Ideas and decisions picked up from conversations, every ~6 h | ideas | — |
| Calendar | Today's meetings with prep | calendar | Connect a calendar |
| Targets | Your tasks — from you, from Slack reactions, from meetings | — (no pipeline) | "New target", "React with an emoji in Slack" |
| Tracks | Ongoing topics Watchtower follows across channels | tracks | — |
| Workbench | Boards bound to a folder, where Claude Code or Codex works | — | "Add a folder" |
| Digests | Per-channel summaries after each sync | digests | — |
| People | A card per colleague: role, what they work on, how to reach them. First cards after the first digests | people cards | — |
| Memory | What the assistant remembers about your work | memory | Turn on (off by default outside Work communication) |
| Workload / Blockers / Project Map / Releases / Boards | Jira views | Jira | Connect Jira |
| Statistics | Activity across channels | Slack sync | — |
| Search | Search across messages, docs and knowledge | knowledge index | — (existing) |
| Usage | AI spend and pipeline runs | — | — |
| MCP Server | How to use Watchtower from Claude Code / Codex | — | existing |
| AI Chat | existing `ChatEmptyState` + suggested prompts (P3 reuses them) | — | — |

People, Digests, Memory, Statistics and Workload today show a blank page
or "No data". These rows close that gap.

### 2. First-cycle acceleration (P4, Go)

**Briefing.** In `shouldRunBriefing` (`internal/daemon/daemon.go`), the
`now.Hour() < targetHour` gate is skipped when the install is fresh for
the briefing. Fresh means `d.lastBriefing.IsZero()` (no
`last_briefing.txt`) **and** the owner has no `briefings` row at all. The
DB check is what keeps a wiped stamp file (Reset LLM data,
`DaemonStampFiles.clear`) from re-triggering an early briefing on an old
install. Everything else is unchanged:

- the same-day check;
- the attempt budget (`briefingAttemptsExhausted`, `maxDailyAIAttempts`);
- `briefingHasOwner`;
- the briefing pipeline's own "no data → (0, nil)" skip.

So the first briefing runs at the end of the first cycle that has digests
or tracks. A no-data first cycle consumes no budget and retries next cycle.
From the next day on, the hour gate applies.

**Day plan (see Q1).** `shouldRunDayPlan` gets the same freshness bypass:
no `lastDayPlanDate` and no `day_plans` row for the owner. Its existing
`GetDayPlan` existence check stays.

**People cards.** The 24 h throttle is not the real first-cycle blocker.
`phasePeopleCards` stamps `lastPeople` on **every** `(n, nil)` return,
including the two "nothing to do yet" paths in `guide.Pipeline.RunForWindow`
(`internal/guide/pipeline.go`):

- no active users with enough messages;
- no situations from digests yet.

So a first cycle that ran before digests produced situations locks people
cards out for 24 h. The fix is contract-level. `guide.Pipeline` reports
*why* it returned zero (`skipped: noData` vs `covered`/`generated`), and
the daemon stamps `lastPeople` only for `generated` or `covered`. A
`noData` return leaves the stamp alone and records no attempt. Both
no-data paths return before any AI call (verified in `RunForWindow`), so
re-checking every cycle costs no tokens. The attempt budget
(`peopleAttemptsExhausted`) is untouched.

**Inventory.** No guard test covers these gates. `docs/inventory` has no
briefing/people/day-plan cadence contract. The attempt budgets from the
strong-tier cost fixes (`docs/features/strong-tier-cost-fixes.md`) are
kept as they are. `docs/daemon-pipeline.md` Stage 11's "First cycle note"
and the briefing/day-plan stage notes are updated. No owner approval for a
contract change is needed beyond this spec.

**Cost note.** One briefing and possibly one day plan move earlier on day
one. People cards run in the first cycle that has situations instead of
24 h later. The number of runs per day does not grow.

### 3. Home (P2)

**Destination.** A new `SidebarDestination.home` (raw value `"home"`,
title "Home", icon `house`):

- It is the **first root item**.
- It has no feature or source gate.
- It is never hideable (root items have no hide menu).

**Landing.**

- Finish lands on Home for every goal set. `OnboardingFinishPlan.landing`
  collapses to Home and its goal mapping is deleted.
- A setup re-run keeps the current tab (unchanged).
- At launch, `AppState.selectedDestination` defaults to `.home` (was
  `.inbox`).
- `SidebarDestination.fallbackDestination` falls back to `.home` (was
  Inbox, else Workbench). Home is always visible, so the two-step rule
  goes away.

Catch-Up loses nothing: it is a Today card, and the first-sync line also
shows in Getting ready. See Q2 for existing installs.

**Model.** `HomeCenter` on `AppState` (WatchtowerCore logic,
Desktop-side observation) builds `HomeSnapshot` from `ReadinessCenter` and
read-only queries. It has no writes, no CLI calls and no AI. Zones render
top to bottom.

#### 3.1 Getting ready

- One card per tracked feature that is enabled and has a source, in
  pipeline order.
- Each card shows the feature title, the one-sentence "what it is" from
  `EmptyStateCopy`, the readiness line, and **Open** once `ready`.
- `off` features are not cards here; they belong to Try this.
- `needsSource` features show as one combined row: "Connect Jira to get
  Boards, Workload…".

The zone **collapses** to a single line ("Everything's ready", then gone
on the next launch) when every card is `ready` or `error`. It also
collapses when the owner hides it (×, a per-install `UserDefaults` key
`home.gettingReady.hidden`). An install with no tracked feature enabled
(Development only) never shows it. See Q5 for a time cap.

#### 3.2 Today

Each card shows only when it has content. There are no empty cards. Each
card is a deep link into its tab.

| Card | Source (existing unless marked new) | Links to |
|---|---|---|
| Waiting on you | `SidebarCountsViewModel.inboxStripCount` + the strip's top 3 items | Inbox |
| Next meeting | `CalendarQueries.fetchNextEvent` + its prep (`EventLink`) | Calendar event |
| Briefing | `BriefingQueries.fetchByDate(today)` — headline (see Q3) | Briefings |
| My targets | **new** `TargetQueries.homeSummary`: open, ownership mine, due ≤ today or `in_progress`, limit 5 | Targets / the target |
| Agents waiting | **new** `OwnerAskQueries.openAsksAllWorkbenches` (today's `openAsks` takes one `projectID`) | Workbench → the ask |
| Since you were away | `CatchUpQueries.autoWindowStart` + latest recap from `fetchRecaps(limit: 1)` | Catch-Up |

Order is fixed as listed, so the page doesn't reshuffle. With no card and
Getting ready collapsed, Today shows one line: "Nothing needs you right
now."

#### 3.3 Try this → Recent work

This zone has a fixed budget of **6 rows**. **Recent work** fills it
first: a merged list by time of the newest items from

- `TerminalSessionQueries.fetchAllWorkbenchSessions` (last active);
- `ChatConversationQueries` (updated);
- targets the owner touched;
- `MeetingTranscriptQueries.fetchRecordingList`.

**Try this** cards (§4) take whatever slots are left, at most 3 at a time.
When Recent work fills all 6, Try this becomes one link, "More to try",
which opens a sheet with the remaining cards. When every card is done or
dismissed, the zone is Recent work only. A brand-new install therefore
sees 3 Try this cards and grows into Recent work with no switch.

### 4. Try this cards (P3)

Each card has:

- a title;
- one or two sentences on what it is;
- **which model runs**;
- the **cost class**;
- one action button;
- "Not interested" (dismiss, per-install `UserDefaults`).

A card disappears for good when its **completion signal** turns true. The
signal is read from data, never a click on the card. A card whose
prerequisite source is missing sorts after the ones the owner can do now.
There is no counter anywhere.

| Card | Model | Cost class | Done when | Action |
|---|---|---|---|---|
| Record a meeting | Local transcription on this Mac; recap by Claude/Codex through your CLI | Local + light | a `meeting_transcripts` row exists | Start recording |
| Dictate anywhere | Local speech model; optional cleanup by Claude | Local | first successful dictation (per-install flag set by `DictationCenter`) | Show the hotkey |
| Ask the chat what you missed | Claude/Codex through your CLI | Light, per question | a `chat_conversations` row with an owner message | Open chat prefilled "What did I miss yesterday?" |
| Bind a folder to Workbench | None by itself; agents run on your Claude Code/Codex | Your agent's usage | a `projects` (workbench) row exists | Add a folder |
| Turn a Slack reaction into a task | None (mechanical) | Free | a `reaction_commands` row exists | Show the cheat sheet |
| Turn on Memory | Claude/Codex through your CLI, every cycle | Heavier | `memory` enabled and a `memory_nodes` row exists | Turn on |
| Connect your calendar | None for sync; meeting prep rides the briefing | Free | calendar connected | Connect |
| Connect Jira | None for sync | Free | Jira connected | Connect |
| Search Confluence with your messages | None (full-text index) | Free | an `ext_sources` row exists | Connect Confluence |
| Pair your iPhone | None | Free | the mobile hub reports a paired phone | Settings → iPhone |
| Plan your day | Claude/Codex through your CLI, once a day | Light | the Day Plan tab was opened with a plan present (per-install flag) | Open Day Plan |
| See your ideas and decisions | Claude/Codex through your CLI, every ~6 h | Light | the Ideas tab was opened with ideas present (per-install flag) | Open Ideas |

Card copy lives in WatchtowerCore (`TryThisCatalog`), next to
`EmptyStateCopy`, not in `internal/features/registry.go`. The registry's
descriptions are settings copy that talks about AI cost. They stay
unchanged and are not reused verbatim.

### 5. Sub-projects, dependencies, tests

Swift tests go in `Tests/Core` unless they need a view. Go tests go in the
touched package.

**P1 — readiness + empty states** (depends on: none)

- `FeatureReadinessTests`:
  - off wins over everything;
  - needsSource without Slack;
  - content means ready even while a run is `running`;
  - running is preparing only with a live daemon and `started_at` < 2 h;
  - a stale running row is not preparing;
  - error only without content;
  - waitingForSync while `lastSyncTime` is nil;
  - briefing before the hour gives `at(hour:)`, after the hour gives
    `nextCycle`;
  - people from the stamp gives `inAboutADay`;
  - day plan never preparing/error;
  - the ETA vocabulary never yields a minute value other than ~15;
  - **degenerate:** empty inputs give every feature `off` or
    `waitingForSync`, no crash.
- `ReadinessQueriesTests`:
  - each existence flag flips on one row;
  - a missing table reads false.
- `EmptyStateCopyTests`:
  - every `SidebarDestination` case has copy (CaseIterable sweep);
  - the Briefings copy names the configured hour;
  - no copy says "after sync" for an hour-gated feature.
- `FeatureEmptyStateTurnOnTests`: Turn on calls `enableNow([id])` and not
  the staged path.

**P4 — first cycle** (depends on: none; Go, parallel to P1)

- `TestDaemon_FirstBriefingIgnoresHourOnFreshInstall`.
- `TestDaemon_BriefingHourGateAppliesAfterFirst`.
- `TestDaemon_BriefingFreshNeedsNoRowsEvenWithoutStamp`: stamp wiped,
  rows present, so the gate applies.
- `TestDaemon_FirstBriefingNoDataKeepsBudget`.
- `TestDaemon_FirstDayPlanIgnoresHourOnFreshInstall` (if Q1 = yes).
- `TestDaemon_PeopleNoDataRunDoesNotStamp`.
- `TestDaemon_PeopleCoveredRunStamps`.
- `TestDaemon_PeopleGeneratedRunStamps`.
- `TestDaemon_PeopleNoDataRecordsNoAttempt`.
- `guide`: `TestRunForWindow_ReportsNoDataVsCovered`.

**P2 — Home: Getting ready + Today** (depends on: P1, design #784)

- `HomeLandingTests`:
  - Finish lands on Home for every goal set, including zero goals;
  - a re-run keeps the tab;
  - the launch default is Home;
  - the fallback is Home.
- `GettingReadyTests`:
  - cards only for enabled + sourced features;
  - collapses when all ready/error;
  - × persists;
  - Development-only shows nothing.
- `HomeTodayTests`:
  - a card shows only with content;
  - fixed order;
  - asks across all workbenches;
  - `homeSummary` picks due ≤ today and in-progress mine, limit 5;
  - **degenerate:** an empty DB gives "Nothing needs you right now".
- `HomeCenterSurvivesNavigationTests`: start a refresh, switch tabs, the
  snapshot lands.

**P3 — Try this → Recent work** (depends on: P2)

- `TryThisCatalogTests`:
  - every card has model, cost class, signal and action;
  - completed cards are hidden;
  - dismissed cards are hidden;
  - cards with a missing prerequisite sort last.
- `RecentWorkSlotsTests`:
  - 0 recent → 3 cards;
  - 4 recent → 2 cards;
  - 6 recent → "More to try";
  - all cards done → Recent work only;
  - merge order by time across the four sources.

Each sub-project updates `docs/app-guide.md` (Home section, empty states)
and, for P4, `docs/daemon-pipeline.md`.

### 6. Owner decisions (spec approved 2026-10-14, ask #285)

The owner approved the spec without overriding any recommendation, so each
open question is settled as recommended:

1. **Day plan in P4:** yes, the first day plan skips the `day_plan.hour`
   gate on a fresh install, once.
2. **Home for existing installs:** yes, every install opens on Home at
   launch; one rule for everyone.
3. **Briefing card on Today:** the first-paragraph summary, two lines,
   truncated.
4. **Try this slots:** up to 3 cards at once within a 6-row zone.
5. **Getting ready time cap:** the zone folds after 3 days even if a
   feature never becomes ready.
6. **Name:** "Home" (the name used throughout the brainstorm).
7. **Catch-Up landing:** onboarding lands on Home; Catch-Up is a card there.

Any of these can still be revisited on the Home mockup (#784) before P2.
