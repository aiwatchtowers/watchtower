# Session Progress Scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The session row's `done/total` counts only the session's own work: a bound session counts its target's subtree; an unbound one drops leaves another session took over by a status change.

**Architecture:** A `status_at` stamp on `terminal_session_targets` (written by status-changing / creating writes and by binding) decides per-leaf ownership; `internal/sessionreport` narrows `progress` with an owners map. Binding re-writes `terminal_sessions.target_id` through one Go db function used by a new MCP tool and a new CLI verb; the Desktop row menu calls the CLI.

**Tech Stack:** Go (goose SQL migration, `internal/db`, `internal/tools`, `internal/sessionreport`, cobra `cmd`), SwiftUI (WatchtowerCore presentation + row context menu).

**Spec:** `docs/superpowers/specs/2026-10-31-session-progress-scope-design.md` (owner approved, ask #859). Read it first; it carries the rules and the Decisions table.

## Global Constraints

- Migration file: next free number (`00167_session_target_status_at.sql` at writing time); Up = `ADD COLUMN status_at TEXT` + `UPDATE terminal_session_targets SET status_at = last_at;`; Down drops the column.
- Mirror in `internal/db/schema.sql`; regenerate with `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- Agent kinds that own: `terminal_sessions.kind IN ('claude','codex')`, same workbench (`project_id`).
- Ties on `status_at` → higher session id.
- Tool name `set_session_target`; refusal text with no session: `set_session_target needs a Watchtower terminal session`.
- CLI: `watchtower workbench session-target --session N (--target M | --clear) [--json]`, refused under an agent marker (`refuseUnderAgent`, `cmd/actions.go`).
- UI copy (exact): menu `Session Target`, top item `None — Count What It Touched`, failure `Couldn't change the session target: <error>`.
- Skill pack marker bumps `v18` → `v19` (`internal/devpack/workbenchskill/watchtower-workbench/SKILL.md`, `internal/devpack/workbench_test.go`).
- Write transactions start `BEGIN IMMEDIATE` (db default); collect board ids before opening the tx.
- New PROJ-14 guard tests are named `TestProj14_…`; no existing guard relaxed.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, swiftlint for Swift); full gate once at the end.

## Review Focus

1. A session with **no links at all** and no target → `0/0`, the row unchanged ("No tasks yet"); pin in Task 3.
2. A leaf linked by S only through a **comment after the upgrade** (status_at NULL) while nobody else stamped it → still counts for S (unowned leaf); pin in Task 3.
3. **Dismissed** leaves never count, owned or not (existing `counted()`); pin in Task 3 with an owned dismissed leaf.
4. Binding to the **session's current target again** is idempotent (re-stamps, no error); pin in Task 1.
5. Binding a target of **another workbench** reads as "not in this workbench", never confirming the id exists; pin in Task 4.

---

