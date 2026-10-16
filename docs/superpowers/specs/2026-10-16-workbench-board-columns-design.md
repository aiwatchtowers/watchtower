# Workbench — configurable board columns (design)

Board #267, under #265 "Workbench for your own workflow". Methodology (#266, PR #293) shipped first, per ask #138. Owner decisions: ask #201 (why), ask #202 (storage, who moves, hiding, phone).

## 1. Problem

The Workbench board has six fixed statuses: `todo`, `in_progress`, `in_review`, `blocked`, `done`, `dismissed`. They are our flow. A customer's flow can differ — "Spec", "Code", "Waiting for QA", "Deployed to staging" — and today the board cannot show it (owner, ask #201: «наши предложенные статусы могут не соответствовать флоу кастомера»).

The six statuses cannot simply become free-form: the parent rollup (PROJ-05), the status history (PROJ-06), the drift check (PROJ-07), the hooks, the skill pack and the phone all read them.

## 2. Goal, non-goals, anti-goals

**Goal.** The owner defines the board's columns per workbench. Every column sits inside one of the six status categories. The owner can rename a category, split it into several columns, and hide `in_review` or `blocked` entirely. Each column carries a description that tells the agent when a card goes there. The agent moves cards between columns by those descriptions; the owner drags them on the Desktop. The phone shows the column name.

