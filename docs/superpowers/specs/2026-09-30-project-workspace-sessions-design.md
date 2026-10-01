# Project workspace — sessions, split layout, "Work on it", standalone terminals

**Date:** 2026-09-30
**Status:** Implemented (2026-10-01; Tasks 1–12 of `docs/superpowers/plans/2026-09-30-project-workspace-sessions.md`). The bottom shell console (#120) was dismissed by the owner.
**Board targets:** #77 (several sessions per project), #87 ("Work on it"), #86 (split layout), #73 (collapsible panel), #103 (standalone terminal)
**Builds on:** `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` (Projects POC)

## Intent

The owner wants the Projects page to be the place they actually work from: several Claude Code sessions per project, each clearly named, one click from a board target to an agent working on it, the terminal visible next to the board or a document when they want it, and a scratch terminal for chores that belong to no project.

What the owner said (2026-09-30):
- A project holds several Claude Code sessions. Navigation lives in the left panel, not a tree: clicking a project drills into its sessions (switch / new / close) with a Back button to the project list. The panel is collapsible like the AI Chat history.
- Split is optional: one pane by default, a split when wanted, and any pane can be expanded to the full page.
- Each board target and sub-target has a "Work on it" button that starts a session for it; if one already exists it switches to it. Whether the agent uses a worktree is the agent's call.
- Every terminal has a name that says what is in it, generated automatically.
- Sessions survive an app restart (owner choice: remember and resume).
- "Work on it" starts the agent immediately (owner choice), no Return needed.
- A standalone terminal (#103) is part of this design, as a "Terminals" section.

## Non-goals (v1)

- No cap on the number of live sessions (the panel shows the live count).
- No forced git worktree per session.
- No sharing a session between projects, no moving a session to another project.
- No kanban board (#76), no board card redesign (#85) — separate targets.

## 1. Data — `terminal_sessions`

New goose migration (mirrored into `schema.sql`, `TestAllTablesExist`, golden snapshot):

| column | type | notes |
|---|---|---|
| `id` | INTEGER PK | |
| `project_id` | INTEGER NULL → `projects(id) ON DELETE CASCADE` | NULL = standalone terminal |
| `kind` | TEXT CHECK(`claude`,`shell`) | |
| `title` | TEXT NOT NULL | |
| `title_source` | TEXT CHECK(`auto`,`ai`,`user`) DEFAULT `auto` | `user` is never overwritten |
| `target_id` | INTEGER NULL → `targets(id) ON DELETE SET NULL` | set by "Work on it" |
| `folder_path` | TEXT NOT NULL | the cwd the session starts in |
| `claude_session_id` | TEXT NULL | UUID Watchtower generates; NULL for `shell` |
| `created_at`, `last_active_at` | TEXT | |
| `closed_at` | TEXT NULL | set when the owner closes it (process stopped, row kept) |

Indexes on `(project_id, last_active_at)` and `target_id`. `target_id` is deliberately not unique — a target may collect several sessions over time; "Work on it" picks the most recently active one (§4).

**Writers:** Swift writes every column except the AI title. Go writes only `title` (with `title_source='ai'`) through `watchtower terminal title <id>` (§5), never over `title_source='user'` — the `chat title` precedent.

**PROJ-02:** `project delete` removes the project's session rows (CASCADE, plus the existing single-transaction removal). The Claude Code transcripts under `~/.claude/projects/` are Claude Code's own files and are not touched.

**PROJ-01:** a standalone terminal (`project_id IS NULL`) is not a project row and reaches no project reader; a project session reaches no non-project reader.

## 2. Processes — `TerminalCenter`

`ProjectTerminalCenter` becomes `TerminalCenter`, keyed by `terminal_sessions.id` instead of `project.id`. Everything else it does stays: login shell, `exec claude`, SIGHUP → SIGKILL after 3 s, `closeAll()` from `QuitCoordinator`, the bracketed-paste/clipboard `sendPrompt` path.

Launch commands (built by a pure `TerminalLaunch` builder in WatchtowerCore):

- project `claude`, new: `exec claude --session-id <uuid> [prompt]` in the project folder — the project's MCP (`watchtower-project`) and `SessionStart` hook apply as today, since they are installed per folder.
- project `claude`, resume: `exec claude --resume <uuid>`.
- standalone `claude`: the same flags in the chosen folder (default `~`); **no** project MCP or hook is passed or installed. (If the chosen folder happens to be a project folder, its local Claude Code config applies as it would in any terminal — Watchtower adds nothing.)
- `shell`: the login shell alone, no `exec claude`.

A process keeps running while the owner switches sessions or projects. When a `claude` process exits (owner typed `/exit`, crash), the row stays open and the pane offers "Resume". **Close** stops the process and sets `closed_at`; the session stays in the list (dimmed) and can be resumed. **Delete** removes the row (after a close); Claude Code's transcript is left alone.

After an app restart no process is running: every open session shows as "not running" and starts (`--resume`) on first selection — nothing launches by itself at startup.

Resume failure (transcript gone, `claude` refuses the id): the pane shows the error and offers "Start fresh" (a new UUID, same row, same title).

## 3. Navigation and layout

**Left panel**, collapsible from the toolbar like the AI Chat history (#73), state remembered:

- Level 1 — **Projects** list (as today, with badges) and a **Terminals** section: standalone sessions + "New terminal" (menu: Claude Code / Shell, folder: Home or Choose…).
- Level 2 — clicking a project: a Back button, the project name, **Board** and **Documents** entries, then the project's **sessions** (live ones marked with a dot, closed ones dimmed, most recently active first) and "New session". A session row shows its title and, for a target session, the target id; right-click: Rename, Close, Delete.

**Main area**, per project:

- **Single pane** (default): whichever of Terminal (the selected session) / Board / Documents is selected in the panel.
- **Split** (optional): a toolbar toggle splits the area into two panes with a draggable divider; each pane has its own picker (a session, Board or Documents). Orientation: side by side.
- **Expand**: every pane has an expand button that shows it alone full-size; pressing it again returns to the split.
- Layout (single/split, what's in each pane, divider position, expanded pane) is remembered per project in UserDefaults — it is view state, not data. A standalone terminal always opens single-pane.

**Send N comments** (documents) types its one line into the project's **active session** — the most recently focused live `claude` session of that project. If a terminal pane is already visible (split) the page does not switch panes; otherwise it switches to that session as today. No live session → the existing "Open terminal" path, now "open the most recent session or start one". The line still never auto-submits (unchanged `ProjectCommentPrompt` rule).

## 4. "Work on it" (#87)

A button on every board row (target and sub-target).

1. If a session with this `target_id` exists in the project, select the most recently active one (resuming it if not running).
2. Otherwise create a row (`kind='claude'`, `title` = the target's text, `title_source='auto'`, `target_id`) and launch `claude --session-id <uuid> "Work on target #<id> using the watchtower-project skill."`.

The prompt is a fixed template with one integer; no owner- or agent-authored text reaches argv, so a target title cannot inject flags or shell syntax. It is passed as an argv prompt rather than typed into the TUI, so it cannot confirm whatever dialog the TUI is showing (the reason `ProjectCommentPrompt` never auto-submits does not apply). The agent then follows the skill: sets the target `in_progress`, reads its comments, decides on a worktree itself.

## 5. Names

Every session always has a readable name:

- "Work on it": the target's text (`auto`).
- New project/standalone `claude` session: provisional `New session · HH:MM` (`auto`); then an AI title (`ai`) once the owner has said something.
- `shell`: mechanical `<shell name> — <folder basename>` (`auto`), never AI.
- Rename from the context menu sets `title_source='user'`; nothing overwrites it afterwards.

**AI title:** new CLI `watchtower terminal title <id>` (Go) reads the session's Claude Code transcript (`~/.claude/projects/<escaped folder>/<claude_session_id>.jsonl`), takes the first owner messages (capped, e.g. 2,000 chars; tool output and assistant text excluded), and — if there is at least one — asks the light tier for a 3–6 word title via a new prompt `terminal.title` (add-ai-prompt skill: both providers, `digest.WithSource` tag, light tier). It writes `title` only when `title_source='auto'` (a `user` row is refused, an `ai` row is kept — the title is generated once). No owner message yet → exit 0, nothing written. The transcript text travels to the model on stdin, never argv. A transcript path that resolves outside `~/.claude/projects` is refused.

**When Swift calls it:** for an `auto`-titled `claude` session, when the owner switches away from it, when it is closed, and on the center's 2-minute poll while it is live — until the row is no longer `auto` or 5 attempts have been made (an in-memory counter per launch). A failure is logged and leaves the provisional name.

## 6. Error handling

- Missing project folder → the session pane shows "The folder … no longer exists" (today's `.unavailable` state); the row stays.
- `claude` not on PATH → the existing launch error in the pane.
- Title CLI failure → provisional name stays, logged; never an alert.
- A DB write failure on create/close/rename → shown in the panel, the process is not started for a row that was not written.

## 7. Testing

- WatchtowerCore (fast, no ML link): `TerminalLaunch` (all four command shapes, the fixed "Work on it" template, argv quoting), `WorkspaceLayoutPolicy` (single/split/expand transitions, per-project persistence encoding), active-session resolution for Send comments, "Work on it" session selection (existing live / existing closed / none), title-source rules.
- `TerminalQueries` (GRDB): create/close/delete/rename, cascade on project delete, `target_id` SET NULL on target delete.
- `TerminalCenter` with a fake session: switch keeps processes alive, close stops only the chosen one, `closeAll` on quit, resume after exit, start-fresh after a failed resume.
- Go: migration + schema golden; `terminal title` — no owner message = no write, `user` never overwritten, transcript outside `~/.claude/projects` refused, stdin not argv, tier-scan and prompt-store scans stay green.
- PROJ-01..04 and DEV-06 guard tests unchanged; PROJ-02's removal test extended to the new table.

## Open questions for the owner

None blocking. Defaults chosen above that the owner may want to change: side-by-side split only (no top/bottom), no live-session cap, AI title generated once (not refreshed as the conversation drifts).
