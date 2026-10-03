# Workbench session report — design (2026-10-03)

**Board:** feature target "Отчёт сессии: что сделано, PR, что на тебе; синяя точка у законченной сессии" (id in the plan header).
**Builds on:** owner asks (`docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md`, PR #147, branch
`feature/workbench-owner-asks`, not merged yet) and the session agent state (board #312, PR #142, PROJ-11).
**Plan:** `docs/superpowers/plans/2026-10-03-workbench-session-report.md`.
**Design mock:** the brainstorm screen "session-report" of 2026-10-03, built on the live data of sessions #314 (finished)
and #257 (working).

Part 1 is the one-page owner spec. Parts 2–9 are the technical spec: decisions and contracts for the implementing
sessions. Every UI string ships in English (the owner's standing rule); the Russian words in Part 1 are the
conversation's names, with the shipped label next to them.

---

## Part 1 — For the owner (one page)

**Problem.** You wake up to several sessions and each one is a wall of terminal text. You cannot see what a session
did, how far it got, which PRs were merged, or what is left on you. With many sessions this gets very hard.

**What you will see.**
- **A Session view next to the terminal**, where the Documents pane used to be. It shows the selected session's report:
  - **State and size.** A state badge (Working / Waiting / Needs approval / **Finished**), the session's ticket, how long
    it ran and its branches. A large **X / Y tasks** with a progress bar.
  - **«На тебе» ("On you")** comes first: this session's open asks, each with **Open**. When nothing is waiting:
    "Nothing — the agent is not waiting for you."
  - **«Сейчас» ("Now")**: the tasks in progress, each with its branch and start time.
  - **Pull requests**: each PR with merged / open / closed, the size (+/−) and when it was merged. A branch with done work
    but no PR shows "no PR yet".
  - **«Что сделано» ("Done")**: the session's work grouped by phase (the parent ticket). Each phase shows done/total and
    the time span, with "Next" for what is still todo.
  - **«Последнее слово агента» ("Agent's last word")**: two or three lines the agent wrote when it finished. This replaces
    reading the terminal.
- **Session rows in the panel** get a second line: ticket, a mini progress bar, X/Y and the PR state ("PR #147 open",
  "2 PRs merged").
- **A blue dot means finished.** Green = working, orange = waiting for you or needs approval, **blue = finished**, hollow =
  not running. A finished session stays blue after it is closed. It turns green again as soon as you send it a new
  prompt.
- **The agent says when it is done.** It calls a new tool with a short summary. If it stops with its work done and does
  not call the tool, the end-of-turn check reminds it.

**Decisions for you (recommendations marked).**
1. **The header toolbar** (Terminal ▾ / Board / Session / Files / split / ⋯): see toolbar decision, filled after the owner
   picks. Plan Task 11 waits for this pick. Every other task can go ahead without it.
2. **Amend PROJ-11** (session state hooks): add the Finished state, shown blue, and let the `UserPromptSubmit` write clear
   it. *Recommended: yes.*
3. **Amend PROJ-13** (the ask guard never traps a turn): the same Stop prompt also reminds the agent to call
   `finish_session`. All of PROJ-13's pass rules hold unchanged. *Recommended: yes.*
4. **Add PROJ-14** "a session report shows only that session's own work, and Finished comes only from the session's own
   `finish_session`". *Recommended: yes* (wording in Part 8).

**Out of scope (v1).** A cross-session "while you were away" overview, which is the next step on the same data. Reports
for standalone terminals and for `claude` in an external terminal. Session reports in the AI Chat or the briefing.
Editing the agent's summary. Marking a session finished by hand.

**Done when.**
- On the two real sessions the progress, phases and PRs match the mock: #314 shows 14/15 tasks (leaves; the mock's 16/17 counted parents), its phases and PR #147
  open, and #257 shows #273/#269 under "Now" and PRs #140/#146 merged.
- Their "On you" lists only asks filed after this ships, because the old requests were comments.
- A session that calls `finish_session` turns blue with its summary.
- An agent that finishes calls `finish_session`, or is reminded once to call it.
- A new prompt turns a blue session green.
- Rows show X/Y and the PR state without opening the session.

---

## Part 2 — Data (migration `00101_workbench_session_report.sql`)

The number follows `00100_owner_asks` on `feature/workbench-owner-asks`. If main takes `00101` first, the migration is
renumbered at merge (see the `project_goose_crossed_migration_line` note: check the tables exist, not the goose
version).

```sql
-- +goose Up
ALTER TABLE terminal_sessions ADD COLUMN finished_at    TEXT;              -- UTC ISO-8601 with ms (agent_state_at format); NULL = not finished
ALTER TABLE terminal_sessions ADD COLUMN finish_summary TEXT NOT NULL DEFAULT '';  -- the last summary, kept after finished_at is cleared

CREATE TABLE terminal_session_targets (            -- which targets a session's agent wrote to
    session_id INTEGER NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
    target_id  INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    first_at   TEXT NOT NULL,                       -- UTC ISO-8601 seconds
    last_at    TEXT NOT NULL,
    PRIMARY KEY (session_id, target_id)
);
CREATE INDEX idx_terminal_session_targets_target ON terminal_session_targets(target_id);

CREATE TABLE workbench_pr_states (                  -- Go-only cache of PR/branch state for reports
    project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    ref         TEXT NOT NULL,                      -- 'pr:<number>' or 'branch:<name>'
    state       TEXT NOT NULL CHECK(state IN ('merged','open','closed','none','unknown')),
    pr_number   INTEGER,                            -- set for a pr ref, and for a branch whose PR gh found
    title       TEXT NOT NULL DEFAULT '',
    additions   INTEGER,
    deletions   INTEGER,
    merged_at   TEXT NOT NULL DEFAULT '',
    checked_at  TEXT NOT NULL,
    PRIMARY KEY (project_id, ref)
);
-- +goose Down: drop both tables and both columns.
```

- Mirror the changes into `internal/db/schema.sql`, add both tables to `TestAllTablesExist`, and regenerate the golden and
  `TestDatabase+Schema.swift`.
- **Writers.** Go is the only writer of all four new things. The Desktop only reads them.
- **PROJ-02.** Deleting a workbench removes its sessions, and with them their link rows, plus its PR cache, through the
  cascades. `DeleteWorkbench`'s leftover test adds both tables.

## Part 3 — Recording what a session touched

- **Resolving the session.** `tools.terminalSessionOf` (`internal/tools/workbench_asks.go`) resolves the session from
  `WATCHTOWER_TERMINAL_SESSION_ID`. It accepts only a row of the same workbench. An unknown id, another workbench's id or
  no variable means "no session", and then nothing is recorded.
- **Link writes.** After a successful write, these tools upsert `(session, target)` with `last_at = now` (and
  `first_at = now` on insert):

  | Tool | Targets linked |
  |---|---|
  | `update_target` | the target |
  | `create_targets` | every created target |
  | `add_comment` | its `target_id`; for a reply, the root comment's target |
  | `ask_owner` | its `target_id` |
  | `finish_session` | its `target_id`, when given |

  The legacy tool spellings link exactly as the new ones do.
- **Failure handling.** The link write is best-effort, after the tool's own write. A failure is one stderr line plus
  `session_link_warning` in the tool result, and it never fails or undoes the tool. Read tools never link.
- **Session scope** (used by the report) = the session's own `target_id` subtree ∪ the linked targets ∪ the subtrees of
  linked targets that have children. Dismissed targets are excluded from every count.

## Part 4 — Finished: `finish_session` and the state rules

**MCP tool `finish_session`** (workbench sessions only; a write; DEV-06 classification "workbench write").

- **Params:**
  - `summary` (required): 1–600 runes after trim, at most 4 lines. It reads as the agent's last word to the owner.
  - `target_id` (optional): a target of this workbench.
  - `reason` (the registry's usual field).
- **Refusals**, each a `ValidationError`:
  - `summary: required`
  - `summary: at most 600 characters`
  - `summary: at most 4 lines`
  - `target_id: no target with id N in this workbench`
  - `finish_session needs a Watchtower terminal session` when no session resolves. An external terminal has no session to
    mark.
- **Effect:** one `UPDATE terminal_sessions SET finished_at = <now, ms>, finish_summary = <summary> WHERE id = <session>`,
  then the Part 3 link for `target_id`.
- **Result:** `{session_id, finished_at, open_asks: <count of this session's open asks>}`. Open asks are allowed: a session
  can be finished and still wait on the owner. The report shows both.
- **Repeat calls** overwrite both columns, so the newest summary wins.

**Clearing.** `db.SetTerminalAgentState` sets `finished_at = NULL` in the same `UPDATE` whenever it writes `working`
(`UserPromptSubmit`, or `PostToolUse` out of `approval`). `finish_summary` is kept, and the report shows it as "Previous
summary" while the session works again. No other write clears `finished_at`.

**Desktop dot state.** `SessionSwitcherPresentation.State` gains `finished`. The effective state (pure, Core) is decided in
this order:
1. A live row in `approval` → `needsApproval` (orange).
2. A live row in `working`, with `agent_state_at` later than `finished_at` (or `finished_at` NULL) → `working` (green).
3. `finished_at` set → `finished` (**blue**), live or not. Finished never needs a process run, so PROJ-11's run-scoping
   does not apply to it.
4. Otherwise, today's rules: `waitingForOwner` orange, `running` green, `notStarted` hollow.

The blue dot shows at every dot site (`SessionLiveDot`: panel row, switcher button and popover, Go to… palette).

**Notifications.** A transition into `finished` posts one notice, under the same conditions as PROJ-11's notices (app
inactive, workbench notifications on, quiet hours off): "<session> finished". The body is the first line of the summary,
and the identifier is the existing `workbench-session-<id>`, so a later state replaces it.

## Part 5 — The Stop reminder (ask guard prompt v2)

The ask guard Stop prompt (`devpack.askGuardPrompt`, marker `[watchtower-workbench ask-guard N]`) gets one more rule. The
full canonical text:

```
[watchtower-workbench ask-guard N]
You check a coding agent's final message of a turn.
Input (JSON): $ARGUMENTS
Return {"ok": true} when stop_hook_active is true.
Otherwise check two things, in this order, and return the FIRST failure:
1. Request left as text. If last_assistant_message clearly waits on the owner (a question to them, a decision they must
   make, something they must try or check by hand, a document they must read) and does not say it filed an ask (for
   example by naming "ask #<number>"), return {"ok": false, "reason": "You asked the owner in plain text. File it with
   ask_owner (kind question, check or review), name it as 'ask #<id>' in your text, then stop."}
   Rhetorical questions, questions the agent answers itself, summaries of finished work and offers such as "say if you
   want X" are NOT requests.
2. Finished without saying so. If last_assistant_message reports that the work of this session is complete (every task
   done, a PR opened or merged, or "nothing left for me to do here") and does not say it called finish_session (for
   example "session finished"), return {"ok": false, "reason": "Your work in this session looks complete. Call
   finish_session with a 2-3 line summary for the owner (what was done, the PRs, what is left on them), say 'session
   finished', then stop."}
   A progress report with work still left, a pause for an answer, or a partial result is NOT complete.
Otherwise return {"ok": true}. When unsure, return {"ok": true}.
```

- **Same guarantees as PROJ-13.** It passes on `stop_hook_active`, passes when unsure, and blocks at most once per stop.
  The skill tells the agent to write "session finished" once it has called the tool.
- **Upgrade.** `integrate`/`resync` replace our previous canonical text (the v1 golden of the owner-asks branch,
  recognised byte-exact after the marker number is substituted) with v2. An owner-edited prompt is kept and reported
  `drifted` (PROJ-04).
- **Goldens.** `goldenAskGuardPrompt7` becomes the v2 golden. The v1 text is kept as the upgrade fixture.

**Skill (`watchtower-workbench`, pack v3).** One new section, "Finishing a session":
- Call `finish_session` when the work this session was started for is done or handed to the owner. That means: tasks
  closed, the PR opened or merged, remaining owner work filed as asks.
- The summary is 2–3 lines: what landed (tickets, PR numbers), what is left on the owner (`ask #…`), and anything risky.
- After the call, write "session finished".
- Do not call it after every task, nor while work in this session's scope is still in progress.

## Part 6 — The report (`internal/sessionreport` + CLI)

**Package `internal/sessionreport`.**
- `Build(ctx, d *db.DB, projectID, sessionID int64, opts Options) (Report, error)` reads the DB and the PR cache only.
- `Refresh(ctx, d, projectID, refs []Ref, opts) RefreshResult` updates the PR cache.

**Report shape** (also the `--json` output; snake_case keys):

| Key | Contents |
|---|---|
| `session` | `id`, `title`, `target_id`, `kind`, `created_at`, `last_active_at`, `agent_state`, `agent_state_at`, `finished_at`, `finish_summary` |
| `progress` | `done`, `total`: leaves in scope; done = `done`, total excludes `dismissed` |
| `on_you` | this session's asks with status `open`: `id`, `kind`, `title`, `target_id`, `created_at`. Session-less asks never appear here |
| `now` | in-scope leaves `in_progress`/`in_review`/`blocked`: `id`, `text`, `status`, `branch`, `since` (from the latest `target_status_history` row) |
| `next` | the first 3 `todo` leaves in board order |
| `phases` | one per parent of in-scope leaves, in board order: `target_id`, `text`, `done`, `total` (all its non-dismissed leaf descendants, not only touched ones), `started_at` (earliest move to `in_progress` among them), `finished_at` (latest move to `done`, only when all done), `items` (the leaves, with status) |
| `prs` | the distinct PR refs and branches of in-scope targets: `ref`, `pr_number`, `title`, `state`, `additions`, `deletions`, `merged_at`, `checked_at`, `targets` (ids). A branch whose PR is known merges into that PR's entry |
| `pr_note` | why PR state may be incomplete (gh missing, no network, budget hit), or empty |

**Row summary** (`--summary`): for every `claude` session of the workbench, `session_id`, `target_id`, `done`, `total`,
`pr_line` and `finished_at`. `pr_line` is computed from the cache only: "PR #147 open", "2 PRs merged", "no PR yet", or
empty.

**PR state.** `Refresh` reuses `internal/workbenchcheck`'s readers and never re-implements them:
- **Branches:** the git merge detection (merge commit, fast-forward, cherry, squash patch id) through `gitbin`/`workbenchgit`.
- **PRs:** `gh` (`gh pr view <n> --json state,title,additions,deletions,mergedAt`, and `gh pr list --head <branch>
  --state all` for a branch with no known PR) when gh is present and network is allowed.
- **Budget:** 10 s overall. A ref not checked keeps its cached row. A ref never checked is `unknown`.
- **Cache freshness:** a ref is re-checked only when it is older than 60 s, or older than 10 min when its state is
  `merged`/`closed`.
- **Writes:** one upsert per ref, Go-only. Nothing is written to the board, so PROJ-07's drift check stays the only place
  that flags `merged_but_open`.

**CLI `watchtower workbench session-report --workbench N (--session S | --summary) [--json] [--no-network]`**
(`cmd/workbench_session_report.go`).
- `--session` runs `Refresh` for that session's refs (skipped with `--no-network`), then `Build`.
- `--summary` never refreshes.
- Exits non-zero only when the workbench or the session does not resolve. A git or gh failure goes into `pr_note`. The
  text form prints the Part 1 sections.
- Legacy `project session-report --project N` works through the existing aliases.

## Part 7 — Desktop

- **Core (`WatchtowerCore`):**
  - `SessionReport` and `SessionReportSummary`: Codable mirrors of Part 6. Older or extra keys decode with defaults.
  - `SessionReportPresentation`, pure: the hero line, the "Done" phase lines with time spans, the row caption
    "#314 · 14/15 · PR #147 open", "Previous summary" vs "Agent's last word", and the empty texts.
  - `SessionAgentStatus.effective` gains the Part 4 order. `SessionSwitcherPresentation.State.finished` and
    `SessionLiveDot` get the blue color, a system blue that works in light and dark.
- **`SessionReportCenter`** (Services, AppState-owned, so it survives navigation):
  - **Summary:** runs `workbench session-report --summary --json` once per workbench on screen, every 15 s while the
    Workbench tab is visible, and on app activation. Rows keep their last good value. A failure shows as a stale caption,
    never as a blank one.
  - **Full report:** runs `--session S --json` for the session whose Session view is on screen. It runs on show, every
    30 s while shown, and when the session's agent state changes.
  - **Concurrency:** at most one run in flight per workbench plus one queued rerun.
  - **Errors:** a failed run keeps the last report, marked stale with the error line.
- **Session view:**
  - **Placement:** a new `WorkspacePane.sessionReport(Int64)` (`WorkspaceView.report`, label "Session"), placed through
    `WorkbenchesViewModel.Placement` like the other views. A saved layout naming an unknown case still decodes to
    `.default`.
  - **Layout:** a column of at most 760 pt, sections in the Part 1 order.
  - **Actions:** **Open** on an ask opens the asks drawer for that ask (the #314 drawer). A PR row opens its GitHub URL
    in the browser (`NSWorkspace`), or does nothing when the URL is unknown. A target id opens it on the Board.
  - **Following the selection:** the view tracks the selected session. With no session it shows "Pick a session".
- **Panel rows:** the second line under the title, using the existing caption slot. The finished dot is blue. A
  standalone terminal gets no second line.
- **Toolbar and split:** Task 11, waiting for the owner's pick (Part 1, decision 1).

## Part 8 — Inventory

- **PROJ-11 (amended).**
  - *Observable* gains: "`finish_session` stores `finished_at`/`finish_summary`. Any `working` write clears `finished_at`
    in the same statement. The Desktop shows Finished (blue) from `finished_at` whether or not the session runs, below
    `needsApproval` and a `working` newer than `finished_at`."
  - New guards: `TestProj11_WorkingClearsFinished`, `testProj11_FinishedOutranksWaitingButNotApprovalOrNewerWork`.
- **PROJ-13 (amended).**
  - The ask guard prompt is the Part 5 v2 text. Pass on `stop_hook_active`, pass when unsure, one block per stop: all
    unchanged.
  - Guard: the golden test is updated, plus `TestProj13_V1PromptIsUpgradedEditedIsKept`.
- **PROJ-14 (new) — a session report shows only that session's work, and only the session itself says it finished.**
  - Link rows come only from that session's own workbench tools (a session resolved from
    `WATCHTOWER_TERMINAL_SESSION_ID` in the same workbench).
  - `finished_at` is written only by `finish_session` and cleared only by a `working` state write.
  - The report reads the DB and the PR cache, and never writes a target, a status or a comment.
  - Guards: `TestProj14_OnlyOwnSessionWritesLink`, `TestProj14_ReportNeverWritesTheBoard`,
    `TestProj14_FinishNeedsATerminalSession`.
- **PROJ-02:** the leftover test lists `terminal_session_targets` and `workbench_pr_states`.

## Part 9 — Non-goals and v1 limits

- **No backfill.** Sessions that ran before this ships have no link rows. Their report covers only their own `target_id`
  subtree, so #314 and #257 still look right because each was started on its ticket.
- **Best-effort links.** A failed link write loses that link; the tool result names it.
- **Owner's own changes.** Status changes the owner makes on the Desktop are not linked to any session. Targets the
  session already linked still show their new status.
- **PR state.** It needs gh for numbers, titles and sizes. Without gh only branch merge state is known, and PRs read
  `unknown`. The cache can lag by up to 60 s.
- **Other agents.** codex sessions get `finish_session` but no Stop reminder. External terminals cannot finish (refused).
- **Not in v1:** a cross-session overview, hand-marking finished, editing the summary, and reports for standalone
  terminals.