**Non-goals (v1).**
- `who_moves` (a column only the owner may move into) — only when a real request comes (target intent).
- Columns in the folder file `.watchtower/workflow.md` — the owner chose a personal setting (ask #202).
- WIP limits, column colours, column-level status history.
- Changing the six categories or the rollup/history/drift rules.
- Columns on personal (non-workbench) targets.
- A column on `create_targets` (a new target lands in its category's first column).

**Anti-goals.**
- A board with no columns defined must look and behave exactly as today, byte for byte in every agent-facing text.
- A target must never show in a column whose category differs from its status.
- No second implementation of a rule in Go and Swift where SQLite can carry it (the PROJ-05 pattern).

## 3. Model

- **Category** = the target's `status`. Unchanged everywhere.
- **Column** = a named place inside one category of one workbench: `{id, project_id, status, title, description, position}`.
- **A category with no defined columns** has one implicit column: today's label ("To Do", "In Progress", …). Renaming a category = defining one column for it.
- **A target's column**: `targets.board_column_id`, nullable. The card shows in that column; when it is NULL (or the category has no defined columns) it shows in the category's first column by `position`.
- **Invariant (in SQLite, §4):** a target's column belongs to the same workbench and to the target's current status. A status change that leaves the column's category clears `board_column_id` — the card lands in the new category's first column.
- **Hidden categories:** only `in_review` and `blocked` can be hidden (`todo`, `in_progress`, `done` carry the rollup and target creation; `dismissed` is already folded away). A hidden category has no column on the board while it is empty; the agent may not set it (§5). Targets already in it stay visible in a column with the category's standard label until they move out. *Builder's note: only these two are hideable — my call, to keep the rollup's inputs intact.*
- **Parents:** a column applies to leaf targets only. A parent's status is derived (PROJ-05); every reader ignores a parent's `board_column_id` and shows the parent in the first column of its category (the Desktop Kanban already places only leaves — parents are lanes —, so this concerns the brief, `workbench_board` and the phone). A leaf that gains children keeps its stored column; readers ignore it while it has children, no trigger. `update_target(column)` on a target with children is refused (`columns apply to leaf targets`) — a new refusal; a parent's `status` write stays allowed as today (PROJ-05 unchanged). *My call: refusing is clearer to the agent than a silent no-op.*
- **`snoozed`** (a seventh value of `targets.status`, set and cleared by the daemon) is not a column category. Snoozing clears the column like any category change; the card shows where it does today (`__other__` on the Desktop).
- **Limits** (my call): at most 6 columns per category, 20 per workbench; title 1–40 characters, unique per workbench case-insensitively, and never equal to another category's standard label (so a `todo` column cannot be named "Done" while `done` uses its implicit column); description up to 500 characters.

## 4. Storage

Migration (next free number at merge; `00125`):

```sql
CREATE TABLE workbench_board_columns (
  id          INTEGER PRIMARY KEY,
  project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  status      TEXT NOT NULL CHECK(status IN ('todo','in_progress','in_review','blocked','done','dismissed')),
  title       TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  position    INTEGER NOT NULL,
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_workbench_board_columns_project ON workbench_board_columns(project_id, status, position);

ALTER TABLE targets  ADD COLUMN board_column_id INTEGER NULL REFERENCES workbench_board_columns(id) ON DELETE SET NULL;
ALTER TABLE projects ADD COLUMN board_hidden_statuses TEXT NULL; -- JSON array, subset of ["in_review","blocked"]; NULL = none
```

Triggers (one implementation for Go and the Desktop's GRDB writes, like PROJ-05):
- **Check** — `BEFORE INSERT` on `targets`, and `BEFORE UPDATE OF board_column_id` when `NEW.board_column_id IS NOT OLD.board_column_id`: when `NEW.board_column_id` is set and that column's `project_id`/`status` differ from `NEW`'s → `RAISE(ABORT, 'board column does not match the target')`. It fires only when the column itself is written, so a plain status change never aborts.
- **Clear** — `AFTER UPDATE OF status, project_id ON targets` when `NEW.board_column_id` is set and that column's `project_id`/`status` differ from `NEW`'s → `UPDATE targets SET board_column_id = NULL WHERE id = NEW.id`. A plain status change thus lands the card in the new category's first column.
- A writer that moves a card writes `status` and `board_column_id` in one statement; the check sees the new pair and passes, the clear finds nothing to clear.
- Column changes never write `target_status_history` (PROJ-06 untouched).

Mirror in `schema.sql`, `TestAllTablesExist`, the snapshot and the Swift test schema, per the `add-migration` skill.

**Writer.** One writer for the definition: `watchtower workbench columns <id>`:
- `--json` prints `{columns:[{id,status,title,description,position}], hidden:[…]}`.
- `--set -` reads the same JSON on stdin and replaces the definition in one write transaction: rows with an `id` are updated, rows without are created, rows missing from the input are deleted (their cards fall to the category's first column via `ON DELETE SET NULL`). A row's `status` cannot change (refused: delete and re-create instead — my call, so a card never silently changes status). Limits from §3 are checked; any violation refuses the whole input.
- Hiding a category that still has targets is allowed (§3).

The Desktop calls this command, as it does for `workbench methodology`; it does not write the definition itself. Card moves are ordinary target writes (§6), written by the Desktop through GRDB as status writes are today.

## 5. The agent

**`update_target`** gains `column` (a column title, case-insensitive, or its id; the standard label of a category with no defined columns — e.g. "Done" — also resolves, to that status with `board_column_id = NULL`, so every name the brief shows works):
- Sets `board_column_id` and the status to the column's category in one statement (actor `agent`, so a category change is recorded in the history as today).
- `column` together with a `status` of another category → refused with an error naming both.
- `column: ""` clears it (the card goes to the first column of its category).
- On a target with children → refused (§3).
- `status` alone works as today: the trigger clears a column of another category.

**Hidden categories:** `update_target(status)` (or a `column` resolving to a hidden status) is refused on the workbench MCP surface — today the only agent writer of a workbench target's status: `"<status> is turned off on this board — <what to do instead>"`, where the hint is: for `in_review`, "go straight to done once the review passes"; for `blocked`, "leave it in_progress; the open ask already shows the owner what waits". The CLI and the Desktop (owner writers) and the rollup/system writers are not refused. Automations P5 adds workbench target writes for recipes; whichever agent-facing writer it adds must call the same check (one Go helper, e.g. `workbenchHiddenStatus(project, status)`), and PROJ-19 says so — this plan does not wait for P5.

**Reading.** `workbench_board` and `get_target` add `column` (title) to each target that is on a board with columns defined. `workbench_info` adds `columns` (the definition with descriptions) and `hidden_statuses`. With no columns and nothing hidden, nothing is added — the outputs stay byte-identical.

**The brief.** `renderSessionBrief` gains a **Board columns** section, only when columns are defined or a category is hidden, reserved up front next to Folder rules:

```
Board columns (the owner's; move a card with update_target column when its description fits):
- To Do: Backlog — not yet looked at | Ready — spec agreed, can start
- In Progress: Spec — writing the design | Code — building it
- Done: Done
Turned off: in_review (go straight to done once the review passes).
```

At most 1000 characters; over that, one line instead: `Board columns: <N> columns defined — read them with workbench_info before you move a card.` The open-board lines in the brief show the column title instead of the status where one is defined. `TestBrief*` goldens extended.

**Skill pack.** The core `watchtower-workbench` skill gets one paragraph under "Keeping the board…"/Rules: when the brief shows Board columns, a card moves between columns by their descriptions with `update_target` `column`; a status the brief marks turned off is never set. Pack version bumps by one. The `watchtower-flow` preset text stays as is — the brief's "Turned off" line overrides it the same way Folder rules do; add one sentence saying so to the core skill.

## 6. The Desktop

**Kanban columns** (`WorkbenchBoardKanban.swift`): the hardcoded `["todo","in_progress","in_review","blocked","done"]` becomes a list built from the definition: for each category in today's order, its defined columns by `position`, or the implicit one; a hidden category is skipped while empty. `dismissed` and the synthetic `__other__` column behave as today. The Done fold covers every `done` column. A column header shows its title; when it differs from the category label, a small category caption under it; the description in its tooltip. A pure builder in WatchtowerCore (`BoardColumnLayout`) with Core tests does the layout. *Sizing note:* the Kanban is keyed by status throughout — column identity, lane columns, the `totals` dictionary (a `Dictionary(uniqueKeysWithValues:)` that would trap on two columns of one status). The Desktop task re-keys all of it by a column key (`status` for an implicit column, the column id otherwise); it is not a one-line list swap.

**Moving cards:** dragging to a column writes `status` + `board_column_id` in one GRDB statement through the existing owner write path (`actor = owner`). The target panel's status picker lists columns grouped by category instead of the six statuses when columns are defined.

**Editing:** a **Board Columns…** item in the board header menu opens a sheet: the six categories in order, each with its columns (add, rename, reorder by drag, delete, description field) and, for `in_review`/`blocked`, a **Hide** toggle. Save calls `workbench columns <id> --set -`; errors are shown inline. Deleting a column with cards says how many cards move to the category's first column.

## 7. The phone

The board slice gains an optional `column` (title) per target; the Kit decodes it as an optional field (open-wire, old phones ignore it). The phone shows the column title where it shows the status label today; the glyph and tone stay per category; filters stay per category. A status change from the phone stays a category write (the column clears, the card lands in the first column). Unrecognised extra fields keep decoding (existing open-wire rule).

## 8. Contracts

- **New PROJ-19 — board columns never contradict the status.** A target's column is of its workbench and of its current status (SQLite triggers, both writers); a status change clears a column of another category; column moves write no status history; with no columns defined and nothing hidden, every agent-facing text (brief, tool outputs, skill behaviour) and the Desktop board are as before. Guards: Go trigger tests, a brief golden with and without columns, a Desktop layout test with an empty definition.
- **Agent refusal of hidden statuses** is part of PROJ-19.
- PROJ-05, PROJ-06, PROJ-07: unchanged (noted in each that columns do not touch them).
- Skill pack version bump: note in PROJ-04's changelog as usual.
- `docs/features/workbench.md` gets a "Board columns" paragraph; CLAUDE.md's Workbench line gains a short mention.

## 9. Testing

- Go: migration + triggers (mismatch refused, status change clears, delete sets NULL, both-in-one-statement passes, other workbench refused); `workbench columns` set/replace/limits/status-immutable; `update_target` column/status/hidden/parent/implicit-label cases; `workbench_board`/`get_target`/`workbench_info` with and without columns (byte-identical without); brief goldens.
- Swift Core: `BoardColumnLayout` (empty definition = today's columns; hidden empty vs non-empty; order); GRDB move writes status + column; the trigger refusal surfaces as an error.
- Kit: slice decodes with and without `column`.
- Phone: label shows the column title.

## 10. Left to the builder

- Exact Swift type and view names; the sheet's layout.
- Whether `--set` takes stdin or a temp file path (stdin preferred).
- The brief section's exact wording beyond the shape above.
- Plan task split and order (schema + triggers first; agent, Desktop and phone can then run in parallel lanes).
