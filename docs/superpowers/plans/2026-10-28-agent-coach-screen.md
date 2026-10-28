# Agent coach Plan 2 — the Analytics screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the coach (metrics, proposals, accepted edits, Run Now) on the workbench's Analytics pane above today's statistics, redesigned; periods 1/7/30 days; fold the instruction miner into the coach and show a coach proposal on Home.

**Architecture:** Go adds `coach status --days`, a run lock, `lead` sentences in `agents report`, and the miner import; the Desktop gets a `CoachCenter` over the coach CLI (pinned `--json` keys), Codable models and pure presentation rules in WatchtowerCore, new pane sections, a reworked statistics stack and a Home row read from `coach_proposals`.

**Tech Stack:** Go 1.26 (cobra CLI, `internal/coach`, `internal/agentreport`, `internal/daemon`), SwiftUI + GRDB (WatchtowerDesktop, WatchtowerCore), the design kit.

**Spec:** `docs/superpowers/specs/2026-10-28-agent-coach-screen-design.md` (parent: `docs/superpowers/specs/2026-10-26-agent-coach-design.md`). Mockup: `docs/design/mockups/agent-coach/screen-plan2.html`.

## Global Constraints

- Every edit needs the owner's press: Accept / Decline / Roll Back / Run Now run the coach CLI from the Desktop (`confirmWithOwner` answers Desktop-started commands without a window). Nothing applies on its own (COACH-01).
- `--json` keys are only added, never renamed or removed (`coach status|proposals|run`, `agents report`).
- `coach status --days N`: 1–90, default 14. Verdicts keep 14 days (`coach.Judge` untouched).
- Periods on the pane: `day = 1`, `week = 7`, `month = 30`; default 7; a stored raw value 0 (old "All") reads as `.week`.
- Trend rule: lower is better for every metric; |change| < 5 % → "about the same" (neutral); `known == false` or `n < 3` → "few data", greyed, no trend; `previous == nil` → value without trend; `owner_loop` change in points, the others in percent.
- Proposals on a pane: `workbench_id == pane id` or `workbench_id == 0` (global). Home candidates: proposals of workbenches with `projects.agent_analytics = 1`, or global ones when at least one such workbench exists.
- Home row: a change of more than 4 lines shows 4 lines + "…" and only **Open in Analytics** / **Decline**.
- Wording: "since this edit", never "because".
- Lead sentences are built from report counts and names only, never transcript text (AGENTLOG-01); empty lead hides the line.
- Design kit only (no hex, no raw metrics, `kit_*` lint); new screens registered in `DesignShotCatalog` on fixture data (`acme`, `example.com`).
- Hint and lead sentences in `digest.language` (`agentreport/i18n.go`); UI chrome in English.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for Swift); the gate runs once per phase.

## Review Focus

1. **Coach CLI failure reaches the Desktop** — `coach … --json` exits non-zero, and `CLIRunnerError.nonZeroExit` carries stderr only; the failure object must be parsed from stderr's last line (Task 1 echoes it there), else every stale/busy turns into a raw error string. Tested in Task 1 (Go) and Task 5 (Swift fake runner).
2. **Period change mid-load** — switching 7 → 1 day while a `coach status` for 7 is in flight must not show the 7-day tiles under the 1-day header. Task 5 test `testPeriodChangeDropsStaleStatus`.
3. **A proposal decided elsewhere** (CLI, Home, another pane) — accept on a pane whose list is stale returns `stale`/`state_changed`; the card closes with its line and the list reloads. Task 5 test `testStaleAcceptClosesCardAndReloads`.
4. **Global proposal on Home with analytics on nowhere** — no row (no dead "Open in Analytics"). Task 8 test `testNoRowWithoutAnalyticsOnWorkbench`.
5. **Growth list with tiny sources** — shares under 1 % print `<1%`, never `0%`; more than 6 sources fold. Task 7 tests `testShareUnderOnePercent`, `testGrowthFoldsAfterSix`.

---

## Phase A — Go (Tasks 1–3, independent lanes)

### Task 1: `coach status --days`, the run lock, failure JSON on stderr

**Depends on:** none

