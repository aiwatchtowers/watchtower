# Workbench board columns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-workbench board columns inside the fixed status categories — defined by the owner on the Desktop, moved by the agent (`update_target column`) and the owner (drag), with `in_review`/`blocked` hideable and the column name on the phone.

**Architecture:** A `workbench_board_columns` table plus `targets.board_column_id` and `projects.board_hidden_statuses`; SQLite triggers keep a target's column inside its status (one rule for Go and GRDB, the PROJ-05 pattern). One definition writer (`watchtower workbench columns`), called by the Desktop. Agent surfaces read the definition into the brief, `workbench_info`, `workbench_board`, `get_target`; with nothing defined every output is byte-identical to today.

**Tech Stack:** Go 1.26 + goose migrations + modernc SQLite; SwiftUI/GRDB (WatchtowerCore); WatchtowerKit; iOS app.

**Spec:** `docs/superpowers/specs/2026-10-16-workbench-board-columns-design.md` (approved, ask #209). Read it with this plan.

## Global Constraints

- Hideable statuses: only `in_review` and `blocked`.
- Limits: ≤ 6 columns per status, ≤ 20 per workbench; title 1–40 chars (trimmed), unique per workbench case-insensitively, never equal (case-insensitive) to another status's standard label; description ≤ 500 chars.
- Standard labels (implicit columns; reuse the existing Desktop labels — `WorkbenchBoardCard` label for each status — and the same strings in Go): `todo` "To Do", `in_progress` "In Progress", `in_review` "In Review", `blocked` "Blocked", `done` "Done", `dismissed` "Dismissed". Task 1 pins them in Go as `db.BoardStatusLabels`; check the Swift labels match and use those if they differ.
- A column's `status` never changes after creation (`--set` refuses it).
- Column moves never write `target_status_history` (PROJ-06 unchanged).
- With no columns and nothing hidden: brief, `workbench_board`, `get_target`, `workbench_info`, the Desktop Kanban and the phone are unchanged.
- Migration number: next free at merge (`00125`, after main's `00124_review_checks`).
- Inner loop only per task (CLAUDE.md "Agent-driven runs"): `go test ./internal/<pkg>` / `./cmd -run …`, `make test-swift FILTER=…`, `make kit-test FILTER=…`, `make lint-diff`, and `make lint-swift` for Swift tasks (lint-diff is Go-only).

## Review Focus

1. **A status change on a card in a custom column** (agent `status: done` on a card in "Code") must land it in Done's first column, not abort — Task 1 `TestProj19_StatusChangeClearsForeignColumn`.
2. **Deleting a column that holds cards** must leave the cards in the status's first column, never orphaned or invisible — Task 1 `TestProj19_DeletedColumnFallsBack` + Task 4 `testCardWithNullColumnGoesToFirstColumn`.
3. **Hiding a status that still has cards**: the cards stay visible under the standard label — Task 4 `testHiddenStatusWithCardsStillShows`.
4. **An agent naming a column by the label it saw in the brief, any case** ("done", "Spec") resolves — Task 3 `TestUpdateTarget_ColumnResolvesByTitleCaseInsensitiveAndImplicitLabel`.
5. **Snoozed card with a column**: snooze clears it, unsnooze lands in the first column — Task 1 `TestProj19_SnoozeClearsColumn`.

---

### Task 1: Schema, triggers and Go accessors

Depends on: none.

**Files:**
- Create: `internal/db/migrations/00125_workbench_board_columns.sql`, `internal/db/board_columns.go`, `internal/db/proj19_board_columns_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/workbench_board.go` (`BoardNode.Column`), `internal/db/targets.go` (scan stays unchanged unless needed — `db.Target` gets no new JSON-visible field), the `TestAllTablesExist` list, snapshot + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`)

**Interfaces — Produces:**
```go
type BoardColumn struct {
    ID          int64  `json:"id,omitempty"`
    Status      string `json:"status"`
    Title       string `json:"title"`
    Description string `json:"description"`
    Position    int    `json:"position"`
}
type BoardColumns struct {
    Columns []BoardColumn `json:"columns"` // ordered by status order, then position
    Hidden  []string      `json:"hidden"`  // subset of HideableStatuses, never nil
}
var BoardStatusOrder = []string{"todo","in_progress","in_review","blocked","done","dismissed"}
var BoardStatusLabels = map[string]string{ /* Global Constraints */ }
var HideableStatuses = []string{"in_review","blocked"}
func (b BoardColumns) IsEmpty() bool                        // no columns and nothing hidden
func (b BoardColumns) IsHidden(status string) bool
func (b BoardColumns) Resolve(name string) (status string, columnID *int64, ok bool) // id, title or implicit label; case-insensitive
func (db *DB) GetBoardColumns(projectID int64) (BoardColumns, error)
func (db *DB) ReplaceBoardColumns(projectID int64, in BoardColumns) (BoardColumns, error) // one write tx; validates; returns the stored definition
func (db *DB) SetTargetColumnTx(tx *sql.Tx, targetID int64, status string, columnID *int64, actor string) error // one UPDATE of status, board_column_id, status_actor
// BoardNode gains: Column string // the leaf's effective column title when the board has columns defined; "" otherwise
```
`ReplaceBoardColumns` errors are `*BoardColumnsError{Msg string}` (user-facing text), e.g. `column "Code": status cannot change (delete it and add a new one)`.

- [ ] **Step 1: Write the failing tests** in `proj19_board_columns_test.go`:
  - `TestProj19_ColumnMustMatchStatusAndWorkbench`: set a `todo` target's `board_column_id` to an `in_progress` column → error containing `board column does not match the target`; to another workbench's column → same error; to a `todo` column of its workbench → ok.
  - `TestProj19_StatusChangeClearsForeignColumn`: target in `in_progress` column "Code"; `UpdateTargetStatusAsTx(…, "done", ActorAgent)` succeeds and `board_column_id` is NULL; exactly one new `target_status_history` row.
  - `TestProj19_StatusAndColumnInOneStatement`: `SetTargetColumnTx(tx, id, "in_progress", &codeID, ActorAgent)` from `todo` → status `in_progress`, column = codeID, one history row with actor `agent`.
  - `TestProj19_ColumnMoveWritesNoHistory`: moving between two `in_progress` columns adds no history row.
  - `TestProj19_DeletedColumnFallsBack`: `ReplaceBoardColumns` without "Code" → its targets' `board_column_id` NULL, status unchanged.
  - `TestProj19_SnoozeClearsColumn`: status → `snoozed` clears the column; back to `todo` keeps it NULL.
  - `TestReplaceBoardColumns_Validates`: 7 columns in one status, 21 total, empty/41-char title, duplicate title (case-insensitive), a `todo` column titled "done", 501-char description, an unknown status, hiding `todo`, changing an existing id's status, an id of another workbench → each a `*BoardColumnsError`, nothing written.
  - `TestReplaceBoardColumns_KeepsIDsAndOrder`: update by id keeps the id and its targets' column; positions are rewritten 0..n per status in input order.
  - `TestBoardColumnsResolve`: by id string, title any case, implicit label of a status without columns (→ columnID nil); a status's label when that status has columns → not ok.
  - `TestGetWorkbenchBoard_ColumnOnLeavesOnly`: leaf in "Code" → `Column == "Code"`; leaf with NULL in `todo` with columns Backlog/Ready → "Backlog"; parent → ""; no definition → "" everywhere.
- [ ] **Step 2: Run** `go test ./internal/db -run 'Proj19|BoardColumns|ColumnOnLeaves'` → FAIL (undefined).
- [ ] **Step 3: Migration** per spec §4: table, index, `targets.board_column_id`, `projects.board_hidden_statuses`, triggers `targets_board_column_check_ai`, `targets_board_column_check_bu` (`BEFORE UPDATE OF board_column_id … WHEN NEW.board_column_id IS NOT OLD.board_column_id AND NEW.board_column_id IS NOT NULL`), `targets_board_column_clear_au` (`AFTER UPDATE OF status, project_id`). Down drops them. The clear's inner UPDATE touches only `board_column_id`, so it fires neither rollup nor history triggers (both are `OF status…`). Mirror into `schema.sql`, regenerate the snapshot and Swift test schema, add the table to `TestAllTablesExist`.
- [ ] **Step 4: Implement** `board_columns.go` (the Interfaces above) and fill `BoardNode.Column` in `GetWorkbenchBoard` for leaves only, after the tree is built, from one `GetBoardColumns` read.
- [ ] **Step 5: Run** `go test ./internal/db` → PASS (whole package: the schema goldens live here).
- [ ] **Step 6: Commit** `feat(db): workbench board columns table and PROJ-19 triggers (board #267)`.

### Task 2: `watchtower workbench columns` CLI

Depends on: Task 1.

**Files:** Create `cmd/workbench_columns.go`, `cmd/workbench_columns_test.go`.

**Interfaces — Produces:** `watchtower workbench columns <id> [--json] [--set -]`. Output JSON = `db.BoardColumns` (`{"columns":[…],"hidden":[…]}`, `columns` never null). `--set -` reads that JSON from stdin, calls `ReplaceBoardColumns`, prints the stored definition with `--json`; a `*BoardColumnsError` prints its `Msg` to stderr and exits 1. Without `--json`, a human list: one line per status with its columns, then `Hidden: …`.

- [ ] **Step 1: Failing tests** (pattern: `cmd/workbench_methodology_test.go`): `TestWorkbenchColumns_JSONEmpty` (`{"columns":[],"hidden":[]}`), `TestWorkbenchColumns_SetRoundTrip`, `TestWorkbenchColumns_SetRefusesAndWritesNothing` (a validation error: exit 1, stderr has the message, a second `--json` read shows the old definition), `TestWorkbenchColumns_UnknownWorkbench`.
- [ ] **Step 2: Run** `go test ./cmd -run TestWorkbenchColumns` → FAIL.
- [ ] **Step 3: Implement** as a subcommand of `workbenchCmd` beside `workbench methodology`.
- [ ] **Step 4: Run** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(workbench): columns CLI (board #267)`.

### Task 3: Agent surface — tools, brief, skill pack

Depends on: Task 1.

**Files:**
- Modify: `internal/tools/workbench_targets.go` (`updateTargetArgs.Column *string`, validate, scope, `applyTargetFields`), `internal/tools/workbench_board.go` (`boardNodeView.Column string json:"column,omitempty"`), `internal/tools/targets_read.go` (workbench `get_target` gains `column` when non-empty), `internal/tools/workbenches.go` (`workbench_info` gains `columns`/`hidden_statuses`, `omitempty`, only when `!IsEmpty()`), `cmd/workbench_brief.go` + new `cmd/workbench_brief_columns.go`, `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (pack v11), `internal/devpack/testdata/watchtower-workbench-v10.md` (the shipped v10 copied as a fixture; add it to the fixture lists in `workbench_test.go` / `workbench_methodology_test.go` with its digest), `.agents/skills/watchtower-workbench/SKILL.md` if it is a generated mirror.
- Test: `internal/tools/workbench_columns_test.go`, `cmd/workbench_brief_columns_test.go`.

**Interfaces — Consumes:** `GetBoardColumns`, `BoardColumns.Resolve/IsHidden/IsEmpty`, `SetTargetColumnTx`, `BoardNode.Column`, `BoardStatusLabels`.
**Produces:** `func briefColumnsSection(c db.BoardColumns) string` ("" when `IsEmpty()`); `func hiddenStatusRefusal(status string) error`.

Behaviour (spec §5):
- `column` (`jsonschema:"move the card to this board column (title from the brief or workbench_info, or its id); sets the status to the column's category; \"\" = first column of its status"`).
- Resolve under `Scope` (after `targetInWorkbench`): unknown name → `ValidationError` listing the column titles; `column` + `status` of another category → `"column \"Code\" is in in_progress, status says done — send one of them"`; target has children → `"columns apply to leaf targets"`; resolved or plain `status` hidden → `hiddenStatusRefusal`: `"in_review is turned off on this board — go straight to done once the review passes"` / `"blocked is turned off on this board — leave it in_progress; the open ask already shows the owner what waits"`.
- Write: a resolved column → `SetTargetColumnTx(tx, id, status, columnID, db.ActorAgent)` instead of the plain status write (skip it if status and column are unchanged); `column: ""` → `SetTargetColumnTx(…, t.Status, nil, …)`.
- Brief: `renderSessionBrief`'s `method` argument is extended by the caller (`briefFromDB`) with `briefColumnsSection` (joined by "\n"), so it sits in the reserved rules block. Shape and the 1000-char fallback line exactly as spec §5. `briefTargetLine` shows `n.Column` in place of the status word when non-empty (`[Code 2h, medium, 40%]`, the age logic unchanged).
- Skill pack paragraph (core skill, under Rules), verbatim:
  > - When the brief shows **Board columns**, they are the owner's columns inside the statuses: move a card with `update_target` `column` when a column's description fits (it sets the status too). A status the brief marks **Turned off** is never set — the brief says what to do instead, and this overrides any methodology preset.
  Bump `x-watchtower-pack` to `v11`.

- [ ] **Step 1: Failing tests** — `TestUpdateTarget_ColumnSetsStatusAndColumn`, `TestUpdateTarget_ColumnResolvesByTitleCaseInsensitiveAndImplicitLabel`, `TestUpdateTarget_ColumnStatusConflictRefused`, `TestUpdateTarget_ColumnOnParentRefused`, `TestUpdateTarget_HiddenStatusRefused` (both statuses, via `status` and via `column`), `TestUpdateTarget_UnknownColumnListsTitles`, `TestUpdateTarget_EmptyColumnClears`, `TestWorkbenchBoard_ColumnFieldOnlyWithDefinition`, `TestGetTarget_ColumnField`, `TestWorkbenchInfo_ColumnsOnlyWhenDefined`, and a byte-identical guard `TestProj19_NoDefinitionAgentOutputsUnchanged` (board, get_target, info JSON of a fixture workbench equal before and after an empty `ReplaceBoardColumns`); brief: `TestBriefColumns_Section`, `TestBriefColumns_LongFallsBackToOneLine`, `TestBriefColumns_TargetLineShowsColumn`, `TestBriefColumns_NoneLeavesBriefUnchanged` (existing `TestBrief*` goldens untouched).
- [ ] **Step 2: Run** `go test ./internal/tools -run 'Column|Proj19' && go test ./cmd -run BriefColumns` → FAIL.
- [ ] **Step 3: Implement** the tool changes.
- [ ] **Step 4: Implement** the brief section and target line.
- [ ] **Step 5: Implement** the skill paragraph, v11, the v10 fixture.
- [ ] **Step 6: Run** `go test ./internal/tools ./internal/devpack && go test ./cmd -run 'Brief|WorkbenchColumns'` → PASS; `make lint-diff`.
- [ ] **Step 7: Commit** `feat(workbench): agent moves cards by board columns (board #267)`.

### Task 4: Swift Core — columns, layout, owner moves

Depends on: Task 1 (schema in the Swift test schema).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/WorkbenchBoardColumns.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/BoardColumnLayout.swift`, `WatchtowerDesktop/Tests/Core/BoardColumnLayoutTests.swift`, `WatchtowerDesktop/Tests/Core/WorkbenchBoardColumnWritesTests.swift`
- Modify: `WatchtowerCore/Database/Queries/WorkbenchQueries.swift` (`boardColumns(_:projectID:)`; `board(...)` fills the node's column id), `WatchtowerCore/Models/Workbench.swift` (`WorkbenchBoardNode.boardColumnID: Int64?`), `WatchtowerCore/Models/Target.swift` (decode `board_column_id`), `WatchtowerCore/Services/WorkbenchBoardKanban.swift` (re-key), `WatchtowerCore/Services/WorkbenchOwnerWrites.swift` (`moveToColumn`).

**Interfaces — Produces:**
```swift
package struct WorkbenchBoardColumnDef: Codable, Equatable, Identifiable { id: Int64?; status: String; title: String; description: String; position: Int }  // CodingKeys match the CLI JSON
package struct WorkbenchBoardColumns: Codable, Equatable { columns: [WorkbenchBoardColumnDef]; hidden: [String]; static let empty; var isEmpty: Bool }
package struct BoardColumnSlot: Equatable, Identifiable { key: String /* status for implicit, "c<id>" otherwise */; status: String; columnID: Int64?; title: String; description: String; categoryLabel: String?  /* set when title differs from the status label */; id: String { key } }
package enum BoardColumnLayout {
    static func slots(_ def: WorkbenchBoardColumns, occupiedStatuses: Set<String>, showDismissed: Bool) -> [BoardColumnSlot]
    static func slotKey(status: String, columnID: Int64?, def: WorkbenchBoardColumns) -> String  // NULL / foreign → first slot of the status
}
WorkbenchOwnerWrites.moveToColumn(_ db: Database, targetID: Int64, status: String, columnID: Int64?) throws -> WorkbenchOwnerWrite // one UPDATE of status, board_column_id, status_actor = 'owner'
```
`WorkbenchBoardKanban.init` gains `columns: WorkbenchBoardColumns = .empty`; `Column` gains `key`, `columnID`, `description`, `categoryLabel`; `Column.id` becomes `key`; `totals` is keyed by `key`. With `.empty`, columns, keys (= status) and totals equal today's.

- [ ] **Step 1: Failing tests** — `BoardColumnLayoutTests`: `testEmptyDefinitionIsTodaysColumns`, `testDefinedColumnsInStatusOrderThenPosition`, `testHiddenEmptyStatusIsSkipped`, `testHiddenStatusWithCardsStillShows` (standard label), `testCardWithNullColumnGoesToFirstColumn`, `testCategoryLabelOnlyWhenTitleDiffers`; Kanban: `testKanbanWithTwoInProgressColumnsHasDistinctTotals` (no trap, totals per key), `testDoneFoldCoversEveryDoneColumn`; writes: `testMoveToColumnWritesStatusAndColumnOnce` (one history row actor owner), `testMoveBetweenColumnsOfOneStatusWritesNoHistory`, `testMismatchedColumnIsRefusedByTheTrigger`.
- [ ] **Step 2: Run** `make test-swift FILTER='BoardColumnLayoutTests|WorkbenchBoardColumnWritesTests|WorkbenchBoardKanban'` → FAIL.
- [ ] **Step 3: Implement** the model, query, layout and `moveToColumn`.
- [ ] **Step 4: Re-key** `WorkbenchBoardKanban` (columns, lane columns, `totals`, `cards(inColumn:)`) by slot key; keep the `__other__` column and `acceptsDrops` (false for it).
- [ ] **Step 5: Run** the filter above plus every existing `WorkbenchBoard*` test class → PASS; `make lint-swift`.
- [ ] **Step 6: Commit** `feat(desktop): board column layout and owner moves (board #267)`.

### Task 5: Desktop UI — columns sheet, drag, panel picker

Depends on: Tasks 2 and 4.

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Workbench/BoardColumnsSheet.swift`, `WatchtowerDesktop/Tests/Core/BoardColumnsDraftTests.swift` (+ `WatchtowerCore/Services/BoardColumnsDraft.swift` — the sheet's editable state and its client-side checks mirroring the Global Constraints, so the sheet shows errors before Save)
- Modify: `Services/WorkbenchCLI.swift` (`boardColumns(projectID:)`, `setBoardColumns(projectID:_:)` via `workbench columns <id> --json [--set -]`, stdin JSON), `ViewModels/WorkbenchBoardViewModel.swift` (load the definition with the board; drop → `moveToColumn`), `Views/Workbench/WorkbenchBoardKanbanView.swift` (header title, caption, tooltip; drop target per slot), `Views/Workbench/WorkbenchHeaderControls.swift` (`moreMenu`: **Board Columns…**), the target panel's status picker (columns grouped by status when the definition is non-empty).

Sheet behaviour (spec §6): statuses in `BoardStatusOrder`, each with its columns (add, rename, drag to reorder, delete, description field) and a **Hide** toggle on `in_review`/`blocked`; Save calls `setBoardColumns`, shows the CLI's stderr message inline on failure; deleting a column with cards shows "N cards move to <first column>".

- [ ] **Step 1: Failing tests** — `BoardColumnsDraftTests`: `testDraftRejectsSeventhColumnInAStatus`, `testDraftRejectsTitleEqualToAnotherStatusLabel`, `testDraftKeepsIDsOnRename`, `testDraftEncodesTheCLIJSON` (keys `columns`/`hidden`/`id`/`status`/`title`/`description`/`position`), `testDeleteNoticeCountsCards`; `WorkbenchBoardViewModelTests.testDropOnColumnMovesStatusAndColumn`.
- [ ] **Step 2: Run** `make test-swift FILTER='BoardColumnsDraftTests|WorkbenchBoardViewModelTests'` → FAIL.
- [ ] **Step 3: Implement** draft, CLI wrapper, sheet, menu item, Kanban header/drop, panel picker.
- [ ] **Step 4: Run** the filter → PASS; `make lint-swift`; build the app once (`make test-swift FILTER=BoardColumnsDraftTests` links it).
- [ ] **Step 5: Commit** `feat(desktop): Board Columns sheet and column drag (board #267)`.

### Task 6: Phone — column name

Depends on: Task 4.

**Files:** Modify `WatchtowerKit/Sources/WatchtowerKit/Models/WorkbenchTarget.swift` (`public let column: String?`, decoded if present), `WatchtowerDesktop/Sources/Services/MobileHub/Slices/WorkbenchTargetSlice.swift` (set `column` = the leaf's effective column title when the definition is non-empty, else nil — reuse `BoardColumnLayout`), `WatchtowerMobile/Sources/Features/Workbench/BoardModel.swift` + `BoardTargetDetailModel.swift` (show `target.column ?? statusLabel(target.status)`).
Tests: Kit `WorkbenchTargetTests.testDecodesWithAndWithoutColumn`; Desktop slice `WorkbenchTargetSliceTests.testColumnOnlyWithDefinition`; mobile `BoardModelTests.testRowShowsColumnTitle`.

- [ ] **Step 1: Failing tests** above.
- [ ] **Step 2: Run** `make kit-test FILTER=WorkbenchTargetTests`, `make test-swift FILTER=WorkbenchTargetSliceTests`, `make mobile-test MOBILE_FILTER=BoardModelTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the three → PASS; `make lint-swift` (and the phone tree's lint via `make lint-all` scope if cheap).
- [ ] **Step 5: Commit** `feat(mobile): board column name on the phone (board #267)`.

### Task 7: Contracts and docs

Depends on: Tasks 1–6.

**Files:** `docs/inventory/workbench.md` (new **PROJ-19 — board columns never contradict the status**, wording from spec §8 with its test guards: Task 1 `TestProj19_*`, Task 3 `TestProj19_NoDefinitionAgentOutputsUnchanged`, `TestBriefColumns_NoneLeavesBriefUnchanged`, Task 4 `testEmptyDefinitionIsTodaysColumns`; notes under PROJ-05/06/07 that columns do not touch them; the PROJ-04 changelog line for pack v11; the P5 note that any new agent writer of a workbench status calls `hiddenStatusRefusal`), `docs/features/workbench.md` (a "Board columns" paragraph), `CLAUDE.md` (the Workbench line: "board columns (2026-10-16, board #267: `workbench_board_columns`, `workbench columns`, `update_target column`, hidden in_review/blocked, PROJ-19)").

- [ ] **Step 1: Write** the three docs.
- [ ] **Step 2: Run** `bash scripts/leak-check.sh` over the branch if available, else `make lint-diff`.
- [ ] **Step 3: Commit** `docs(workbench): board columns contract PROJ-19 (board #267)`.

### Phase gate (controller)

`make test`, `make test-swift`, `make lint-all`, `make mobile-test` once, then the PR into `main`.
