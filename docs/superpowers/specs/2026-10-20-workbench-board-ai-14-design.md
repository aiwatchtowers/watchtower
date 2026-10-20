# Workbench board — columns on the board, Linear-style New Task, header, drift Fix (design)

Target #713 (Linear AI-14). Desktop only: no Go, no migration, no agent-facing text changes. The column storage, limits and the `workbench columns --set -` write stay exactly as in the board-columns design (2026-10-16); this changes only where the owner edits them.

## 1. Columns edited on the board (replaces the Board Columns… sheet)

Problem: the sheet is a long form of every status with "One column: …" rows; the owner cannot see what a change does to the board.

Design — every edit happens on the Kanban's column header row:

- **Header context menu** (right-click, and a `…` button that appears on hover):
  - **Rename** — the title turns into an inline text field in place; Return saves, Esc cancels.
  - **Description…** — a small popover with one text field (the header's tooltip, the agent's guidance for the column).
  - **Add Column Right** / **Add Column Left** — a new "New Column" in the same status, already in rename mode.
  - **Move Left** / **Move Right** — within its status only (a column never changes status; disabled at the status's edges).
  - **Delete Column** — when the column holds cards, a confirm says "N cards move to <first column of the status>"; an empty column goes at once.
  - **Hide In Review** / **Hide Blocked** — on those two statuses only, as today.
- **A status without columns** shows its one implicit column (as today). On it, Rename defines the status's first column with the new title; Add Column defines two: one named after the status (it keeps the cards) and the new one beside it. Deleting the last column of a status returns it to the implicit one.
- **A `+` at the end of the header row** opens a menu: *Add column to → To Do / In Progress / In Review / Blocked / Done*, and *Show In Review* / *Show Blocked* when one is hidden — the only way back for a hidden empty status, which has no header to right-click.
- **Every edit saves at once** through the existing whole-definition write (`BoardColumnsDraft` → `setBoardColumns`); a refusal (limits, a duplicate title) shows inline under the header row and the board keeps the stored definition. No Save/Cancel.
- In the List mode the header menu item becomes **Edit Columns on the Kanban** (switches the mode). The sheet and its menu item are removed.

## 2. New Task like Linear's New issue

Problem: a form dialog — a "Title" field, a segmented priority, a "Description" box, and a separate parent line.

Design — one wide panel (~620 pt) with the text first and the controls as chips under it:

- Top line: a breadcrumb chip showing where the task goes (`Workbench › #702 Linear…` or `Workbench › Top level`); clicking it picks another parent from a searchable list of the board's open targets.
- A large borderless title field ("Task title"), then a borderless multi-line description ("Add description…") that grows with the text.
- A chip row under the text: **Priority** (menu High / Medium / Low with the board's priority glyph) and **Status/column** (menu of the To Do and In Progress columns, defaults to the first To Do column). Nothing else — the board has no assignees, labels or dates.
- Footer: **Create more** toggle on the left (keeps the panel open, clears the text, keeps parent and chips) and **Create Task** on the right; ⌘↩ creates from anywhere, Return in the title moves to the description, Esc closes.
- The create path is unchanged except the status/column chip: when not the default, the new target gets `column` right after creation (the existing column write).

## 3. Header

Drop the `Board` label before **+ New Task** — the page and the tab already say it.

## 4. Fix for board drift

Problem: the popover lists findings with fix instructions written for the agent; the owner has nothing to press.

Design:

- The popover header gets a **Fix** button (beside Refresh). It starts one new agent session of this workbench, shown like any new session, with the first prompt: *"Fix the board drift using the watchtower-workbench skill: run `watchtower workbench check --workbench <id>`, then update the board as each finding says. Findings now: #561 merged, still open; …"*. One session for every finding — each fix is a few board writes, a session per finding would cost more than the fixes.
- Each row also gets a small **Fix** on hover that starts the same kind of session for that one finding (`startForTarget` with a custom prompt, so it opens beside that target's sessions).
- While such a session runs, the Fix button reads **Fixing…** and opens that session instead of starting another.
- The session ends by itself as any session does; the drift banner refreshes on its usual cadence and goes away once the board agrees with git.

## 5. Testing

- `BoardColumnsDraft` gains the in-place operations (rename/define-implicit, add left/right, move within status, delete-last → implicit); covered in `Tests/Core/BoardColumnsDraftTests.swift`.
- The drift prompt builder lives in WatchtowerCore (`TerminalLaunch`) with a test pinning its shape; `WorkbenchesViewModelDriftTests` covers "Fixing…" reuse.
- New Task: `WorkbenchBoardViewModelTests` for Create more and the column chip.
- `make desktop-shots` for the header row, the context menu, the New Task panel and the drift popover before review.