**Files:**
- Modify: `cmd/coach.go` (`coachPeriod` use in `runCoachStatus`, flag, `coachRun` failure output, `runCoachNow` lock), `internal/daemon/coach.go` (`phaseCoach` lock)
- Modify: `internal/fsutil/lock.go` (add `TryLockFile`)
- Test: `cmd/coach_test.go`, `internal/daemon/coach_test.go` (or the existing coach daemon test file), `internal/fsutil/lock_test.go`
- Modify: `docs/inventory/coach.md` (COACH-01 CLI line + changelog), `docs/features/agent-coach.md` (CLI section)

**Interfaces:**
- Produces: `fsutil.TryLockFile(path string) (unlock func(), ok bool, err error)` — non-blocking `LOCK_EX|LOCK_NB`, file created 0600, left in place.
- Produces: `coach.LockPath(workspaceDir string) string` = `<workspaceDir>/coach.lock` (in `internal/coach/coach.go`).
- Produces: CLI `coach status --days N` (int, default 14, 1..90 else usage error); `coach run` failure code `busy`; with `--json`, every failure object is also written as one line to stderr (last line).

- [ ] **Step 1: Failing tests**
  - `TestTryLockFile_SecondHolderGetsFalse` — first `TryLockFile` ok=true, second ok=false, after unlock ok=true.
  - `TestCoachStatus_DaysWindow` — with `--days 7`, `period.since` = until − 7 days; with `--days 1` = until − 1 day; default = 14 days; `--days 0` and `--days 91` exit with a usage error.
  - `TestCoachRun_BusyWhenLocked` — hold `coach.LockPath(ws)`, run `coach run --json` (owner confirm seam stubbed to confirm): stdout JSON `{"ok":false,"code":"busy"}`, non-zero exit, stderr's last line is the same JSON object.
  - `TestCoachJSONFailure_EchoedOnStderr` — `coach accept 999 --json` (missing id): stdout and stderr's last line decode to the same `{"ok":false,...}`.
  - `TestPhaseCoach_SkipsWhenLocked` — lock held: the phase writes neither `last_coach.txt` nor `last_coach_failed.txt` and makes no model call.
- [ ] **Step 2:** Run `go test ./internal/fsutil ./cmd -run 'TryLock|CoachStatus_Days|CoachRun_Busy|CoachJSONFailure' ` and `go test ./internal/daemon -run PhaseCoach_SkipsWhenLocked` — FAIL.
- [ ] **Step 3: Implement.** `--days` replaces `coachPeriod` in `runCoachStatus` only (`time.Duration(days)*24*time.Hour`); `Short` becomes "Metrics of the last N days (default 14) against the N before". `runCoachNow` (not `--dry-run`) takes `TryLockFile(coach.LockPath(...))` after `confirmWithOwner`, before judging; not ok → `&coachCodedError{code: "busy", err: errors.New("the coach is already running")}`. `phaseCoach` takes the same lock first; not ok → log `coach: busy, skipped` and return. `coachRun` with `coachFlagJSON` writes the failure JSON to stdout (as today) and to `cmd.ErrOrStderr()`.
- [ ] **Step 4:** Re-run the commands of Step 2 — PASS; `go test ./internal/coach ./cmd -run Coach` — PASS.
- [ ] **Step 5:** Docs: COACH-01's CLI line gains `status --days` and `busy`; changelog line "2026-10-28 (Plan 2): `--days`, `busy`, stderr echo; nothing relaxed". Commit `feat(coach): status --days, run lock, failure JSON on stderr (#1120)`.

### Task 2: `lead` sentences in `agents report`

**Depends on:** none

**Files:**
- Modify: `internal/agentreport/context.go`, `skills.go`, `trouble.go` (add `Lead string \`json:"lead"\`` to `ContextReport`, `SkillsReport`, `TroubleReport`), `internal/agentreport/i18n.go` (keys `lead.context`, `lead.skills`, `lead.trouble` in en and ru), the builder that fills the blocks (`build.go`)
- Test: `internal/agentreport/lead_test.go`; AGENTLOG-01 guard in the existing `agentlog01`-style test file of `agentreport` (or new `TestAGENTLOG01_LeadHoldsNoEventText`)
- Modify: `docs/features/agent-analytics.md` (keys), `docs/inventory/agent-analytics.md` (AGENTLOG-01 changelog line)

**Interfaces:**
- Produces: JSON `context.lead`, `skills.lead`, `trouble.lead` (string, `""` when the block has no data).

