# Workbench session report — plan (2026-10-03)

**Spec:** `docs/superpowers/specs/2026-10-03-workbench-session-report-design.md` (Parts referenced as §N).
**Board:** feature target id in the board comment on it; one sub-target per task below.
**Branch:** `feature/workbench-session-report`, cut from `feature/workbench-owner-asks` (PR #147). Rebase it onto main once
#147 merges, renumbering the migration if main took `00101`.
**Before starting:** the owner approves the §8 inventory amendments (PROJ-11, PROJ-13, new PROJ-14). Until then no task
changes a PROJ guard's assertions. Task 11 also waits for the owner's toolbar pick (§1 decision 1).

Every task runs only its inner loop (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`). The full
gate is Task 13. The reviewer checklist is `docs/review/review-rules.md`; the implementer self-reviews against it before
hand-back. Go tasks may run in parallel lanes where `Depends on` allows. Swift tasks run one at a time in one worktree.

---

## Phase 1 — Go

### Task 1 — Migration 00101 and the db layer
- **Files:**
  - `internal/db/migrations/00101_workbench_session_report.sql`, `internal/db/schema.sql`
  - `internal/db/terminal_sessions.go`, new `internal/db/session_report.go`
  - tests, the schema golden, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- **Produces:**
  - `db.LinkSessionTarget(sessionID, targetID int64) error` (an upsert; `first_at` is kept)
  - `db.FinishTerminalSession(sessionID int64, summary string, at time.Time) error`
  - `db.SessionLinkedTargets(sessionID) ([]int64, error)`
  - `db.UpsertPRState(PRState) error`, `db.PRStates(projectID) (map[string]PRState, error)`
  - `SetTerminalAgentState` clears `finished_at` when it writes `working` (§4)
- **Depends on:** none.
- **Tests:**
  - Up/Down round trip: rows of other tables survive.
  - `TestAllTablesExist` lists both new tables.
  - Linking twice keeps `first_at` and moves `last_at`.
  - Cascades: deleting a session drops its links; deleting a target drops its links; deleting a workbench drops its links
    and its PR cache (PROJ-02 leftover test).
  - `TestProj11_WorkingClearsFinished`: `working` clears `finished_at` and keeps `finish_summary`; `waiting` and
    `approval` keep `finished_at`.
  - An older `working` event, refused by the existing time guard, does not clear `finished_at` either.
  - The PR state CHECK rejects an unknown state.

### Task 2 — Tools: `finish_session` and session links
- **Files:** `internal/tools/workbench_targets.go`, `workbench_asks.go`, new `internal/tools/workbench_finish.go`, the
  registry wiring in `buildToolRegistry`, the legacy name tables, tests.
- **Produces:**
  - The `finish_session` tool (§4: params, refusals, result).
  - A `linkSession(binding, targetIDs...)` helper, called after a successful `update_target`, `create_targets`,
    `add_comment` (a reply links its root's target), `ask_owner` and `finish_session`. A failure adds
    `session_link_warning` to the result.
- **Depends on:** Task 1.
- **Consumes:** `terminalSessionOf`.
- **Tests:**
  - Each of the five tools links exactly the §3 targets.
  - A read tool (`get_target`, `workbench_board`, `list_asks`) links nothing.
  - `TestProj14_OnlyOwnSessionWritesLink`: no variable, an unknown id or another workbench's session → no row.
  - `TestProj14_FinishNeedsATerminalSession`.
  - Summary bounds: 600/601 runes, 4/5 lines, empty after trim.
  - `target_id` from another workbench is refused.
  - A repeat call overwrites the summary.
  - `open_asks` counts only this session's open asks.
  - A failed link write leaves the tool's own write in place and returns the warning (injected failing DB).
  - The legacy (`--project`) binding links the same.

### Task 3 — `internal/sessionreport`: Build
- **Files:** `internal/sessionreport/{report.go,scope.go,phases.go,summary.go}`, `testdata/`, tests.
- **Produces:**
  - `Build(ctx, d, projectID, sessionID, Options) (Report, error)`
  - `Summaries(ctx, d, projectID) ([]Summary, error)`
  - The §6 JSON shape, including the `pr_line` texts.
- **Depends on:** Task 1.
- **Tests:**
  - **A fixture board shaped like #314** (a session target with a review leaf, phases of 7, 5 and 2 leaves, one blocked):
    `progress` 14/15; `phases` in board order with done/total and time spans from history rows; `now` holds the blocked
    leaf with its `since`; `next` is empty.
  - **A fixture shaped like #257** (two `in_progress` leaves, a nested parent #261 with three children, two todo leaves):
    `now` and `next` (first 3, board order); the nested parent counts all its leaves.
  - **Scope:** a linked target outside the session's own subtree is included; a dismissed leaf counts in neither number.
  - **Asks:** `on_you` holds only this session's `open` asks — not answered ones, not another session's, not
    session-less ones.
  - **PRs:** two targets with the same PR give one `prs` entry listing both targets; a branch whose cached PR is known
    merges into that entry; a ref never cached reads `unknown`.
  - **Summary:** `pr_line` reads "PR #147 open", "2 PRs merged", "no PR yet" (a branch with done work and no PR) or
    empty.
  - `TestProj14_ReportNeverWritesTheBoard`: run `Build` and `Summaries` on a DB whose triggers fail any write to targets,
    comments or history.

### Task 4 — `internal/sessionreport`: Refresh (PR state)
- **Files:** `internal/sessionreport/refresh.go`, small exported readers in `internal/workbenchcheck` (git merge detection,
  the gh PR state) if they are not exported yet. These are moves only; behaviour stays the same.
- **Produces:** `Refresh(ctx, d, projectID, refs, Options{Network bool, Budget, Now}) RefreshResult{Note string}`.
- **Depends on:** Task 1.
- **Consumes:** `workbenchcheck` readers, `gitbin`.
- **Tests:**
  - With a fake gh stub on PATH (reaped in `t.Cleanup`, process group killed): open, merged with `mergedAt`, closed, and
    a branch found by `pr list --head`.
  - gh missing → branch-only state plus a `Note`.
  - `Network: false` → no gh call.
  - The 10 s budget is hit → the unchecked refs keep their cached rows and the note says so.
  - Freshness: a 30 s old open ref is not re-checked; a 61 s old one is; a merged ref is re-checked only after 10 min.
  - A plain folder (no `.git`) spawns no git.
  - The existing `workbenchcheck` tests stay green, unchanged.

### Task 5 — CLI `workbench session-report`
- **Files:** `cmd/workbench_session_report.go`, tests.
- **Produces:** `watchtower workbench session-report --workbench N (--session S | --summary) [--json] [--no-network]`
  (§6), and the legacy spelling via the existing alias.
- **Depends on:** Tasks 3 and 4.
- **Tests:**
  - Exactly one of `--session`/`--summary` is required.
  - An unknown workbench or session exits non-zero; a gh or git failure exits 0 with `pr_note`.
  - `--summary` never runs gh (stub records calls).
  - The JSON golden for the #314 fixture.
  - The text form prints the sections in §1 order.
  - `--project` works and names the old command in its help.

### Task 6 — Ask guard prompt v2 and skill pack v3
- **Files:** `internal/devpack/workbench_settings.go` (`askGuardPrompt`), the v1 prompt kept as an upgrade fixture,
  `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (pack v3, "Finishing a session"), tests.
- **Produces:** the §5 text and the upgrade rule.
- **Depends on:** none. It touches no db code.
- **Tests:**
  - The golden v2 text with the marker substituted.
  - `TestProj13_V1PromptIsUpgradedEditedIsKept`: v1 byte-exact → replaced with v2; an edited v1 → kept, reported
    `drifted`; another workbench's marker → untouched.
  - A resync run twice is idempotent.
  - The skill digest and marker are updated per DEV-04, and the skill text names `finish_session` and "session
    finished".

---

## Phase 2 — Desktop (one lane, in order)

### Task 7 — Core: report model, presentation, finished state
- **Files:**
  - `WatchtowerCore/Models/SessionReport.swift`
  - `WatchtowerCore/Services/SessionReportPresentation.swift`
  - `SessionAgentStatus` (`effective`), `SessionSwitcherPresentation.swift` (`.finished`)
  - `TerminalSession` model + `TerminalSessionQueries` (read `finished_at`/`finish_summary`)
  - tests in `Tests/Core`
- **Produces:**
  - `SessionReport`/`SessionReportSummary` decoding.
  - The presentation strings.
  - The §4 effective-state order.
- **Depends on:** Task 5 (JSON shape).
- **Tests:**
  - Decode the Task 5 golden; extra/missing keys decode with defaults.
  - `testProj11_FinishedOutranksWaitingButNotApprovalOrNewerWork`: every pair of (live, agent_state, agent_state_at vs
    finished_at) in the §4 order, including not live + finished → finished.
  - Caption texts: "#314 · 14/15 · PR #147 open", no ticket, no PR, stale.
  - Phase time spans: same day, across midnight, still running ("07:47 – …").
  - "Previous summary" shows when `finished_at` is NULL and a summary exists.

### Task 8 — `SessionReportCenter`
- **Files:** `WatchtowerDesktop/Sources/Services/SessionReportCenter.swift`, AppState wiring, tests.
- **Produces:** `summaries[workbenchID]`, `report[sessionID]`, `stale` flags, `refresh(workbench:)`, `show(session:)`.
- **Depends on:** Task 7.
- **Tests (with a fake CLI runner):**
  - Summary polling runs only while the Workbench tab is visible, every 15 s, and on activation.
  - The full report runs on show, every 30 s while shown, and on the session's agent-state change.
  - One in flight plus one queued rerun per workbench.
  - A failure keeps the last value and marks it stale.
  - A session switch cancels nothing in flight and drops the stale result for the old session.
  - The center survives navigation (state lives on AppState).

### Task 9 — Sessions panel: second line and the blue dot
- **Files:** the sessions panel row, `SessionLiveDot`, the switcher button and popover, the Go to… palette rows, tests.
- **Depends on:** Task 8.
- **Tests:**
  - The row caption comes from the summary; a stale summary shows the last caption marked stale.
  - A standalone terminal has no second line.
  - The blue dot appears at all four dot sites for a finished session, live or not.
  - The `finished` notice: one per transition, under PROJ-11's conditions, body = the first summary line, same
    identifier.

### Task 10 — Session view
- **Files:**
  - `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionReportView.swift` (+ section subviews)
  - `WorkspaceLayout` (`.sessionReport(Int64)`, `WorkspaceView.report`)
  - `WorkbenchesViewModel.Placement` wiring, tests
- **Depends on:** Tasks 8 and 9.
- **Tests:**
  - Layout decode: an old saved layout still decodes; an unknown case → `.default`.
  - Placement: the view follows the selected session; no session → "Pick a session".
  - **Open** on an ask opens the #314 drawer on that ask.
  - A PR row with a URL opens it; one without a URL is not a link.
  - A target id opens the Board on it.
  - Empty states: no asks, nothing now, no PRs, no summary.
  - A stale report shows its error line.
  - Snapshot-free view-model tests only (house rule), with the presentation covered in Task 7.

### Task 11 — Header toolbar and split (waits for the owner's pick)
- **Files:** `WorkbenchPageView` header, `WorkbenchesViewModel.showView`/`hideView`, `WorkspaceLayout`, tests.
- **Depends on:** Task 10, and the owner's toolbar choice (§1 decision 1). Do not start before the pick is recorded on
  this task's board target.
- **Produces:** the chosen layout of Terminal ▾ / Board / Session / Files / split / ⋯.
- **Tests:**
  - Every view button toggles its view as today, including Session.
  - A split keeps the session pairing (terminal + its report).
  - The ⋯ menu items keep their actions.
  - Plus the cases the chosen variant adds, written into the target before the work starts.

---

## Phase 3 — Docs and gate

### Task 12 — Documentation and inventory
- **Files:**
  - `docs/features/workbench.md`: a session report bullet and the v1 limits from §9
  - `docs/app-guide.md`: the Session view, the blue dot, `finish_session`
  - `docs/inventory/workbench.md`: the PROJ-11 and PROJ-13 amendments and PROJ-14 exactly as §8, plus the changelog
  - `docs/inventory/dev-surface.md`: DEV-06 lists `finish_session`
- **Depends on:** Tasks 1–10 (Task 11 when done).
- **Tests:** each guard named in §8 exists under that name (grep in the review).

### Task 13 — Gate and manual check
- **Depends on:** all tasks.
- **Gate:** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` (targeted `-race -run` for the new cmd).
- **Manual check** on `make app-dev`:
  1. A fresh session started with Work on it on a small target: the agent links targets, opens a PR and calls
     `finish_session`. The dot turns blue, and the report shows the summary, X/Y and the PR.
  2. Send a new prompt to the blue session → green, with "Previous summary" shown.
  3. An agent that ends with "all done, PR opened" without the tool gets the reminder once, then calls it.
  4. Without gh on PATH: branch state shows and `pr_note` explains.
  5. The rows of five sessions show their captions within 15 s of opening the tab.
  6. The reports of #314 and #257 match the §1 done criteria.
