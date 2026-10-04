# Workbench session report — design (2026-10-03)

**Board:** feature target #343 "Отчёт сессии: что сделано, PR, что на тебе; состояния сессии".
**Builds on:** owner asks (`docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md`, PR #147, in main) and
the session agent state (board #312, PR #142, PROJ-11).
**Revision 2 (2026-10-03, owner comment #206 + the states brainstorm):** one blue "finished" dot became a full set of
session states (Part 4). Owner picks: "waiting for you" means a real request only (1a); a turn that ends with no request
and no `finish_session` is its own grey **Stopped** state (2a); colour says whose move it is, the panel adds a glyph and a
caption (3a); approval, request, error, "working with a request open" and "finished with requests open" are all told
apart (4: all).
**Revision 3 (implementation rulings, 2026-10-03), reflected in the parts named:**
- **Part 1, decision 1 — toolbar.** The owner picked (ask #5) a separate **Session** view button in the page header,
  between **Terminal ▾** and **Board** (`Terminal ▾ | Session | Board | Files | split | ⋯`). The button pairs the report
  with its session's terminal: from a single pane it makes the page a split of that session's terminal and its report; a
  split already showing that terminal swaps its other pane for the report. It reports on the session on screen, else the
  active one, else the first listed `claude` session (none: nothing happens), and starts nothing. In a split a panel
  click never replaces the report: the clicked session takes the other slot and the report follows it.
- **Part 1/4b — "Not running · <age>".** A not-started session keeps the age it showed before ("Not running · 5m") in
  the panel rows and the switcher popover; the age helps pick a session. Owner-confirmed (ask #18). The failed caption
  shows the stored error type as words, its underscores as spaces ("Error: rate limit" for `rate_limit`); the stored
  value stays as Claude Code sends it.
- **Part 4 — errors.** The StopFailure payload carries the error type in the top-level `error` field (for example
  `"rate_limit"`; pinned by `cmd/testdata/stopfailure_rate_limit.json`). A `waiting` write with no failure (the
  `idle_prompt` notice, the Stop hook) over a stored failed `waiting` is a no-op, so the error stays until the owner
  acts: it clears only on a `working` or `approval` write or the SessionStart clear of a new run. Claude Code does not
  run the Stop hooks alongside a StopFailure (verified live on Claude Code 2.1.288). A repeated StopFailure with the
  same error is a no-op (the first time is kept); one with a different error replaces the stored error and its
  `agent_failed_at`/`agent_state_at`.
- **Part 4 — Finished clearing.** Any write that changes the state into `working` clears `finished_at`: a
  UserPromptSubmit, or a PostToolUse out of `waiting` or `approval` (a turn the agent started itself is a new turn). A
  `working` over a stored `working` clears it only for a UserPromptSubmit (finish, an Esc interrupt that fires no hook,
  then a new prompt), never for a PostToolUse: that is the `finish_session` turn itself, and a main-thread PostToolUse
  that records `working` from any state must not clear the blue. `SetTerminalAgentState` and the hook precheck take a
  `prompt` flag. A plain `working` repeat on an unfinished row stays a no-op. Guards
  `TestProj11_WorkingOverWorkingClearsFinished`, `TestProj11_ToolRunWorkingOverWorkingKeepsFinished` /
  `TestProj11_PostToolUseOverWorkingKeepsFinished` and `TestProj11_ToolRunOutOfWaitingClearsFinished` /
  `TestProj11_PostToolUseIntoWorkingClearsFinished` (db / hook halves).
- **Part 4b — the Finished notice.** Its body is "N asks waiting for you" while asks are open, else the summary's first
  line (the workbench name when the summary is empty).
- **Part 5 — upgrade.** "An owner-edited prompt is kept and reported `drifted`" conflicted with the locked PROJ-04 (our
  edited marker prompt is set back in place, guard `TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks`).
  Every prompt entry carrying our marker, the v1 text or an edit of it, is set to v2; PROJ-04 is unchanged.
  Owner-confirmed (ask #18). The PROJ-13 guard is `TestProj13_V1PromptIsUpgradedToV2`.
- **Part 6 — phases.** The session's own target is a phase only when it is flat (leaves only). With sub-parents, its
  phase would repeat the report's X/Y, so its direct leaves count in `progress`, `now` and `next` only.
- **Part 6 — untouched groups (amendment 2026-10-04, board #393).** Creating a target or moving it under a group links
  it, so a group the session only filed showed under "Done" as 0/N with a dashed circle. A parent is a phase only when
  at least one of its in-scope leaves moved past todo (its status is neither todo nor snoozed, or it ever went to
  `in_progress` or `done`); otherwise its first todo leaves show in `next` only (capped at 3). v1 limit: the history is
  the leaf's whole history, not this session's, so a group that only received a leaf finished earlier by another
  session still reads as a phase with that work.
- **Part 6 — API.** PR-cache refs are strings (`pr:<n>` | `branch:<name>`): `SessionRefs(ctx, d, projectID, sessionID)
  ([]string, error)` and `Refresh(ctx, d, projectID, refs []string, RefreshOptions{Network, Budget, Now})
  RefreshResult`.
- **Part 6 — merged without gh.** Without gh, git can only upgrade a cached row to `merged`, and the row keeps the PR
  fields gh gave earlier: a PR gh saw closed on a branch that later merges reads "PR #N merged".
  Owner-confirmed (ask #18).
- **Part 6 — `--no-network`.** It makes the refresh offline (local git merge detection only, gh never runs), not a
  skipped refresh.
- **Part 7 — PR links.** The Desktop derives a PR's URL from the workbench folder's git `origin` remote (GitHub https
  and ssh forms, `GitHubRemote`) plus `/pull/<n>`, read once per workbench. With an unknown remote the row is not a
  link. No cache column, no golden change.
- **Part 7 — refresh on return (Fix B).** A Session view left mounted in a hidden, covered or backgrounded window does
  not disappear, so its 30 s ticks run nothing there. `SessionReportCenter` watches app activation and
  `NSWindow.didChangeOcclusionStateNotification`: a shown report that comes back on screen runs at once instead of at
  the next tick. A tab switch is covered by the view's own appear.
- **Part 7 — panel row.** The mini progress bar (done/total) sits before the report line's text, not between the ticket
  and X/Y: the line is one string.
- **Part 7 — unknown branch.** A branch whose state is not known reads "not checked" on the Desktop (not "unknown (no PR
  yet)"). The Go CLI's text form says the same: a never-checked branch reads "<branch> not checked", an open one
  "<branch> open (no PR yet)" and a closed one "<branch> closed (no PR yet)". A branch gh checked and found no PR for
  (`none`) reads "no PR yet" everywhere: the Desktop's PR row, the CLI ("<branch> no PR yet") and `pr_line`; only
  `unknown` reads "not checked".
**Plan:** `docs/superpowers/plans/2026-10-03-workbench-session-report.md`.
**Design mock:** the brainstorm screen "session-report" of 2026-10-03, built on the live data of sessions #314
(finished) and #257 (working).

Part 1 is the one-page owner spec. Parts 2–9 are the technical spec: decisions and contracts for the implementing
sessions. Every UI string ships in English (the owner's standing rule); the Russian words in Part 1 are the
conversation's names, with the shipped label next to them.

---

## Part 1 — For the owner (one page)

**Problem.** You wake up to several sessions and each one is a wall of terminal text. You cannot see what a session
did, how far it got, which PRs were merged, or what is left on you. With many sessions this gets very hard.

**What you will see.**
- **A Session view next to the terminal**, where the Documents pane used to be. It shows the selected session's report:
  - **State and size.** A state badge (one of the Part 4 states, with its glyph and caption), the session's ticket, how long
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
- **Session states you can tell apart at a glance.** The colour says whose move it is; the panel row, the header switcher
  and the report add a glyph and a caption:

  | State | Colour | Glyph | Caption (shipped) | Notice |
  |---|---|---|---|---|
  | Working | green | — | Working | — |
  | Working, a request is open | green | ? + count | Working · 2 asks open | (the ask's own notice) |
  | Waiting for your answer | orange | ? | Waiting for you · ask #12 | (the ask's own notice) |
  | Needs approval in the terminal | orange | hand | Needs approval | yes |
  | Finished, requests still open | orange | ✓ | Finished · 1 ask open | "finished" |
  | Stopped (turn over, nothing asked, not finished) | grey | pause | Stopped | "stopped" |
  | Finished | blue | ✓ | Finished | "finished" + summary line |
  | Error (rate limit, API error) | red | ! | Error: rate limit | yes |
  | Running (just started, nothing reported yet) | green | — | Running | — |
  | Not started | hollow grey | — | Not running | — |

  A filled dot means the process runs, a ring in the same colour means it does not: a finished session closed later
  shows a blue ring, a closed session with an open ask an orange ring. A new prompt turns any of them green again.
  **"Waiting for you" now means a real request** — an open ask or a permission dialog — not every end of a turn.
- **The agent says when it is done.** It calls a new tool with a short summary. If it stops with its work done and does
  not call the tool, the end-of-turn check reminds it.

**Decisions for you (recommendations marked).**
1. **The header toolbar** (Terminal ▾ / Board / Session / Files / split / ⋯). *Decided by the owner (ask #5):* a separate
   **Session** view button between **Terminal ▾** and **Board** (plan Task 11).
2. **Amend PROJ-11** (session state hooks) to the Part 4 state set: the stored `waiting` now means "turn over" (shown
   Stopped, grey), "waiting for you" comes only from open asks and approval, StopFailure records an error, Finished comes
   from `finish_session`, and every `working` write clears both. PROJ-11's run-scoping holds for the hook states.
   *Decided by the owner in the brainstorm (1a, 2a, 3a, 4 all); this is the inventory change that records it.*
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
- A session that calls `finish_session` turns blue with its summary; with an open ask it stays orange with ✓.
- A turn that ends with no ask and no `finish_session` shows grey Stopped, not orange.
- An open ask turns the session orange (?) once the agent stops, green with "? N" while it keeps working.
- A rate-limit or API failure at the end of a turn shows red with the error.
- An agent that finishes calls `finish_session`, or is reminded once to call it.
- A new prompt turns a blue session green.
- Rows show X/Y and the PR state without opening the session.

---

## Part 2 — Data (migration `00101_workbench_session_report.sql`)

The number follows `00100_owner_asks` (in main). If main takes `00101` first, the migration is renumbered at merge
(check the tables exist, not the goose version).

```sql
-- +goose Up
ALTER TABLE terminal_sessions ADD COLUMN finished_at    TEXT;              -- UTC ISO-8601 with ms (agent_state_at format); NULL = not finished
ALTER TABLE terminal_sessions ADD COLUMN finish_summary TEXT NOT NULL DEFAULT '';  -- the last summary, kept after finished_at is cleared
ALTER TABLE terminal_sessions ADD COLUMN agent_failed_at TEXT;             -- = agent_state_at of the StopFailure write that set it; NULL = no error
ALTER TABLE terminal_sessions ADD COLUMN agent_error    TEXT NOT NULL DEFAULT '';  -- the StopFailure error type, clipped to 60 runes; '' = unknown

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
-- +goose Down: drop both tables and the four columns.
```

- Mirror the changes into `internal/db/schema.sql`, add both tables to `TestAllTablesExist`, and regenerate the golden and
  `TestDatabase+Schema.swift`.
- **Why two error columns and not a new `agent_state` value.** `agent_state` carries a column-level
  `CHECK (agent_state IN ('working','waiting','approval'))` (migration `00098`); widening it means rebuilding
  `terminal_sessions`. An error is a turn that ended (`waiting`) plus a flag, like `finished_at`, so it needs no rebuild.
- **Writers.** Go is the only writer of every new column and table. The Desktop only reads them.
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
(`UserPromptSubmit`, or `PostToolUse` out of `approval`), also over a stored `working` while `finished_at` is set
(Revision 3). `finish_summary` is kept, and the report shows it as "Previous
summary" while the session works again. No other write clears `finished_at`.

**Errors (StopFailure).** `agentStateFor` keeps mapping `StopFailure` to `waiting`, and the hook now passes a failure:
`agent_failed_at = <the event time>` and `agent_error = <the payload's error type>`. Every other state write that lands sets
`agent_failed_at = NULL, agent_error = ''` in the same statement. The guard "a different state" becomes "a different
state, or a failure landing on a plain state or on one with another error", so a StopFailure after a `waiting` still lands, while a plain `waiting`
(`idle_prompt`, the Stop hook) over a failed one writes nothing: the error clears only on a `working` or `approval` write
or the SessionStart clear (Revision 3). The "event time later than the stored one" guard is unchanged. The payload field
is the top-level `error` (for example `"rate_limit"`), pinned by `cmd/testdata/stopfailure_rate_limit.json`; a missing or
non-string field stores `''`, and the caption then reads "Stopped on an error". The value is clipped to 60 runes and passed through `asks.OneLine`.

### Part 4b — The session state model

**Inputs**, all per `claude` session row:
- `live`: the process runs (`TerminalCenter`).
- `hook`: PROJ-11's trusted state — `working`, `waiting`, `approval`, or none — trusted only while live and
  `agent_state_at ≥ startedAt` (unchanged run-scoping). `failed` = trusted `waiting` with
  `agent_failed_at = agent_state_at`.
- `finished`: `finished_at` is set (not run-scoped; any `working` write clears it).
- `openAsks`: the count of this session's `owner_asks` with `status = 'open'` (session-bound asks only).

**Kinds** (`SessionSwitcherPresentation.State` becomes a struct `{kind, live, openAsks, error}`; `kind` is one of
`notStarted`, `running`, `working`, `needsApproval`, `failed`, `waitingOnAsk`, `stopped`, `finished`), decided in this
order — the first match wins:

1. live ∧ `hook = approval` → `needsApproval`.
2. live ∧ `failed` → `failed`.
3. live ∧ `hook = working` → `working`.
4. `finished` → `finished`, live or not.
5. `openAsks > 0` → `waitingOnAsk`, live or not (the answer reaches a closed session through the brief, so it is still
   the owner's move).
6. live ∧ `hook = waiting` → `stopped`.
7. live → `running` (no state reported in this run yet).
8. otherwise → `notStarted`.

**Colour and glyph** (pure, `SessionStatePresentation` in Core):

| Kind | Colour | Glyph (SF Symbol) | Caption |
|---|---|---|---|
| `working`, `openAsks = 0` | green | — | Working |
| `working`, `openAsks > 0` | green | `questionmark` + count | Working · N ask(s) open |
| `waitingOnAsk` | orange | `questionmark` | Waiting for you · ask #<oldest open id> (· N asks when more than one) |
| `needsApproval` | orange | `hand.raised.fill` | Needs approval |
| `finished`, `openAsks > 0` | orange | `checkmark` | Finished · N ask(s) open |
| `stopped` | grey (`.secondary`) | `pause.fill` | Stopped |
| `finished`, `openAsks = 0` | blue (system blue) | `checkmark` | Finished |
| `failed` | red | `exclamationmark` | Error: <agent_error> / Stopped on an error |
| `running` | green | — | Running |
| `notStarted` | grey ring | — | Not running |

- **Fill vs ring.** `live` fills the dot; a not-live session draws a ring in its kind's colour (blue ring = finished and
  closed, orange ring = closed with an open ask, grey ring = not running).
- **Sites.** `SessionLiveDot` takes the struct everywhere. The glyph and caption show where there is room: the panel row
  (the caption slot under the title, before the report's X/Y line), the header switcher button and its popover rows,
  and the report badge. The Go to… palette shows the dot only. Every site sets the caption as the accessibility label.
- **Not a session state.** The sidebar rail's dot (`railDotColor`, a blue count badge) is unchanged and unrelated: it
  counts open asks plus unread comments, not a session's state.

**Data path.** `TerminalSessionQueries.fetchAgentStates` also reads `finished_at`, `agent_failed_at`, `agent_error` and
`(SELECT COUNT(*) FROM owner_asks a WHERE a.session_id = ts.id AND a.status = 'open')` for the workbench's `claude` rows,
live or not. `SessionAgentStateCenter` keeps its 1 s poll while a live `claude` session exists, and also refreshes on app
activation, when the Workbench tab appears, and right after `OwnerAsksViewModel` answers an ask (the count drops) — a
not-live row changes in no other way. It publishes only on change, as today.

**Notifications** (`SessionAgentNoticePolicy`, same conditions as PROJ-11: app inactive, workbench notifications on,
quiet hours off; identifier `workbench-session-<id>`, so a newer state replaces it):
- into `needsApproval`: "<session> needs approval" (unchanged);
- into `failed`: "<session> hit an error", body the caption;
- into `stopped`: "<session> stopped" (replaces today's "is waiting for you" on a turn end);
- into `finished`: "<session> finished", body "N asks waiting for you" when asks are open, else the summary's first line;
- into `waitingOnAsk` or `working` with asks: no state notice — `WorkbenchNotificationPolicy.askOpened` already
  announced the ask;
- back to `working`, or not live: the notice is withdrawn (unchanged).

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
  recognised byte-exact after the marker number is substituted) with v2. An edited prompt carrying our marker is set to
  v2 as well, as PROJ-04 already sets our edited prompt back (Revision 3).
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
- `Refresh(ctx, d, projectID, refs []string, opts RefreshOptions) RefreshResult` updates the PR cache; refs are
  `pr:<n>` | `branch:<name>` strings, listed by `SessionRefs`.

**Report shape** (also the `--json` output; snake_case keys):

| Key | Contents |
|---|---|
| `session` | `id`, `title`, `target_id`, `kind`, `created_at`, `last_active_at`, `agent_state`, `agent_state_at`, `finished_at`, `finish_summary` |
| `progress` | `done`, `total`: leaves in scope; done = `done`, total excludes `dismissed` |
| `on_you` | this session's asks with status `open`: `id`, `kind`, `title`, `target_id`, `created_at`. Session-less asks never appear here |
| `now` | in-scope leaves `in_progress`/`in_review`/`blocked`: `id`, `text`, `status`, `branch`, `since` (from the latest `target_status_history` row) |
| `next` | the first 3 `todo` leaves in board order |
| `phases` | one per parent of in-scope leaves that moved past todo (a leaf neither todo nor snoozed, or with an `in_progress`/`done` history row; amendment 2026-10-04, board #393), in board order (the session's own target only when it is flat, Revision 3): `target_id`, `text`, `done`, `total` (all its non-dismissed leaf descendants, not only touched ones), `started_at` (earliest move to `in_progress` among them), `finished_at` (latest move to `done`, only when all done), `items` (the leaves, with status) |
| `prs` | the distinct PR refs and branches of in-scope targets: `ref`, `pr_number`, `title`, `state`, `additions`, `deletions`, `merged_at`, `checked_at`, `targets` (ids). A branch whose PR is known merges into that PR's entry |
| `pr_note` | why PR state may be incomplete (gh missing, no network, budget hit), or empty |

**Row summary** (`--summary`): for every `claude` session of the workbench, `session_id`, `target_id`, `done`, `total`,
`pr_line` and `finished_at`. `pr_line` is computed from the cache only: "PR #147 open", "2 PRs merged", "no PR yet", "not checked" (only a
never-checked branch carries done work, as the Desktop's PR rows say), or empty.

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
- `--session` runs `Refresh` for that session's refs (offline with `--no-network`: local git only, never gh), then
  `Build`.
- `--summary` never refreshes.
- Exits non-zero only when the workbench or the session does not resolve. A git or gh failure goes into `pr_note`. The
  text form prints the Part 1 sections.
- Legacy `project session-report --project N` works through the existing aliases.

## Part 7 — Desktop

- **Core (`WatchtowerCore`):**
  - `SessionReport` and `SessionReportSummary`: Codable mirrors of Part 6. Older or extra keys decode with defaults.
  - `SessionReportPresentation`, pure: the hero line, the "Done" phase lines with time spans, the row caption
    "#314 · 14/15 · PR #147 open", "Previous summary" vs "Agent's last word", and the empty texts.
  - `SessionAgentStatus.effective` becomes the Part 4b order over the four inputs; `SessionSwitcherPresentation.State`
    becomes the Part 4b struct and `SessionStatePresentation` maps it to colour, glyph, fill/ring and caption (system
    colours, light and dark).
- **`SessionReportCenter`** (Services, AppState-owned, so it survives navigation):
  - **Summary:** runs `workbench session-report --summary --json` once per workbench on screen, every 15 s while the
    Workbench tab is visible, and on app activation. Rows keep their last good value. A failure shows as a stale caption,
    never as a blank one.
  - **Full report:** runs `--session S --json` for the session whose Session view is on screen. It runs on show, every
    30 s while shown and the tab is on screen, at once when it comes back on screen (Revision 3), and when the
    session's agent state changes.
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
- **Panel rows:** the state caption with its glyph (Part 4b) in the existing caption slot, then the report line
  (a mini progress bar, then "#314 · 14/15 · PR #147 open"). A standalone terminal gets neither.
- **Toolbar and split:** Task 11, a separate **Session** button between **Terminal ▾** and **Board** that pairs the
  report with its session's terminal (Part 1, decision 1; Revision 3).
- **PR links:** derived from the folder's git `origin` (GitHub https/ssh) plus `/pull/<n>`; an unknown remote leaves the
  row unlinked. An unknown branch state reads "not checked".

## Part 8 — Inventory

- **PROJ-11 (amended, owner-approved in the 2026-10-03 brainstorm).**
  - *Observable* becomes: "The stored `waiting` means the turn is over and shows **Stopped** (grey), never 'waiting for
    you'. 'Waiting for you' (orange) comes only from an open ask of the session or a permission dialog. A StopFailure
    stores `agent_failed_at`/`agent_error` with `waiting` and shows **Error** (red). `finish_session` stores
    `finished_at`/`finish_summary` and shows **Finished** (blue, orange while the session has open asks) whether or not
    the session runs. Any `working` write clears `finished_at` and the error in the same statement; an `approval` write
    and the SessionStart clear also clear the error, and a plain `waiting` over a failed one writes nothing. The order is
    Part 4b's; the hook states stay run-scoped."
  - Existing guards that assert `waiting` → `waitingForOwner` (orange) are rewritten to `stopped` (grey) — the intended
    change, not a relaxation; the "a dead run's state never shows" assertions stay as they are.
  - New guards: `TestProj11_WorkingClearsFinishedAndError`, `TestProj11_StopFailureRecordsErrorOtherWritesClearIt`,
    `testProj11_StateOrder` (a table over the eight kinds: approval > error > working > finished > open ask > stopped >
    running > not started), `testProj11_TurnEndWithoutAskIsStoppedNotWaiting`.
- **PROJ-13 (amended).**
  - The ask guard prompt is the Part 5 v2 text. Pass on `stop_hook_active`, pass when unsure, one block per stop: all
    unchanged.
  - Guard: the golden test is updated, plus `TestProj13_V1PromptIsUpgradedToV2` (the v1 text and an edit of it both
    become v2; PROJ-04 unchanged, Revision 3).
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
- **Other agents.** codex sessions get `finish_session` but no Stop reminder and no state hooks (their dot shows only
  Finished, open asks, Running or Not running). External terminals cannot finish (refused).
- **States not seen.** An Esc/Ctrl+C interrupt fires no hook, so the session reads Working until the next prompt
  (unchanged from PROJ-11). A freshly started session reads Running (green) until its first prompt, though the agent is
  idle. A StopFailure from a Claude Code that sends no error type reads "Stopped on an error".
- **Not in v1:** a cross-session overview, hand-marking finished, editing the summary, and reports for standalone
  terminals.