### Task 1: Schema + db layer

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00167_session_target_status_at.sql`
- Modify: `internal/db/schema.sql`, `internal/db/session_report.go`, golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)
- Test: `internal/db/session_report_test.go`

**Interfaces:**
- Produces:
  - `func (db *DB) LinkSessionTargetStatus(sessionID, targetID int64) error` — upsert, sets `last_at = status_at = now` (first_at kept).
  - `func (db *DB) SessionLeafOwners(workbenchID int64) (map[int64]int64, error)` — target id → owning session id over all links with non-NULL `status_at` of that workbench's claude/codex sessions; latest `status_at`, tie → higher session id.
  - `func (db *DB) SetSessionTarget(sessionID int64, targetID sql.NullInt64, stampLeaves []int64) error` — one write tx: `UPDATE terminal_sessions SET target_id = ?`; when valid, upsert link of target with status stamp and `status_at = now` link for every id in `stampLeaves`. Any error rolls back all.

- [ ] **Step 1:** Write failing tests in `session_report_test.go`:
  - `TestSessionLeafOwners_LatestStatusWinsTieHigherID` — S1 status_at t1, S2 t2>t1 → S2; equal stamps S3(id 3) vs S4(id 4) → 4.
  - `TestSessionLeafOwners_NullStatusAtGivesNothing` — only a NULL row → key absent.
  - `TestSessionLeafOwners_IgnoresShellAndOtherWorkbench`.
  - `TestMigration00167_BackfillsStatusAtFromLastAt` — row inserted before migrate gets `status_at == last_at` (follow an existing migration test's up-to-N pattern in `internal/db`).
  - `TestSetSessionTarget_OneTransaction` — force a failure on a stamp (e.g. a leaf id with no `targets` row → FK error) → `target_id` unchanged and no link rows added.
  - `TestSetSessionTarget_Idempotent` — bind same target twice → no error, stamps moved.
  - `TestSetSessionTarget_ClearKeepsLinks` — `NullInt64{}` → `target_id` NULL, links remain.
- [ ] **Step 2:** `go test ./internal/db -run 'SessionLeafOwners|Migration00167|SetSessionTarget'` → FAIL.
- [ ] **Step 3:** Migration, `schema.sql` mirror, the three functions. Owners query: window `ROW_NUMBER() OVER (PARTITION BY l.target_id ORDER BY l.status_at DESC, l.session_id DESC)`.
- [ ] **Step 4:** Regenerate golden + Swift schema (`-update`), then `go test ./internal/db` → PASS.
- [ ] **Step 5:** Commit `feat(db): session target status stamps and binding (board #1352)`.

### Task 2: Status-changing writes stamp

**Depends on:** Task 1

**Files:**
- Modify: `internal/tools/workbench_finish.go` (`linkSession`), `internal/tools/workbench_targets.go` (`applyTargetUpdate`, `NewUpdateTarget`, `NewCreateTargets`), `internal/tools/workbench_docs.go:277` (comment call keeps plain link)
- Test: `internal/tools/workbench_targets_test.go` (or the existing link test file)

**Interfaces:**
- Consumes: `LinkSessionTargetStatus`.
- Produces: `linkSession(d, b, sessionEnv, out, stamp bool, ids ...int64)`; `applyTargetUpdate` additionally returns `statusWritten bool` (true on the plain status path when `a.Status != t.Status`, and on a column move that changed the status).

- [ ] **Step 1:** Failing tests: `TestProj14_UpdateTargetStatusChangeStamps` (status change → `status_at` set), `TestProj14_UpdateTargetWithoutStatusDoesNotStamp` (title only → NULL on a fresh link), `TestProj14_ColumnMoveStampsOnlyOnStatusChange`, `TestProj14_CreateTargetsStamps`, `TestProj14_CommentAndAskDoNotStamp`.
- [ ] **Step 2:** `go test ./internal/tools -run 'TestProj14_.*Stamp'` → FAIL.
- [ ] **Step 3:** Implement; `ask_owner`, `add_comment`, `finish_session` pass `stamp=false`.
- [ ] **Step 4:** `go test ./internal/tools` → PASS.
- [ ] **Step 5:** Commit `feat(tools): status changes stamp the session link (board #1352)`.

### Task 3: Report progress scope

**Depends on:** Task 1

**Files:**
- Modify: `internal/sessionreport/scope.go`, `internal/sessionreport/summary.go`
- Test: `internal/sessionreport/report_test.go` (+ `testdata/scope.sql` if fixtures fit)

**Interfaces:**
- Consumes: `SessionLeafOwners`.
- Produces: `newScope(b *board, sessionID int64, sessionTarget sql.NullInt64, linked []int64, owners map[int64]int64) scope`; `scope.progress()` uses the progress set; `scope.targets()` / lists keep the wide set (today's).

Rules (spec "Rule"): target valid **and on the board** → progress = its subtree's counted leaves, no exclusion. Else → today's wide set minus leaves with `owners[leaf]` present and `!= sessionID`.

- [ ] **Step 1:** Failing tests:
  - `TestProj14_ProgressDropsLeavesOwnedByAnotherSession` — the owner's case: S1 linked group A (35 leaves) + group B; S2 stamps A's leaves → S1 progress = B only; S1 `targets()` still lists A.
  - `TestProj14_GroupMoveTakesNoLeaves` — S2 stamps only group A → S1 keeps A's leaves.
  - `TestProj14_BoundSessionCountsOnlyItsSubtree` — bound to B, linked A → progress = B; no exclusion inside B even if S2 owns a B leaf.
  - `TestProj14_BoundTargetOffBoardFallsBackToRule2` — bound target archived → rule 2.
  - `TestProj14_OwnerBoardMoveKeepsOwnership` (spec test 6) — S1 stamps a leaf, then `UpdateTargetStatus(..., db.ActorOwner)` → owners map unchanged, S1 still counts it.
  - Review Focus 1–3: `TestProgress_NoLinksNoTargetIsZero`, `TestProgress_UnownedCommentLeafStillCounts`, `TestProgress_OwnedDismissedLeafNeverCounts`.
- [ ] **Step 2:** `go test ./internal/sessionreport -run 'Proj14_|Progress_'` → FAIL.
- [ ] **Step 3:** Implement; `Summaries` loads owners once per workbench; `Build` (single session, `scope.go:217`) loads them too.
- [ ] **Step 4:** `go test ./internal/sessionreport` → PASS.
- [ ] **Step 5:** Commit `feat(sessionreport): progress counts the session's own leaves (board #1352)`.

### Task 4: `set_session_target` MCP tool + pack + contracts

**Depends on:** Task 1

**Files:**
- Create: `internal/tools/workbench_session_target.go`, `internal/tools/workbench_session_target_test.go`
- Modify: `internal/tools/workbenches.go` (register after `NewFinishSession`), `internal/mcp/workbench_test.go:161` (rename in place to `…ListsTwentyTools…`, count only), `internal/tools/workbench_names_test.go` comment count, `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (tool line + "when the session's work moves to a new group, call `set_session_target` with it"; marker v19), `internal/devpack/workbench_test.go` (v19), `docs/inventory/workbench.md` PROJ-14 (amendment paragraph, ask #859), `docs/inventory/dev-surface.md` DEV-06 (twenty tools, changelog line), `docs/features/workbench.md` (one paragraph)

**Interfaces:**
- Consumes: `SetSessionTarget`, `terminalSessionOf`, `targetInWorkbench`, the board (`d.GetWorkbenchBoard`) to check on-board + collect subtree leaves.
- Produces: `func NewSetSessionTarget(sessionEnv func() string) *Tool`; args `{target_id int64 (0 clears), reason string}`; result `{"session_id", "target_id" (0 when cleared), "stamped": N}`. Also an exported helper used by the CLI: `func BindSessionTarget(d *db.DB, workbenchID, sessionID, targetID int64) (stamped int, err error)`:
  - the session row must be of `workbenchID` and of kind `claude`/`codex`; a `shell` row or another workbench's row → error `session N is not an agent session of this workbench` (no write);
  - `targetID == 0` → no target checks, `SetSessionTarget(sessionID, sql.NullInt64{}, nil)`, `stamped = 0`;
  - `targetID > 0` → in workbench (`targetInWorkbench`), on the board, not `dismissed`; collects the subtree's leaves; `SetSessionTarget(sessionID, valid(targetID), leaves)`.

- [ ] **Step 1:** Failing tests: `TestProj14_SetSessionTargetNeedsSession` (refused, no row, no audit row), `TestProj14_SetSessionTargetRefusesOtherWorkbench` (Review Focus 5: error wraps `db.ErrNotInWorkbench`), `…RefusesArchived`, `…RefusesDismissed`, `…AllowsDone`, `…ClearKeepsLinks` (0 skips target checks), `…RefusesShellSession`, `…StampsSubtreeLeaves` (another unbound session loses them in `SessionLeafOwners`), `…AuditRow` (applied), `…FailedWriteAuditsFailed` (make `SetSessionTarget` fail at apply — e.g. delete a subtree leaf between `Scope` and `Execute`, or a db seam — → tool error, registry audit row `failed`, `target_id` unchanged).
- [ ] **Step 2:** `go test ./internal/tools -run SetSessionTarget` → FAIL.
- [ ] **Step 3:** Implement, register, bump counts/pack, write the docs paragraphs.
- [ ] **Step 4:** `go test ./internal/tools ./internal/mcp ./internal/devpack` → PASS.
- [ ] **Step 5:** Commit `feat(tools): set_session_target re-points a session (board #1352)`.

### Task 5: CLI `workbench session-target`

**Depends on:** Task 4

**Files:**
- Create: `cmd/workbench_session_target.go`, `cmd/workbench_session_target_test.go`
- Modify: `cmd/actions.go` (`refuseUnderAgent` doc list)

**Interfaces:**
- Consumes: `tools.BindSessionTarget`.
- Produces: the command; `--json` prints one line `{"session_id":N,"target_id":M,"stamped":K}` (pinned keys); errors → non-zero exit, message on stderr.

- [ ] **Step 1:** Failing tests: `TestWorkbenchSessionTarget_RefusedUnderAgent`, `…SetsAndPrintsJSON`, `…ClearSetsNull`, `…RequiresExactlyOneOfTargetClear`, `…UnknownSession`, `…RefusesShellSession` (the helper's error, non-zero exit).
- [ ] **Step 2:** `go test ./cmd -run WorkbenchSessionTarget` → FAIL.
- [ ] **Step 3:** Implement (workbench id from the session row).
- [ ] **Step 4:** `go test ./cmd -run WorkbenchSessionTarget` → PASS.
- [ ] **Step 5:** Commit `feat(cli): workbench session-target (board #1352)`.

### Task 6: Desktop "Session Target ▸" submenu

**Depends on:** Task 5 (CLI contract only; may run in parallel against the pinned JSON)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionTargetMenu.swift`, `WatchtowerDesktop/Tests/Core/SessionTargetMenuTests.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionsPanel.swift` (`SessionRowActions.setTarget: ((TerminalSession, Int64?) -> Void)?`), `WatchtowerDesktop/Sources/Views/Workbench/TerminalSessionRow.swift` (submenu between Rename… and Clean Up…, shown only where `setTarget` is non-nil — the panel passes it for workbench `claude`/`codex` rows, matching the Go helper's refusal of shell rows), `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel.swift` (new `func setSessionTarget(_ session: TerminalSession, targetID: Int64?) async` runs the CLI through the existing CLIRunner, then the existing report refresh; on failure sets a new `var sessionTargetError: String?` = `SessionTargetMenu.failureLine(stderr)`), `WorkbenchSessionsPanel.swift` (an `.alert` bound to `sessionTargetError`, the same shape as `deleteError`'s alert in `WorkbenchPageView.swift:87`), `docs/guide/` workbench sessions page (one short paragraph, `go test ./docs/guide`)

**Interfaces:**
- Consumes: CLI from Task 5; `WorkbenchBoardOutline.rows`/nodes for the board tree.
- Produces: `enum SessionTargetMenu { static let title = "Session Target"; static let noneTitle = "None — Count What It Touched"; static func failureLine(_ error: String) -> String; static func items(roots: [WorkbenchBoardNode], current: Int64?) -> [Item] }` where `Item` = `.none(checked: Bool)` | `.target(id: Int64, title: String, checked: Bool, children: [Item])`; archived and dismissed targets left out; a group's first child item is the group itself (as in **Move to…**).

- [ ] **Step 1:** Failing tests in `SessionTargetMenuTests`: strings exact; `items` checks `none` when `current == nil`; checks the current target; omits dismissed/archived; group carries itself first. Plus a view-model test class `WorkbenchesViewModelSessionTargetTests` (next to the existing `WorkbenchesViewModel` tests, with their stub CLI runner): a non-zero exit sets `sessionTargetError == SessionTargetMenu.failureLine(<stderr>)`; success clears it.
- [ ] **Step 2:** `make test-swift FILTER='SessionTargetMenuTests|WorkbenchesViewModelSessionTargetTests'` → FAIL.
- [ ] **Step 3:** Implement model + menu wiring.
- [ ] **Step 4:** `make test-swift FILTER='SessionTargetMenuTests|WorkbenchesViewModelSessionTargetTests'` → PASS; `make lint-swift` clean.
- [ ] **Step 5:** Commit `feat(desktop): Session Target submenu on the session row (board #1352)`.

### Final: gate + review

- [ ] `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`.
- [ ] Manual check (owner ask, kind check): upgraded app — the Go-hub session row shows the phase number, not 42/72; submenu binds and clears; finish gate follows the bound target.
