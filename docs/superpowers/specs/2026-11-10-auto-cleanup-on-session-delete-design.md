# Automatic cleanup when a session is deleted

**Board:** #1716 · **Date:** 2026-11-10 · **Mockup:** `docs/design/mockups/session-auto-cleanup/states.html`
**Builds on:** session cleanup (board #535, PROJ-18; `docs/superpowers/specs/2026-10-12-session-cleanup-design.md`), Clean Up screen (#1107), session placement (#229), sessions panel (PROJ-17).

## Why

The disk is running out. One workbench repository has about 400 local branches and 190 linked worktrees. Half of the branches are already merged into the default branch, and 21 worktrees are prunable. The session cleanup exists, but two things keep it from working:

1. **It runs only when the owner asks.** A quick delete (✕, ⌘⌫) and the dialog's **Delete Only** remove nothing. Only **Delete and Clean Up** cleans, and the owner has to choose it every time.
2. **It does not see most of what a session creates.** A session owns only the worktrees its hooks saw as an agent's `cwd`, plus its targets' branches. Plan runs fan tasks out to subagent lanes: `git worktree add <scratchpad>/<lane> -b <branch>` under `/private/tmp/claude-<uid>/<project-slug>/<claude-session-uuid>/scratchpad/` or `/private/tmp/watchtower-<n>`. The subagents work there through `git -C` or `cd` inside a Bash call, so no hook event carries that `cwd`. The cleanup keeps those worktrees as `not_this_session`, and they pile up.

## Goal

Deleting a session from the Desktop always removes, in the background, everything the session created that is safe to remove. The owner does nothing extra. Whatever could not be removed keeps the session in the list, marked **Not fully cleaned**.

## Non-goals

- **The existing pile.** The owner clears it once by hand on the Clean Up screen (**Select All That Can Go**). There is no periodic sweep and no daemon phase (ask #1205).
- **Remote branches.** Nothing is ever deleted on `origin`. Fetching stays the agent's or the owner's job, as before.
- **A workbench delete.** It keeps today's behaviour (placed sessions only); its rows are gone by cascade, so there is no row to mark.
- **AI judgement.** No model decides what to remove. The rules below are deterministic, and PROJ-18's safety catches stay as they are.

## Anti-goals

- Removing anything with uncommitted changes, unpushed commits, a running process, or another live session in it. This is PROJ-18 as today, unchanged.
- Removing what another session or the owner created. Ownership stays fail-closed: when in doubt, keep it.
- Slowing the hooks. Hook events have 500 ms to 1 s of database budget. Parsing a command string costs microseconds; a git run in the hook is forbidden.

## 1. Trigger: every delete cleans

Every Desktop session delete (✕, ⌘⌫ and the dialog) goes through `WorkbenchesViewModel.delete`, as PROJ-17 says. What changes is what happens when the Undo window ends.

1. **Inside the Undo window**, nothing changes: the row is hidden, the terminal closes, nothing is written, and Undo brings the row back.
2. **When the window ends**, the row is not deleted at once. The Desktop writes `terminal_sessions.delete_requested_at = now` (new column, Desktop-only writer) and queues a **background cleanup** of the row.
3. **The background cleanup** runs `watchtower workbench cleanup --session N --workbench W --live-session … --apply --json`. There is no `--item`: the CLI re-plans and removes everything that is `remove` now. It also removes the row's orphan processes and LaunchServices entries, as a session cleanup already does.
4. **The outcome decides the row** (§3):
   - **clean**: the row is deleted (`TerminalSessionQueries.delete`; the cascades of today), and a quiet notice appears;
   - **not fully cleaned**: the row comes back into the list with the mark and stays until the owner acts.

**Time limit.** A background run is stopped after 10 minutes: its process group gets SIGTERM, then SIGKILL after 5 s, and the outcome is **could not** ("the cleanup took longer than 10 minutes"). The workbench slot is freed when the process has been reaped. Items removed before the stop stay removed. The next run re-plans, as in §4.

**One at a time per workbench.** Background cleanups of one workbench run one after another, in the order they were requested. They share the existing per-workbench slot, so a Clean Up screen apply or a placed-session cleanup waits for the slot and is not refused. Different workbenches run in parallel.

**The delete dialog** (for a live row) loses its cleanup plan and its **Delete Only** / **Delete and Clean Up** choice. It becomes a plain confirmation: "Delete “T”? Its terminal stops. Worktrees and branches it created that are merged or pushed are removed in the background." The buttons are **Delete** (destructive, `kitDestructive`) and **Cancel**. The dialog no longer starts a plan on open.

**The natural-exit cleanup of a placed session** (#229) stays as it is. It runs earlier, while the row is still in the list, and only for the row's own worktree.

## 2. Ownership: the session sees what its agents created

Two new sources feed the `observed` set of `internal/sessioncleanup` (`observe`, `ownership.go`). Every catch and birth rule applies to them as to a ledger row: born after the session started, merged or pushed, clean, and not in use.

### 2a. Commands the agents ran (hook)

The session-state hook already gets `tool_name` and `tool_input` on PostToolUse, for the main agent and for subagents, and also for Codex (`sessionagent.Event`). For a successful `Bash` call (Codex: its shell tool), it parses the command text, with no git run:

| Command (any position in a `&&`/`;`/`|` chain, after `cd X &&` or `git -C X`) | Records |
|---|---|
| `git worktree add [opts] <path> [<commit-ish>]`, opts incl. `-b`/`-B <branch>` | worktree `<path>` (resolved against the effective directory) and `<branch>` if given |
| `git branch [opts] <name> [<start>]` (not `-d`/`-D`/`-m`/`-l`/`--list`/`--show-current`, …) | branch `<name>` |
| `git checkout -b/-B <name>`, `git switch -c/-C <name>` | branch `<name>` |

- The effective directory is the hook's `cwd`, changed by a leading `cd <dir> &&` and by `git -C <dir>`.
- A worktree path is recorded only when, after the call, `<path>/.git` is a file (a stat, not git). This keeps typos and failed commands out.
- Rows land in `terminal_session_worktrees` with a new `source` column: `cwd` (today's rows) or `command`. They also get a `kind`: `worktree` for a root with its branch, or `branch` for a branch-only row, whose `root` is the effective repository's top level.
- **The cap**: `cwd` rows keep today's 64. `command` rows get their own cap of 512 per session; past it, one stderr line per run, as today.
- The parser is a pure Go function with a table test. A command it cannot parse records nothing. Quoting is handled the way `sh` would split words; command substitution and variables are not expanded, and a word holding `$` or a backtick is skipped.

**Trust.** A branch or worktree an agent named in a command counts as *named* (like a target's branch, `observed.named`). That is stronger than a ledger branch: a worktree with a named branch checked out is observed. Birth time still has to fall after the session started (`ReasonExistedBeforeSession` / `ReasonCreatedUnknown` unchanged). So a command that names a branch someone else made earlier does not make it the session's.

### 2b. The session's Claude scratchpad

A linked worktree whose root lies under `<TMPDIR>/claude-<uid>/<any slug>/<claude-session-uuid>/` belongs to the session, if the uuid is one of the row's agent session ids (`terminal_session_agent_sessions`, migration 00127, every id the row has had) **and no other `terminal_sessions` row has that uuid**. "Has" means the uuid appears in the other row's history in `terminal_session_agent_sessions` (any id it ever had, not only its current `claude_session_id`), or in its current `claude_session_id`. A uuid shared by two rows (a conversation resumed in another tab) adopts nothing for either of them, which is fail-closed; the ledger and command sources still apply. This catches lanes made before the hook change shipped and commands the parser missed. The `TMPDIR` root is read from the environment of the process that plans (`os.TempDir()`, symlink-resolved, since `/tmp` → `/private/tmp`). Codex rows have no such directory; this rule does not apply to them.

### What stays unseen

Worktrees outside both sources (for example `/private/tmp/watchtower-<n>` made by a script the agent ran rather than a literal command) are still `not_this_session`. The owner removes them on the Clean Up screen.

## 3. Outcome: clean or not fully cleaned

The apply's `Result` sorts each item into one of three groups.

| Item | Group | Effect on the row |
|---|---|---|
| `done` (removed) | removed | — |
| kept for **the owner's work**: `uncommitted_changes`, `unpushed_commits`, `operation_in_progress`, `locked`, `contains_worktree` | kept on purpose | none: the row is deleted; the notice names them |
| kept for **not ours / not the session's**: `not_this_session`, `existed_before_session`, `created_unknown`, `main_folder`, `workbench_folder`, `claude_home`, `default_branch`, `checked_out` (in a worktree that is not the session's) | not ours | none, and not shown |
| **could not**: an item with `error`, or kept for `git_refused`, `moved`, `process_running`, `process_unknown`, `session_in_it`, `check_failed`, `bundle_unreadable`, `not_attempted`; or the run failed as a whole (exit ≠ 0, no JSON, timeout) | could not | the row stays, **Not fully cleaned** |

The table is one pure function in WatchtowerCore (`SessionAutoCleanupOutcome`). Every reason code is listed, and a test fails when Go adds a reason code the table does not place. An unknown code counts as **could not**, which is fail-safe.

**Clean** (no "could not" item): the row is deleted and a notice appears on the Undo bar's place for 6 s. The text, built in the model:
- `Cleaned up “T”: removed 3 worktrees and 12 branches (~2.1 GB).`
- with kept items: `Cleaned up “T”: removed 2 worktrees (~1.4 GB). Kept 1 branch — unpushed commits.`
- nothing to remove: no notice (the row simply goes).

Several deletes in a row join into one notice: `Cleaned up 4 sessions: removed …`.

**Not fully cleaned**: the row comes back into the finished group with a warning line instead of its summary: `Not fully cleaned: 1 worktree — a process is running in it.` It has three actions, shown on hover as plain row buttons, none of them prominent (style guide: one prominent action per screen):
- **Clean Up Again**: the same background cleanup; on success the row goes.
- **Delete Anyway**: deletes the row now. The files stay on disk, and the Clean Up screen still lists them in a sweep.
- **Show in Clean Up**: opens the Clean Up screen scoped to this session.

The row stays out of the ⌘1…⌘9 numbering and out of any live list. Opening it shows its report as for any finished session, with the Cleanup section filled from `cleanup_result`.

While a background cleanup runs, the row is hidden (it is still in the deleting state). The workbench's sessions panel header shows `Cleaning up 2 sessions…` until the queue is empty. There is no spinner on a row the owner already deleted.

## 4. Failure paths and writers

| Event | What happens |
|---|---|
| The app quits inside the Undo window | Today the rows are deleted at quit. Now they get `delete_requested_at` at quit (one short write transaction), and the cleanup runs at the next launch (below). |
| The app quits or crashes during a cleanup | `delete_requested_at` is set, and the row is still there. At launch, after `initWorkbenches`, every row with `delete_requested_at` and no live terminal is queued again. The apply re-plans from scratch, so a half-done run continues where git left it; an already removed item is no longer listed. |
| The launch re-queue fails again | It is the same "could not" outcome: the row shows **Not fully cleaned**. No retry loop: one attempt per launch, plus **Clean Up Again**. |
| The CLI binary is missing or too old (no `--apply` JSON) | The run failed as a whole, so it is **could not**. The row shows the CLI error text. |
| Undo pressed after the window ended | Not possible: the Undo bar is gone when the window ends, as today. |
| The owner reopens a Not-fully-cleaned row (Resume) | Resume clears `delete_requested_at`, and the row is an ordinary finished session again. |

**Writers of the same data:**
- `delete_requested_at`: the Desktop only. It is set at window end or quit, and cleared by Resume, Delete Anyway (the row goes) and the clean outcome (the row goes).
- `terminal_session_worktrees`: the Go hooks only (both sources). The row delete cascades it.
- `cleanup_result`/`cleanup_at`: the Go apply only, as today.
- **Removing the files**: the background cleanup, the agent's own `workbench cleanup --apply` before `finish_session`, the placed natural-exit cleanup, and a Clean Up screen apply. They do not race on one item: every apply re-plans, checks each tip just before it deletes (compare-and-delete, `moved`), and git's own refusals stop a double removal. A loser sees the item gone, and a gone item is not listed, so it is not a failure. The Desktop runs at most one apply per workbench at a time (§1). The agent's own apply is the one writer outside that slot: its race ends in `moved` or a gone item, never in a wrong removal.
- **The phone** has no session delete. What it sees is covered under readers below.

**Readers of a row being deleted.** A row with `delete_requested_at` set is deleted as far as the owner is concerned. It is visible only in the Desktop's finished group, and only once it is **Not fully cleaned**. The readers split in two:
- **Lists hide it** (`AND delete_requested_at IS NULL`):
  - Desktop: the workbench session list queries (`TerminalSessionQueries` list reads), except the read that loads Not-fully-cleaned rows for the finished group;
  - the Swift mobile hub slices that list sessions;
  - Go: `internal/hub/slices/sources/terminal_session.go`, `timeline.go`, `workbench.go`, `target.go`, `internal/hub/lane.go`, `db/terminal_sessions_recent.go`, `sessionstate/status.go` (the workbench status rollup);
  - the brief's session lines (`cmd/workbench_session.go`).
  - **Session start (`internal/sessionstart/start.go`)**:
    - `latestTargetSession` never picks a deleting row, so a target's Start or Reopen opens or creates another session;
    - the scan of the workbench's other sessions (placement: is a live agent in the folder?) skips deleting rows;
    - both "deleted before it started" checks treat a deleting row as deleted: the run never launches, or it is stopped at once;
    - `Start` by id of a deleting row is refused with `db.ErrTerminalSessionNotFound`.
    The one way back is the Desktop's **Resume** on a Not-fully-cleaned row. It clears `delete_requested_at` in its own write before it starts the session. Resume is disabled while a background cleanup of that row runs (the state of mockup 8), so the two never overlap.
  The phone therefore drops the session when the Undo window ends, as if it were deleted, and never shows the mark. Its actions (input, interrupt) on such a row are refused as for a missing row (`hub/actions/handlers/session_input.go`).
- **Lookups by id are unchanged**: session report, `owner_asks` joins, `review_agent`, agent analytics, automation session steps, `session_ticket`, `terminal_agent_turns`, the spec-review sweep. A deleting row behaves there as a finished session, and the cascade removes its rows when the row goes. No hook writes to it, because its terminal is closed.

A Go guard test (`TestProj17_DeletingRowsLeaveEveryList`) lists every `FROM terminal_sessions` read outside `_test.go` and fails when a new one is neither filtered nor on the lookup allowlist.

## 5. Contracts touched

- **PROJ-17** (amended): a delete still writes nothing inside the Undo window. When the window ends, it writes `delete_requested_at` and hands the row to the background cleanup. The row is deleted only after a clean outcome or **Delete Anyway**. At quit, the pending rows get `delete_requested_at` instead of being deleted.
- **PROJ-18** (amended):
  - every Desktop delete applies the session cleanup;
  - the "Delete and Clean Up applies exactly the shown keys" sentence goes, because the background apply has no `--item` and removes what is removable when it runs;
  - the ledger gains `source`/`kind` and the command source;
  - the scratchpad rule extends "what the session observed";
  - the 64 cap applies to `cwd` rows, and `command` rows have their own 512.

  "Only what the session observed and what was created after the session started" stays word for word.
- **Guard tests**: `testQuickDeleteNeverCleansUp` is replaced by `testProj17_EveryDeleteCleansUpAfterTheWindow`. `testProj18_DeleteAppliesOnlyThePlannedItems` is replaced by `testProj18_BackgroundApplyHasNoItemFilter`. `testProj18_FailedCleanupKeepsTheSessionRow` stays (now with the mark). New Go tests: `TestProj18_CommandLedgerAdoptsWorktree`, `TestProj18_ScratchpadWorktreeIsTheSessions`, and `TestProj18_CommandNamedBranchOlderThanSessionIsKept`. The owner approved these replacements in ask #1210 (CLAUDE.md: a guard test is never weakened silently).

## 6. Schema

One migration:
- `terminal_sessions.delete_requested_at TEXT` (NULL = not deleting);
- `terminal_session_worktrees.source TEXT NOT NULL DEFAULT 'cwd' CHECK (source IN ('cwd','command'))`;
- `terminal_session_worktrees.kind TEXT NOT NULL DEFAULT 'worktree' CHECK (kind IN ('worktree','branch'))`.

Adding a CHECKed column is an `ALTER TABLE ADD COLUMN` (allowed in SQLite with a constant default), so there is no table rebuild. The primary key stays `(session_id, root, branch)`, and a branch row uses the repository top level as `root`. If a builder finds that the PK collides between a `cwd` and a `command` row of the same pair, the existing row wins and only `last_at` moves; `source` is not overwritten. `schema.sql`, the golden snapshot and the Swift test schema are regenerated.

## 7. Screens

The states are in the mockup. On implementation, each state is registered in `DesignShotCatalog` on fixture data and compared with the mockup in light and dark (`make desktop-shots`). All texts are built in the model and covered by tests; colours come through `Tone` only (warning tone for the mark).

| State | Where |
|---|---|
| Delete dialog (live row), plain confirmation | sheet |
| Undo window (unchanged) | Undo bar |
| Background cleanup running: `Cleaning up 2 sessions…` | sessions panel header |
| Clean: removed, nothing kept | notice |
| Clean with kept items | notice |
| Several sessions joined | notice |
| Not fully cleaned row (process running / git refused / CLI failed) | finished group |
| Not fully cleaned row while **Clean Up Again** runs (`Cleaning up…`, actions disabled) | finished group |
| Narrow panel: the warning line truncates and the actions move into the row's ⋯ menu | finished group |

There is no empty state: a workbench with no deletes looks as today.

## 8. Guide

`docs/guide/` workbench sessions page: deleting a session cleans up its worktrees and branches; what is kept and why; **Not fully cleaned** and its three actions.

## Decisions

- Every delete cleans in the background, with no question and no switch — ask #1205.
- If something could not be removed, the session stays in the list marked "not fully cleaned" — ask #1205.
- The existing pile is cleared once by hand on the Clean Up screen, with no periodic sweep — ask #1205.
- No LLM decides what to remove; rules only — approved by the owner — ask #1210.
- New ownership sources: parsed agent commands + the Claude scratchpad uuid — agent's call (proposed in ask #1205), approved with the spec in ask #1213.
- Kept-on-purpose items (uncommitted, unpushed, …) do not keep the row; only "could not" items do — approved by the owner — ask #1210.
- The Delete dialog loses **Delete Only** / **Delete and Clean Up** — approved by the owner — ask #1210.
- Quit inside the Undo window defers the delete to the next launch instead of deleting — approved by the owner — ask #1210.
- Guard test replacements in §5 — approved by the owner, ask #1210.
- Workbench delete unchanged; remote branches never touched — agent's call, approved with the spec in ask #1213 (a deleted workbench's sessions are not auto-cleaned).
- Implementation decisions (agent's call, all fail-closed):
  - The branch checked out in an adopted scratchpad worktree is adopted too. Every branch catch still applies: born after the uuid was acquired, merged or pushed, not checked out elsewhere.
  - A scratchpad lane is adopted only when it was born after this row acquired the uuid. A uuid ever held by a deleted row is treated as shared, using migration 00188 `agent_session_tombstones`, written by a `BEFORE DELETE` trigger on `terminal_sessions`.
  - A command row counts only when its root is a worktree of the planned repository. v1 limit: if the agent itself removed a worktree created by a command, that worktree's branch is left for the Clean Up screen.