Sentences (en / ru), from counts already in the block:
- context: "Every session starts with {baseline} tokens; {top1} is {p1}%, {top2} {p2}%." / "Каждая сессия стартует с {baseline} токенов; {top1} — {p1}%, {top2} — {p2}%." (`""` when `facts_sessions == 0`)
- skills: "The skill list costs {listing} tokens per session; {unused} of {listed} skills were not used in this period." / "Список скиллов — {listing} токенов в каждой сессии; {unused} из {listed} не вызывались за период." (`""` when `listed == 0`)
- trouble: "{failed} failed calls and {denied} permission denials; most of them {top}." / "{failed} упавших вызовов и {denied} отказов в разрешении; чаще всего — {top}." (`""` when both are 0; the "; most …" clause dropped when no top class)

- [ ] **Step 1: Failing tests** `TestLead_Context_EnRu`, `TestLead_Skills_EnRu`, `TestLead_Trouble_EnRu` (exact strings for a fixture report; empty block → `""`), `TestAGENTLOG01_LeadHoldsNoEventText` (fixture event text `SECRET-EVENT-TEXT` never appears in any lead).
- [ ] **Step 2:** `go test ./internal/agentreport -run 'Lead|AGENTLOG01'` — FAIL.
- [ ] **Step 3:** Implement with `Lang.f` and the existing `tok`/`count` helpers; plural forms via `Lang.form`.
- [ ] **Step 4:** Same command — PASS; `go test ./internal/agentreport` — PASS.
- [ ] **Step 5:** Docs lines; commit `feat(agentreport): lead sentence per block (#1120)`.

### Task 3: Fold the instruction miner into the coach

**Depends on:** none (touches `cmd/coach.go` `runCoachNow` at one call site — merge after Task 1 if both lanes edit it)

