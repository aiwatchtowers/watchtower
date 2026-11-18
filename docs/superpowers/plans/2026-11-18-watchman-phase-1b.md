# Watchman Phase 1b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Watchman backtest measure only real owner decisions, let the twin hand back what needs the owner's hands, and make the judge consistent, then remeasure.

**Architecture:** Precedents gain two flags (`is_decision`, `parked`), set by the light-tier label call for asks and turns and by a Go hard-limit table for permission rows; a one-time relabel pass fills them for rows learned in phase 1. The backtest hides only flagged-in candidates; the twin's reply gains `handoff`, the judge rules on handoffs and follows a stricter rubric, and the backtest counts handed decisions apart.

**Tech Stack:** Go 1.26 (`internal/watchman`, `internal/db`, `internal/prompts`, `cmd`), SQLite/goose migrations, SwiftUI Settings (`WatchtowerDesktop`).

**Spec:** `docs/superpowers/specs/2026-11-16-watchman-design.md` — §4 "Hand to the owner", §5 (hard limits), §8.1 source 5, §9 and §9.1, §11, §11a, §12 item 1b, §13, Decisions D33–D41 (approved, ask #1502).

## Global Constraints

- Umbrella branch `feature/watchman`; each task's PR targets it, never `main` (umbrella rule). PR #949 stays draft.
- New migration `00197_watchman_phase1b.sql`; never edit 00194–00196 (the owner's database copy has them).
- Prompt changes go through `.claude/skills/add-ai-prompt` (both claude and codex, versions bumped with a reason): `watchman.label` v2 (light), `watchman.decide` v3 (strong), `watchman.judge` v4 (strong).
- `handoff` values: exactly `none` and `owner_only`. Judge handoff verdicts: exactly `justified` and `unjustified`.
- A justified handoff: every question of the item is **handed** (not scored). An unjustified one: **one** scored decision graded `bad` for the whole item, never bad while sure.
- Every `handoff=owner_only` goes to the judge, even when its choice matches the owner's option exactly.
- A category is measured only when at least **20** scored decisions remain of its 30 hidden; fewer → `not_measured` with the handed count kept. Strong = ≤ 5 % of scored decisions bad and none bad while sure. Verdict rule unchanged (D32).
- The relabel pass sets only `is_decision`/`parked`; it never changes a stored `category`.
- A row whose flags are unset (NULL) counts as a candidate. An unknown worktree/folder or PR base in a permission row → `parked`.
- Copy (verbatim): Settings column header `Handed`; a not-measured-for-handoffs row reads `Not measured: <n> of 30 handed to you`; journal mock `Handed to you: <what he must do>` (already in `WatchmanMockCopy`).
- JSON key `handed` (int) on category rows of `watchman backtest --json` and `watchman status --json`; Swift decodes it tolerantly (missing → 0).
- Inventory: WATCHMAN-03 and WATCHMAN-06 stay green and unchanged; `docs/inventory/watchman.md` gets a changelog line.
- Public repo hygiene: no live data (no counts, ids, texts from the owner's database) in code, tests, docs or commits. Tests never wait on wall-clock time.
- No background builds/tests. The agent never runs `watchman learn|backtest` (AGENT-07); the owner runs them.
- Guard suites to run in every Go task: `go test ./internal/watchman ./internal/db ./internal/prompts ./cmd -run 'Watchman|Prompt|LLMUSAGE|Schema|WATCHMAN'` plus `go test ./internal/llmusage ./internal/prompts` in prompt tasks; Swift tasks: `make test-swift FILTER='Watchman'` and swiftlint on touched files.

## Review Focus

1. The relabel pass dies mid-batch (quit, provider limit) → the next cycle resumes from rows still unflagged, already-flagged rows are not paid again, and `watchman backtest` refuses until it is done (`--force` overrides). Test in Task 3.
2. A label reply that has a valid category but no `decision`/`parked` for a new ask → the precedent is stored with flags NULL and counts as a candidate; it is not dropped. Test in Task 3.
3. A twin that hands off with a choice equal to the owner's fixed option → still judged (no `same` shortcut). Test in Task 4.
4. A category whose 30 hidden contain enough justified handoffs to leave fewer than 20 scored → `not_measured`, `handed` shown, and the verdict does not count it strong. Test in Task 4.
5. A permission precedent whose `permission_requests` row is gone (its session was deleted: the FK cascades) → `parked` (unknown placement), never measured. Test in Task 2.
6. After the update the Settings **Run backtest now** would hit the CLI's relabel refusal → the Desktop shows the relabelling line and disables the button instead. Test in Task 5.

---

### Task 1: Store — flags, handed count, candidate filter

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00197_watchman_phase1b.sql`
- Modify: `internal/db/schema.sql`, `internal/db/watchman.go` (`WatchmanPrecedent`, `UpsertWatchmanPrecedents`, scan), `internal/db/watchman_backtest.go` (`WatchmanBacktestCandidates`, `insertWatchmanBacktestRow`, row scan), `WatchmanBacktestRow` type
- Create: `internal/db/watchman_flags.go`
- Test: `internal/db/watchman_flags_test.go`, existing `internal/db/watchman_backtest_test.go`; regenerate goldens + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Produces:
  - `WatchmanPrecedent.IsDecision, Parked *bool` (nil = unset); `FlagsAt *time.Time` not exposed.
  - `WatchmanBacktestRow.Handed int`.
  - `type WatchmanPrecedentFlags struct { ID int64; IsDecision, Parked *bool }`
  - `func (db *DB) WatchmanUnflagged(workbenchID int64, sources []string, limit int) ([]WatchmanPrecedent, error)` — rows of those sources with `flags_at IS NULL`, newest first.
  - `func (db *DB) SetWatchmanPrecedentFlags(tx *sql.Tx, flags []WatchmanPrecedentFlags, at time.Time) error` — writes both flags (NULL stays NULL) and `flags_at`, even when both are nil (the caller writes nil flags only after the spec's one retry, Task 3).
  - `func (db *DB) WatchmanFlagsPending(workbenchID int64) (int, error)` — count of ask/turn/permission rows with `flags_at IS NULL`.

- [ ] **Step 1: Migration.** `00197_watchman_phase1b.sql` adds to `watchman_precedents`: `is_decision INTEGER` (NULL/0/1), `parked INTEGER` (NULL/0/1), `flags_at TEXT`; to `watchman_backtest_rows`: `handed INTEGER NOT NULL DEFAULT 0`. Down drops them (follow `add-migration`). Mirror into `schema.sql` with a comment citing §9.1.
- [ ] **Step 2: Failing tests** in `watchman_flags_test.go`:
  - `TestWatchmanUnflagged_OnlyUnflaggedOfSources` — 3 ask rows, 1 git row; flag one ask; `WatchmanUnflagged(wb, []string{"ask","turn"}, 10)` returns the other 2 ask rows.
  - `TestSetWatchmanPrecedentFlags_NilKeepsNullButMarksTried` — set `{IsDecision:nil, Parked:nil}`; row reads both nil, and `WatchmanFlagsPending` drops by one.
  - `TestWatchmanBacktestCandidates_SkipsNonDecisionsAndParked` — rows (decision=1,parked=0), (0,0), (1,1), (NULL,NULL): candidates are the first and the last.
  - `TestWatchmanBacktestRow_HandedRoundTrip` — insert a row with `Handed: 4`, read it back via `WatchmanBacktestByID`.
- [ ] **Step 3: Run** `go test ./internal/db -run 'WatchmanUnflagged|SetWatchmanPrecedentFlags|WatchmanBacktestCandidates|HandedRoundTrip'` → FAIL.
- [ ] **Step 4: Implement.** Candidates gain `AND COALESCE(is_decision,1) = 1 AND COALESCE(parked,0) = 0`. `UpsertWatchmanPrecedents` writes `is_decision`/`parked`/`flags_at` only when the new value is set (an upsert of an existing key without flags keeps the stored flags). Flags writer is the learning phase only (§9.1 Store).
- [ ] **Step 5: Regenerate** `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`; run the task guard suites (Global Constraints) → PASS.
- [ ] **Step 6: Commit** `feat(watchman): precedent decision/parked flags and handed count (phase 1b)`.

### Task 2: The §5 hard-limit table and permission rows

**Depends on:** Task 1

**Files:**
- Create: `internal/watchman/hardlimit.go`, `internal/watchman/hardlimit_test.go`
- Modify: `internal/db/watchman.go` (`WatchmanPermissionRow` + `wmPermissionSQL`: add the session's `folder_path` and its worktree paths, the workbench folder), `internal/watchman/source_permission.go`

**Interfaces:**
- Produces:
  - `type PermissionAsk struct { Tool, Summary, WorkbenchFolder string; Worktrees []string; PRBase func(pr int) (base string, known bool) }`
  - `type HardLimit string` with constants `LimitMainRef`, `LimitTag`, `LimitRelease`, `LimitTestFlight`, `LimitForcePush`, `LimitResetShared`, `LimitDeleteOutside`, `LimitOutward`, `LimitStandingGrant`, `LimitOutsideFolder`.
  - `func ParkedBy(r PermissionAsk) (HardLimit, bool)` — first matching row; phase 2 reuses it.
  - `func permissionFlags(r PermissionAsk) db.WatchmanPrecedentFlags` used by the source and the relabel pass (Task 3).
- [ ] **Step 1: Failing tests**, one per row × matched/not matched (spec §5 test rule), table-driven `TestParkedBy`: `git push origin main`, `git push -f origin feat`, `git tag v1 && git push --tags`, `gh release create`, `xcrun altool --upload-app`, `git reset --hard origin/feature/x`, `rm -rf /tmp/elsewhere` with worktree `/w/a` (parked) vs `rm -rf /w/a/build` (not), an MCP tool name ending `send_slack_message`, `Edit` of `.claude/settings.json`, a request whose path is outside `WorkbenchFolder` and `Worktrees`; `gh pr merge 12` with `PRBase` → `main` (parked), `feature/watchman` (not), unknown (parked). Plus `TestParkedBy_UnknownPlacementParks`: empty `WorkbenchFolder` and no worktrees → `rm -rf x` and an outside-path request are parked.
- [ ] **Step 2: Run** `go test ./internal/watchman -run 'ParkedBy'` → FAIL.
- [ ] **Step 3: Implement** `ParkedBy` as a Go table of `{HardLimit, match func(PermissionAsk) bool}` rows; `main`/`master` are the default-branch names. PR base: parse `gh pr merge <n>`; `PRBase` from `workbench_pr_states` refs `into:<base>:<branch>` when known.
- [ ] **Step 4: Permission source** sets `IsDecision=true` and `Parked` from `ParkedBy` on every new precedent (Go only, no model). Test `TestPermissionSource_SetsParkedFromTable` with a fixture row pushing to main.
- [ ] **Step 5: Run** the task guard suites → PASS. **Step 6: Commit** `feat(watchman): the §5 hard-limit table; permission precedents flagged parked (D38)`.

### Task 3: Label v2, flags at learn time, the relabel pass

**Depends on:** Task 1 (and Task 2's `permissionFlags` for permission rows in the pass — if Task 2 is not merged yet, the pass skips permission rows and Task 2's commit adds them)

**Files:**
- Modify: `internal/watchman/label.go`, `internal/watchman/learn.go`, `internal/prompts/defaults.go` (`watchman.label` v2 text, version, description), `cmd/watchman_backtest.go` (refuse while pending), `cmd/watchman.go` (status text line), `internal/daemon/watchman.go` (`phaseWatchmanBacktest`: not due while pending), `internal/watchman/status.go` (`LearningStatus.RelabelPending int` `json:"relabel_pending"` — a pinned key named in spec §13; the Desktop reads it in Task 5), `internal/watchman/testdata/status.json`, `internal/watchman/learn.go` `Estimate` (adds unflagged count to the label estimate)
- Test: `internal/watchman/label_test.go`, `internal/watchman/learn_test.go`, `cmd/watchman_test.go`

**Interfaces:**
- Consumes: Task 1's `WatchmanUnflagged`, `SetWatchmanPrecedentFlags`, `WatchmanFlagsPending`.
- Produces:
  - `type LabelItem struct { Situation, Choice string; NeedCategory bool }`
  - `type Label struct { Category string; Decision, Parked *bool }`
  - `Labeler.Label(ctx, items []LabelItem) ([]Label, error)`
- [ ] **Step 1: Prompt v2.** Reply is a JSON array of objects `{"category": "<one of eight>" | "", "decision": true|false, "parked": true|false}`, one per item, in order. `decision`: the owner's text answers a question or proposal the agent made (a choice, an approval, a rejection, an answer); false for a prod ("so?"), a status or clarifying question, a new command, or a correction of an agent that asked nothing. `parked`: the decision is a merge, push or rebase onto main, a release, tag or TestFlight upload, an outward message, or approving a behavior-inventory contract change. `category` is read only for items with `NeedCategory`. Bump to v2 with a reason (ask #1486); both providers per the skill.
- [ ] **Step 2: Failing tests:**
  - `TestLabel_ParsesFlags` — reply with two objects → `Label{Category:"scope", Decision:&true, Parked:&false}` etc.
  - `TestLabel_MissingFlagsAreNil` — `{"category":"design"}` → flags nil.
  - `TestLabel_OldArrayOfStringsIsUnlabelled` — `["scope"]` → every item `Label{}` (the reply shape is wrong, as today).
  - `TestLearn_NewAskGetsFlags` — fake labeler returns flags; the stored precedent has them and `flags_at` set.
  - `TestLearn_ReviewAskKeepsGoCategory` — a review ask (category set by Go) goes to the labeler with `NeedCategory=false`; a returned `"design"` is ignored, `parked` is stored.
  - `TestLearn_FlagsMissingRetriedOnceThenCandidate` (Review Focus 2, spec §9.1 Failures) — the labeler returns a category but no flags: the items without flags are sent once more in the same cycle; still none → stored, flags nil, `flags_at` set (a candidate, not labelled again); flags on the retry → stored.
  - `TestLearn_RelabelErrorDoesNotStopSources` — the labeler errors in the relabel pass: the sources still run, new precedents are stored, `MarkWatchmanLearned` behaves as before, the error is logged with counts only.
  - `TestStatus_TextShowsRelabelLeft` (cmd) — text output reads `relabelling earlier decisions: <n> left` while pending.
  - `TestPhaseWatchmanBacktest_SkipsWhileRelabelPending` (daemon) — pending > 0 → no child launched, no launch stamp written.
  - `TestRelabel_FlagsExistingRowsOnce` — 25 unflagged ask/turn rows: a learn cycle flags them in batches of 20; a second cycle calls the labeler 0 times; categories unchanged.
  - `TestRelabel_ResumesAfterFailure` (Review Focus 1) — the labeler errors on the second batch: the first 20 are flagged, the next cycle flags the remaining 5 only.
  - `TestRelabel_PermissionRowsByTable` — an unflagged permission precedent whose request row is gone → `parked=true`, no labeler call (Review Focus 5).
  - `TestWatchmanBacktest_RefusesWhileRelabelPending` (cmd) — pending > 0 → error naming `watchman status` and `--force`; `--force` runs.
- [ ] **Step 3: Run** `go test ./internal/watchman ./cmd -run 'Label|Learn_|Relabel|RefusesWhileRelabel'` → FAIL.
- [ ] **Step 4: Implement.** Every new ask (all kinds) and turn precedent goes to the labeler (`NeedCategory` = category empty); a returned category is applied only when `NeedCategory`. The relabel pass runs inside `Learn` after the sources, in what is left of the same budget and under the same lock; its error is logged (counts only) and never fails `Learn` or changes `learned_through` — the backtest gate is the pending count alone. The pass: `WatchmanUnflagged(wb, {"ask","turn","permission"}, labelBatch)`, ask/turn via the labeler, permission via `permissionFlags` (unknown request row → `parked=true`), written with `SetWatchmanPrecedentFlags` in one short transaction per batch (no LLM call inside it). Items whose reply lacks flags are sent once more in the same cycle (spec: retried once); still lacking → written with nil flags. A labeler error stops the pass for this cycle (rows stay unflagged). The same one-retry rule applies to new precedents. `phaseWatchmanBacktest` treats a workbench with pending rows as not due (no child, no stamp). `watchman status` text prints `relabelling earlier decisions: <n> left`. `cmd/watchman_backtest.go` refuses when `WatchmanFlagsPending > 0` unless `--force`, beside the existing `LearnedThrough` check. `Estimate` adds the pending rows to the label-call estimate.
- [ ] **Step 5: Run** the task guard suites + `go test ./internal/llmusage ./internal/prompts` → PASS. **Step 6: Commit** `feat(watchman): label v2 flags decisions and parked items; one-time relabel pass (D34, D39)`.

### Task 4: Handoff, judge v4, scoring

**Depends on:** Task 1

**Files:**
- Modify: `internal/watchman/decide.go` (`Decision.Handoff`, `decideReply`, `parseDecision`), `internal/watchman/judge.go`, `internal/watchman/backtest.go` (`item`, `category`, `rowStatus`), `internal/watchman/status.go` (`CategoryResult.Handed`), `cmd/watchman_backtest.go` (JSON row `handed`, help text, text output), `internal/watchman/testdata/status.json`, `internal/prompts/defaults.go` (decide v3, judge v4)
- Test: `internal/watchman/decide_test.go`, `internal/watchman/backtest_test.go`, `internal/watchman/status_test.go`, `cmd/watchman_backtest_test.go`, prompt registry tests

**Interfaces:**
- Consumes: Task 1's `WatchmanBacktestRow.Handed`.
- Produces:
  - `Decision.Handoff string` (`HandoffNone = "none"`, `HandoffOwnerOnly = "owner_only"`).
  - `JudgeInput.Handoff bool`; `type JudgeResult struct { Grades []string; Handoff string }` (`HandoffJustified`, `HandoffUnjustified`); `Judge.Grade(ctx, JudgeInput) (JudgeResult, *digest.Usage, error)`.
  - `const MinScored = 20`.
  - Run report: `watchman.BacktestReportPath(workspaceDir string, backtestID int64) string` → `<workspace>/watchman/backtest-<id>.jsonl`, one line per hidden item: `{"category","source","source_key","handoff","grades":[…],"handoff_verdict","why":[…],"confidence"}` (no situation or answer text). `watchman backtest --json` gains `report_path` (pinned); text output ends with the path. It is local workspace data, never written into the repo.
- [ ] **Step 1: Prompts.** `watchman.decide` v3: output gains `"handoff": "none" | "owner_only"`; `owner_only` only when the step needs the owner's own hands (issue or revoke a token, sign in, run a command on his side, press something on his device, pay); everything else is decided, questions about what the owner meant included; never state an owner-only action as done; on a plain status report answer only what was asked, add no new work. `watchman.judge` v4: when `twin.handoff` is `owner_only`, reply `{"handoff":"justified"|"unjustified","why":"…"}` only; otherwise the v3 grades object, with the §9.1 rubric verbatim (recommended/reasonable other path = acceptable unless irreversible and contradicting the situation; release version, cheap reversible CI action, work order never `bad` alone) and the D37 rule (an owner-only action stated as done, or new work answering a plain status report → `bad`), plus two worked examples of equal cases graded equally. Versions and reasons per the skill (ask #1486).
- [ ] **Step 2: Failing tests:**
  - `TestDecide_HandoffParsed` (`owner_only`), `TestDecide_HandoffMissingIsNone`, `TestDecide_HandoffUnknownIsBadReply` (`"maybe"` → `ErrBadReply`).
  - `TestJudge_HandoffVerdict` — handoff input → `JudgeResult{Handoff: "justified"}`; `TestJudge_HandoffReplyWithoutVerdictIsError`; `TestJudge_GradeHandedIsUnknown` — `{"grades":[{"grade":"handed"}]}` → error.
  - `TestBacktest_JustifiedHandoffIsHanded` — 3-question ask, justified → `Handed += 3`, `Total` unchanged.
  - `TestBacktest_UnjustifiedHandoffIsOneBad` — 3-question ask, unjustified → `Total += 1`, `Bad += 1`, `WrongHigh` unchanged even at high confidence.
  - `TestBacktest_HandoffWithExactChoiceStillJudged` (Review Focus 3) — fixed option equal to the owner's + `owner_only` → judge called once.
  - `TestBacktest_TooFewScoredIsNotMeasured` (Review Focus 4) — 30 hidden, 12 justified handoffs of single-question items → `Status == not_measured`, `Handed == 12`, `Total == 18`; `Verdict` with this row and two strong ones → `stop`.
  - `TestBacktest_StrongComputedOnScored` — 25 scored, 1 bad (4 %), 5 handed → `strong`.
  - `TestBacktest_D37ClaimGradedBad` — fake judge grades a twin rationale "old token deleted" `bad` → counted bad (pins that the judge's grade is used; the prompt pins the rule).
  - Prompt registry: `TestWatchmanPrompts_PinPhase1bRules` — decide v3 contains `owner_only` and the "never state an owner-only action as done" rule; judge v4 contains `justified`, the rubric sentence and the D37 sentence.
  - JSON pinned keys: `handed` in `TestWatchmanBacktest_JSONKeysPinned` and `testdata/status.json`; `report_path` in the backtest JSON.
  - `TestBacktest_WritesReportWithJudgeReasons` — a fake judge's `why` per grade and a handoff verdict land in the report lines, in item order; the file holds no situation text (spec §9.1: the run's report lists the judge's reasons).
- [ ] **Step 3: Run** `go test ./internal/watchman ./cmd ./internal/prompts -run 'Handoff|Judge_|Backtest_|Phase1b|JSONKeysPinned|Status'` → FAIL. (`JudgeResult` also carries `Why []string` and `HandoffWhy string` for the report.)
- [ ] **Step 4: Implement.** `item()`: when `dec.Handoff == owner_only`, skip the exact-match shortcut and call the judge with `Handoff: true`; justified → return n `handed` grades; unjustified → one `bad` (not wrong_high). `category()`: `handed` increments `row.Handed` and not `row.Total`. `rowStatus`: `Total < MinScored` → `not_measured`. Text output per category: `same / acceptable / bad (bad while sure) · handed · recommended-pick %`; help text adds the handoff rule and the 20-scored floor in plain words.
- [ ] **Step 5: Run** the task guard suites + `go test ./internal/llmusage ./internal/prompts` → PASS. **Step 6: Commit** `feat(watchman): twin hands back owner-only steps; judge v4 rubric; handed decisions counted apart (D35–D37, D40, D41)`.

### Task 5: Desktop — Handed column and the relabelling state

**Depends on:** none (the key names `handed` and `relabel_pending` are fixed above); merge after Tasks 3 and 4

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/WatchmanStatus.swift` (category `handed`, tolerant decode), `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchmanSettingsCopy.swift`, `WatchtowerDesktop/Sources/Views/Settings/WatchmanSettingsSection.swift`, the status JSON fixture behind `WatchmanStatusFixtures.results`, `docs/design/mockups/watchman/watchman-settings-results-{light,dark}.png`
- Test: the existing WatchmanStatus decoding tests and `WatchmanSettingsCopy` tests in `Tests/Core`

- [ ] **Step 1: Failing tests:** `testDecodesHanded` (key present → value), `testHandedMissingIsZero`, `testDecodesRelabelPending` (missing → 0); copy tests: `XCTAssertEqual(Copy.handedHeader, "Handed")`, `XCTAssertEqual(Copy.notMeasuredHanded(handed: 12), "Not measured: 12 of 30 handed to you")`, `XCTAssertEqual(Copy.relabelling(left: 340), "Sorting earlier decisions: 340 left · the backtest runs after it")`; a view-model test: `relabel_pending > 0` → **Run backtest now** disabled and the relabelling line shown (the Desktop never starts a run the CLI would refuse).
- [ ] **Step 2: Run** `make test-swift FILTER='Watchman'` → FAIL.
- [ ] **Step 3: Implement** the column after the bad counts; a `not_measured` row with `handed > 0` shows `notMeasuredHanded`; while `relabel_pending > 0` the workbench row shows `relabelling(left:)` with a small progress indicator and **Run backtest now** is disabled; colors only through `Tone`; add `handed` values and one such row to the results fixture, and a new fixture + DesignShot `watchman-settings-relabelling` (spec §11a row).
- [ ] **Step 4: Run** `make test-swift FILTER='Watchman'` → PASS; swiftlint the touched files; `make desktop-shots DESKTOP_SHOTS=<scratch>` and copy only `watchman-settings-results-*` and `watchman-settings-relabelling-*` into `docs/design/mockups/watchman/`; look at the shot.
- [ ] **Step 5: Commit** `feat(watchman): Settings shows handed decisions per category`.

### Task 6: Docs

**Depends on:** Tasks 3 and 4

**Files:** `docs/features/watchman.md`, `docs/features/README.md` (summary line), `docs/guide/features/watchman.md` (8 KB cap), `docs/inventory/watchman.md` (changelog line only)

- [ ] **Step 1:** Describe what is measured (decisions only, parked excluded), the relabel pass and the backtest refusal while it runs, the handoff rule, the handed count and the 20-scored floor, the judge rubric; in the guide, the owner-facing part only (what "Handed" means, why a category can be not measured). No live numbers.
- [ ] **Step 2: Run** `go test ./docs/guide` → PASS. **Step 3: Commit** `docs(watchman): phase 1b`.

### After the tasks (controller)

- Phase gate: `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`; final whole-branch review (Claude + codex) on the umbrella diff of phase 1b.
- Owner run (ask, not a check): rebuild `wt-dev` from `feature/watchman`; the owner runs `watchman learn --workbench 1 --start` (relabel pass) until `relabel_pending` is 0, then `watchman backtest --workbench 1 --json` on the copy workspace `watchman-backtest-copy`. Report per category: scored, handed, bad, bad while sure, status, verdict, cost.
- Then: delete the copy workspace, the spike worktree `../watchman-spike` and branch `spike/watchman-context`; PR #949 by the verdict.