**Files:**
- Create: `internal/coach/import.go` — `ImportSuggestions`
- Modify: `internal/coach/propose.go` (dismissed-text block in validation), `internal/daemon/daemon.go:679` (drop the `phaseInstructionSuggestions` call; keep the file's helpers only if still referenced, else delete the phase file and its test), `internal/daemon/coach.go` (call `ImportSuggestions` before proposing), `cmd/coach.go` (`runCoachNow` calls it too, not on `--dry-run`)
- Test: `internal/coach/import_test.go`, `internal/coach/propose_test.go`
- Modify: `docs/inventory/workbench.md` (PROJ-22 amendment, ask #722), `docs/features/agent-instructions.md` (miner retired), `docs/features/agent-coach.md` (fold)

**Interfaces:**
- Produces: `func ImportSuggestions(main *db.DB, now time.Time) (int, error)` — for each open `instruction_suggestions` row (newest `last_seen_at` first) while open coach proposals < 3: build an `add` proposal to destination `field` (`session` → `DestSession`, `procedure` → `DestProcedure`, `chat` → `DestChat`) for the row's `workbench_id` (NULL → 0), before = the destination's current text, after = before + "\n" + row text, title = the row text cut to 80 runes, `why` = "You said this in {session_count} sessions", metric `owner_loop`, evidence `[{kind:"suggestion", ref:"sg:<id>"}]`, validated by the same `ValidateAfter`/budget rules; skip a row already referenced by any proposal's evidence `sg:<id>` or whose fingerprint is known; an invalid row is skipped and left open. Returns the number written.
- Produces: the Proposer drops a proposal whose added lines equal (trimmed, case-folded) a `dismissed` suggestion text (`db.ListInstructionSuggestionTexts("dismissed")`), and `Validate` accepts evidence kind `suggestion` when the row exists.

- [ ] **Step 1: Failing tests** `TestImportSuggestions_CarriesOpenRowsUpToCap` (4 open rows, 1 open proposal → 2 written, newest first), `TestImportSuggestions_Idempotent` (second call writes 0), `TestImportSuggestions_SkipsInvalid` (over-budget row stays open, not written), `TestPropose_DismissedSuggestionTextBlocked`, `TestDaemon_NoInstructionSuggestionPhase` (a cycle never calls the miner).
- [ ] **Step 2:** `go test ./internal/coach -run 'ImportSuggestions|DismissedSuggestion'`, `go test ./internal/daemon -run NoInstructionSuggestionPhase` — FAIL.
- [ ] **Step 3:** Implement; the import's writes go through the existing proposal insert in one short transaction, no model call.
- [ ] **Step 4:** Same commands — PASS; `go test ./internal/coach ./internal/daemon ./internal/instructions` — PASS.
- [ ] **Step 5:** PROJ-22 amendment text: "Suggestions from the owner's repeated lines reach the owner as coach proposals (agent coach, ask #722); each still needs the owner's Accept. `remember:` unchanged." Guard tests of PROJ-22 are kept; a test that asserted the daily phase runs is replaced by `TestDaemon_NoInstructionSuggestionPhase` only with that note in the changelog. Commit `feat(coach): the instruction miner folds into the coach (#1120)`.

**Phase A gate (controller):** `make test`, `make lint`.

## Phase B — Desktop core (Tasks 4–5)

### Task 4: WatchtowerCore models and presentation rules

**Depends on:** Task 1, Task 2 (JSON shapes only)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/Coach.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Models/CoachPresentation.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentReport.swift` (`lead: String?` on the context/skills/trouble models)
- Test: `WatchtowerDesktop/Tests/Core/CoachDecodingTests.swift`, `CoachPresentationTests.swift`, fixtures `Tests/Core/Fixtures/coach-status.json`, `coach-proposals.json` (from real `--json` output shapes, sample data)

**Interfaces (Produces):**
- `package struct CoachMetric: Decodable, Equatable { value: Double?; n: Int; known: Bool; previous: Double? }`
- `package struct CoachStatus: Decodable, Equatable { ok: Bool; period: CoachPeriod; metrics: CoachMetrics; open: Int; lastRun: String }` with `CoachPeriod { since, until: String }`, `CoachMetrics { corrections, taskHours, taskCostUSD, ownerLoop, specFindings, reviewComments: CoachMetric }` (snake_case keys).
- `package struct CoachProposal: Decodable, Equatable, Identifiable` — every pinned key (`id`, `title`, `why`, `destination`, `workbenchID` (0 = global), `promptID`, `kind`, `metric`, `before`, `after`, `evidence: [CoachEvidence{kind, ref}]`, `sources`, `status`, `createdAt`, `decidedAt: String?`, `baseline: Double?`, `verdict`, `verdictValue: Double?`, `verdictAt: String?`, `revertsID`).
- `package struct CoachFailure: Decodable { ok: Bool; error: String; code: String?; diff: String? }` and `static func CoachFailure.parse(stderr: String) -> CoachFailure?` (last non-empty line).
- `package enum CoachTrend: Equatable { case better(String), worse(String), same, fewData, noTrend }` and `static func CoachTrend.of(_ m: CoachMetric, points: Bool) -> CoachTrend` (the Global Constraints rule; label e.g. `"↓ 30% · was 3.0"`, points `"↓ 9 pts · was 31%"`).
- `static func CoachProposal.forPane(_ all: [CoachProposal], workbench: Int64) -> (open: [CoachProposal], accepted: [CoachProposal])` — open sorted newest first; accepted = `accepted` + `rolled_back`, newest decided first.
- `CoachProposal.verdictLine(hasCut: Bool, now: Date) -> String` — works: "works · {metric} {baseline} → {value} since this edit"; no_effect: "no effect" + (hasCut ? " · a cut is proposed" : ""); too_little_data: "too little data"; empty verdict + accepted: "measuring · verdict on {decided_at + 14 days, MMM d}"; rolled_back: "rolled back".
- `CoachProposal.diffLines: [CoachDiffLine]` (`.kept/.removed/.added(String)`, line diff of before/after) and `CoachProposal.destinationLabel: String` (`session` → "Session instructions", `procedure` → "Target procedure", `chat` → "Chat instructions", `prompt_addition` → "Watchtower prompt · {promptID}", `claude_settings_allow` → "Claude Code settings · allow rules", `claude_md_user` → "~/.claude/CLAUDE.md"; + " · all workbenches" when global).
- `static func CoachHomeRow.lines(_ p: CoachProposal) -> (shown: [CoachDiffLine], truncated: Bool)` — changed lines only, at most 4.

- [ ] **Step 1: Failing tests** — decoding both fixtures (null `value`/`previous`, `workbench_id` 0); `CoachFailure.parse` (last line, junk before it, no JSON → nil); trend table: (3.0→2.1) `.better("↓ 30% · was 3.0")`, (7.6→7.4) `.same`, `n: 2` `.fewData`, `known: false` `.fewData`, `previous: nil` `.noTrend`, owner_loop 0.31→0.22 points `.better("↓ 9 pts · was 31%")`, rise `.worse`; `forPane` (other workbench out, global in); each verdict line; `diffLines`; Home 4-line rule (5 changed lines → 4 + truncated); `AgentReport` decodes `lead` and tolerates its absence.
- [ ] **Step 2:** `make test-swift FILTER='CoachDecodingTests|CoachPresentationTests|AgentReportDecodingTests'` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same — PASS. `make lint-swift`.
- [ ] **Step 5:** Commit `feat(desktop): coach models and presentation rules (#1120)`.

### Task 5: `CoachCenter` and the 1/7/30 period

**Depends on:** Task 4

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/CoachCenter.swift`
- Modify: `WatchtowerDesktop/Sources/Services/AgentAnalyticsCenter.swift` (`Period` → `day = 1, week = 7, month = 30`), `Sources/ViewModels/WorkbenchesViewModel.swift` (`weak var coach: CoachCenter?`, stored period decode 0 → `.week`), `Sources/App/AppState.swift` (create/stop next to `agentAnalyticsCenter`, line ~1860)
- Test: `WatchtowerDesktop/Tests/CoachCenterTests.swift` (fake `CLIRunnerProtocol`)

**Interfaces (Produces):**
- `@Observable final class CoachCenter` with `init(runner: any CLIRunnerProtocol, interval: Duration = .seconds(60))`
  - `private(set) var status: [Int64: SessionReportCenter.Snapshot<CoachStatus>]`, `private(set) var proposals: SessionReportCenter.Snapshot<[CoachProposal]>?`, `private(set) var running: Bool`, `private(set) var runLine: String?`, `private(set) var cardErrors: [Int64: String]`
  - `func show(workbench: Int64, period: AgentAnalyticsCenter.Period)`, `func hide(workbench: Int64)`, `func stop()`, `var isTabOnScreen: () -> Bool`
  - `func accept(_ id: Int64, editedText: String?) async`, `func decline(_ id: Int64) async`, `func rollback(_ id: Int64, force: Bool) async -> String?` (returns the `diff` on `changed_since`), `func runNow() async`
  - args: `coach status --workbench N --days D --json`, `coach proposals --status all --json`, `coach accept <id> --json [--stdin]`, `coach decline <id> --json`, `coach rollback <id> --json [--force]`, `coach run --json`
  - failures: `CLIRunnerError.nonZeroExit(_, stderr)` → `CoachFailure.parse(stderr:)`; `stale`/`state_changed` → `cardErrors[id] = "The text changed since — this proposal is closed"` + reload; `busy` → `runLine = "The coach is already running — the section updates when it finishes"`; other → its `error`; a `run` with `judge_error` → `runLine = "Verdicts could not be updated: {error}"`.
  - a status result for a period other than the current `shown[workbench]` is dropped.

- [ ] **Step 1: Failing tests** `testShowLoadsStatusAndProposals` (args exactly as above, `--days 7`), `testPeriodChangeDropsStaleStatus` (7-day reply arriving after a switch to 1 day is not stored), `testStaleAcceptClosesCardAndReloads`, `testRunNowBusyLine`, `testRunNowJudgeErrorLine`, `testRunNowDisabledWhileRunning` (second `runNow` while `running` makes no CLI call), `testEditedAcceptSendsStdin`, `testRollbackChangedSinceReturnsDiff`, `testStoredAllPeriodReadsAsWeek`.
- [ ] **Step 2:** `make test-swift FILTER=CoachCenterTests` — FAIL.
- [ ] **Step 3:** Implement, following `AgentAnalyticsCenter`'s token/in-flight pattern; the 60 s tick only while `isTabOnScreen()`.
- [ ] **Step 4:** Same — PASS; `make test-swift FILTER='AgentAnalytics'` — PASS. `make lint-swift`.
- [ ] **Step 5:** Commit `feat(desktop): CoachCenter and the 1/7/30-day period (#1120)`.

**Phase B gate (controller):** `make test-swift`, `make lint-all`.

## Phase C — Desktop screens (Tasks 6–8; 6 and 7 may run in parallel lanes, 8 after 5)

### Task 6: Coach sections on the pane

**Depends on:** Task 5

**Files:**
- Create under `WatchtowerDesktop/Sources/Views/Workbench/Analytics/`: `CoachMetricTilesView.swift`, `CoachProposalCardView.swift`, `CoachEditSheet.swift`, `CoachRollbackSheet.swift`, `CoachAcceptedLogView.swift`, `CoachRunLineView.swift`
- Modify: `AgentAnalyticsPaneView.swift` (show/hide `CoachCenter` with the analytics center; pass actions), `AgentAnalyticsOverviewView.swift` (header: dates + "against {previous dates}", `KitSegmentedPicker` 1 day / 7 days / 30 days, on-dot, Discuss in Chat; then the coach sections, then a "Statistics" `SectionHeader`)
- Test: `WatchtowerDesktop/Tests/AgentAnalyticsPaneViewTests.swift` (sections present when on, absent when off), `Tests/DesignShots/DesignShotCatalog.swift` entries `analytics-coach`, `analytics-coach-edit-sheet`, `analytics-coach-rollback-sheet`

UI per spec §3 and the mockup: tiles (4, `Fill.card`, `.monospacedDigit()`, tone from `CoachTrend` via `Tone`, caption "Review findings: per spec's first round {x} · per code review's first round {y}"); proposal cards (chips metric + destination, title, why, diff block — removed struck, added marked —, evidence links ≤ 3 + "+N": `ask:` → `vm.openAsk`, session → `actions.openSession`, `round:` → the review, `hint:` → scroll to the statistics block; **Decline** with a confirmation "Decline for good? It will not be proposed again." · **Edit…** (not for `claude_settings_allow`) · **Accept** `.kitPrimary` — the pane's one prominent action is the first card's Accept, the rest `.kitSecondary`); empty: "No proposals — the coach looks once a week"; run line "The coach looks once a week · last run {date} · next after {date+7d}" + **Run Now** (`.kitQuiet`, disabled while running, `ProgressView` + "The coach is looking at the last 28 days…"); accepted log rows with dot tone, date, title, `verdictLine`, **Roll Back** (`.kitQuiet`) for `accepted`, "Show all" after 10.

- [ ] **Step 1:** Failing view tests: `testCoachSectionsShownWhenOn`, `testCoachSectionsHiddenWhenOff`, `testAllowRuleCardHasNoEdit`.
- [ ] **Step 2:** `make test-swift FILTER=AgentAnalyticsPaneViewTests` — FAIL.
- [ ] **Step 3:** Implement the views.
- [ ] **Step 4:** Tests PASS; `make lint-swift`; `make desktop-shots DESKTOP_SHOTS=<scratch>` and look at the three shots in light and dark (soft fills, nothing clipped, one prominent button).
- [ ] **Step 5:** Commit `feat(desktop): coach sections on the Analytics pane (#1120)`.

### Task 7: Statistics redesigned

**Depends on:** Task 4

**Files:**
- Modify: `AgentAnalyticsOverviewView.swift` (statistics order per spec §4, each block `.card()`), `AgentAnalyticsContextView.swift` (stacked bar + two-column legend top 5 + "N more"; growth bar rows top 6 + fold "N more sources · {size}"), `AgentAnalyticsSkillsView.swift`, `AgentAnalyticsTroubleView.swift` (lead line, lists in `DisclosureGroup`), `AgentAnalyticsFormat.swift` (`share`, `toolName`)
- Test: `WatchtowerDesktop/Tests/Core/AgentAnalyticsFormatTests.swift` (or the existing format test file), `DesignShotCatalog` entry `analytics-statistics`

**Interfaces (Produces):**
- `AgentAnalyticsFormat.share(_ part: Int64, of total: Int64) -> String` — `"<1%"` for 0 < share < 1 %, `"0%"` only for 0, else rounded `"46%"`.
- `AgentAnalyticsFormat.toolName(_ raw: String) -> String` — `mcp__watchtower-workbench__get_ask` / `mcp__watchtower__x` → `"Watchtower: get_ask"`; `mcp__<server>__<tool>` → `"<server>: <tool>"`; anything else unchanged.
- `AgentAnalyticsFormat.fold<T>(_ rows: [T], keep: Int) -> (shown: [T], rest: [T])`.
- A fixed part palette: `AgentAnalyticsPalette.color(at index: Int) -> Color` over semantic system colours (`.blue, .purple, .cyan, .green, .orange, .gray`), stable by part order.

- [ ] **Step 1: Failing tests** `testShareUnderOnePercent` (`share(1, of: 1000)` = `"<1%"`, `share(0, of: 10)` = `"0%"`, `share(46, of: 100)` = `"46%"`), `testToolNameWatchtower`, `testToolNameOtherServer`, `testToolNamePlain`, `testGrowthFoldsAfterSix` (`fold(10 rows, keep: 6)` → 6 + 4).
- [ ] **Step 2:** `make test-swift FILTER=AgentAnalyticsFormatTests` — FAIL.
- [ ] **Step 3:** Implement; totals in one card (Cost, Sessions, Active, Cache hit, Subagents "2.2 avg · peak 20", the "priced by estimate" caption); The main thing card stays; **What else would save** and the folded Time block stay as today.
- [ ] **Step 4:** PASS; `make lint-swift`; shots light/dark looked at.
- [ ] **Step 5:** Commit `feat(desktop): Analytics statistics redesigned (#1120)`.

### Task 8: Home row and the Settings pointer

**Depends on:** Task 4, Task 5

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/HomeQueries.swift` (`newestOpenSuggestion` → `newestCoachProposal`), `Sources/WatchtowerCore/Models/Home.swift` (`HomeInstructionSuggestion` → `HomeCoachProposal { proposal: CoachProposal-equivalent fields read from `coach_proposals`, targetWorkbench: Int64 }`), `Sources/App/AppState+Home.swift` (`decideCoachProposal(id:accept:)` through the coach CLI; `openCoachInAnalytics(workbench:)`), `Sources/Views/Home/WorkbenchZoneView.swift` (row per mockup), `Sources/Views/Settings/InstructionsSettingsSection.swift` (suggestion list → one line "Suggestions now come from the coach — see a workbench's Analytics." + **Open Analytics**)
- Test: `WatchtowerDesktop/Tests/Core/HomeQueriesCoachTests.swift`, `DesignShotCatalog` entry `home-coach-row`

**Interfaces:**
- Consumes: `CoachHomeRow.lines`, `CoachProposal.destinationLabel`.
- Produces: `HomeQueries.newestCoachProposal(_ db: Database) throws -> HomeCoachProposal?` — `status = 'open'`, newest `created_at`, candidates per Global Constraints; `targetWorkbench` = the proposal's workbench, or for a global one the analytics-on workbench opened last (`WorkspaceLayout`'s last-opened workbench id when analytics is on there) else the lowest analytics-on id.

- [ ] **Step 1: Failing tests** `testNoRowWithoutAnalyticsOnWorkbench` (only a global proposal, no workbench on → nil), `testWorkbenchProposalOfOffWorkbenchSkipped`, `testGlobalProposalTargetsLowestOnWorkbench`, `testNewestOpenWins`.
- [ ] **Step 2:** `make test-swift FILTER=HomeQueriesCoachTests` — FAIL.
- [ ] **Step 3:** Implement; truncated rows show only **Open in Analytics** and **Decline**.
- [ ] **Step 4:** PASS; `make test-swift FILTER='Home'` PASS; `make lint-swift`; shot looked at.
- [ ] **Step 5:** Commit `feat(desktop): coach proposal on Home, Settings pointer (#1120)`.

## Phase D — Docs (Task 9)

### Task 9: Feature notes, guide, Learn card

**Depends on:** Tasks 1–8

**Files:**
- Modify: `docs/features/agent-coach.md` (Desktop section; v1 limits: drop "no Analytics screen, Home card", keep "no Settings → Prompts view"), `docs/features/agent-analytics.md` (pane layout, periods 1/7/30, `lead`), `docs/guide/features/agent-analytics.md`, `docs/guide/features/agent-coach.md` (+ `<!-- learn … -->` card for the coach screen, `since: next`), `CLAUDE.md` feature-note line for agent coach (Plan 2 shipped)
- Test: `go test ./docs/guide ./internal/learn`

- [ ] **Step 1:** Write the pages (WRITING.md rules, 8 KB cap).
- [ ] **Step 2:** `go test ./docs/guide ./internal/learn` — PASS.
- [ ] **Step 3:** Commit `docs: agent coach screen (#1120)`.

**Final gate (controller):** `make test`, `make test-swift`, `make lint-all`; then the PR into main with the design shots attached and a review ask with the shots.
