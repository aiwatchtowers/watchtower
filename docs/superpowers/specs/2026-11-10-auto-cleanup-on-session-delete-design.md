# Automatic cleanup when a session is deleted

**Board:** #1716 · **Date:** 2026-11-10 · **Mockup:** `docs/design/mockups/session-auto-cleanup/states.html`
**Builds on:** session cleanup (board #535, PROJ-18; `docs/superpowers/specs/2026-10-12-session-cleanup-design.md`), Clean Up screen (#1107), session placement (#229), sessions panel (PROJ-17).

## Why

The disk is running out. One workbench repository has about 400 local branches and 190 linked worktrees. Half of the branches are already merged into the default branch, and 21 worktrees are prunable. The session cleanup exists, but two things keep it from working:

1. **It runs only when the owner asks.** A quick delete (✕, ⌘⌫) and the dialog's **Delete Only** remove nothing. Only **Delete and Clean Up** cleans, and the owner has to choose it every time.
2. **It does not see most of what a session creates.** A session owns only the worktrees its hooks saw as an agent's `cwd`, plus its targets' branches. Plan runs fan tasks out to subagent lanes: `git worktree add <scratchpad>/<lane> -b <branch>` under `/private/tmp/claude-<uid>/<project-slug>/<claude-session-uuid>/scratchpad/` or `/private/tmp/watchtower-<n>`. The subagents work there through `git -C` or `cd` inside a Bash call, so no hook event carries that `cwd`. Claude Code's own subagent worktrees (`isolation: worktree`, `<repo>/.claude/worktrees/agent-<id>` on a `worktree-agent-<id>` branch) are not seen either. The cleanup keeps all of them as `not_this_session`, and they pile up — most of the pile is `agent-<id>` worktrees.

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
- Slowing the hooks. Hook events have 500 ms to 1 s of database budget; this feature adds nothing to any hook. All reading happens in the planner.

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

Ownership comes from facts that Claude Code and git write themselves. Nothing parses the commands an agent ran (ask #1244: the owner rejected command parsing). Three new sources feed the `observed` set of `internal/sessioncleanup` (`observe`, `ownership.go`). Every catch and birth rule applies to them as to a ledger row: born after the session started, merged or pushed, clean, and not in use. Sources 2a and 2b read Claude Code's own session files, so they need the row's agent kind to have that session capability (`sessionagent` caps, `ClaudeSessionFiles` — the gate's `ScratchpadLanes` renamed; Claude yes, Codex no); a kind without it adopts nothing from them. Source 2c reads only git, so it works for every agent kind, Codex included.

**The row's agent sessions.** Sources 2a and 2b start from the row's Claude session uuids (`terminal_session_agent_sessions`, migration 00127, every id the row has had). A uuid counts only when **no other `terminal_sessions` row has it** — in its history or its current `claude_session_id` — and no deleted row ever had it (migration 00189 `agent_session_tombstones`, written by a `BEFORE DELETE` trigger). A uuid shared by two rows (a conversation resumed in another tab) adopts nothing for either of them, which is fail-closed. Each counted uuid has the moment this row acquired it.

### 2a. Subagent worktrees (Claude Code `isolation: worktree`)

Claude Code writes `<projects dir>/<slug>/<uuid>/subagents/agent-<id>.meta.json` for every subagent; a subagent started with a worktree has `"spawnedWithWorktree": true`, `"worktreePath": "<abs path>"` and `"worktreeBranch": "<branch>"` in it. For each counted uuid the planner reads these files (the same directory lookup `internal/sessionfeed` uses for subagent feeds):

- A linked worktree of the planned repository whose root equals `worktreePath` (symlink-resolved) belongs to the session, when it was born at or after the moment this row acquired the uuid (+1 s, second precision, as `bornReason`).
- `worktreeBranch` names a branch of the session, under the same birth rule.
- A missing `subagents` directory, or a missing transcript of the uuid (`<projects dir>/<slug>/<uuid>.jsonl`), means no subagents: Claude Code prunes old transcripts, so this is normal and shows nothing. A meta file without those keys, or with a non-absolute path, adopts nothing. A file that exists but cannot be read or parsed fails the plan (the row is marked "not fully cleaned"), so a broken read is never a silent "nothing to clean".
- **A format change of Claude Code shows, without noise.** Claude Code names a subagent's worktree after the agent: `<repo>/.claude/worktrees/agent-<id>`, branch `worktree-agent-<id>`, record `agent-<id>.meta.json` (checked on real records while writing this). The planner cross-checks the two: a linked worktree of the planned repository whose last folder is `agent-<id>`, born after the uuid was acquired (+1 s), whose `agent-<id>.meta.json` sits in a counted uuid's `subagents` directory but does not name that worktree by `worktreePath` (the keys were renamed, moved or dropped), is not adopted (fail closed) and gives the plan the note `subagent_records_unreadable`. So does a missing projects directory as a whole (`~/.claude/projects`, or under `$CLAUDE_CONFIG_DIR`) while the row has counted uuids. The note fires only on a real mismatch — an old session with a pruned transcript has no such worktree and no note. The row is still deleted, and the notice says it (§3). A test reads a committed sample of the real `meta.json` shape (neutral values, no live data) through the planner, and another renames its keys and expects the note.

### 2b. The session's Claude scratchpad

A linked worktree whose root lies strictly inside `<base>/claude-<uid>/<any slug>/<uuid>/`, for a counted uuid, belongs to the session when it was born at or after the moment this row acquired the uuid (+1 s). The bases are `/tmp`, `os.TempDir()` and `$CLAUDE_CODE_TMPDIR` when set, symlink-resolved and deduplicated. The branch checked out there is the session's too, under the same birth rule.

### 2c. Branches used inside the session's worktrees (git's own HEAD log)

For every linked worktree the session owns — by the cwd ledger, by placement, or by 2a/2b — the planner reads that worktree's own HEAD reflog (`git rev-parse --git-path logs/HEAD` in it; git writes it on every checkout, commit and reset). The candidates are the `<a>` and `<b>` of each `checkout: moving from <a> to <b>` entry and the worktree's current branch.

**A candidate is the session's only when it was created in that worktree, in the same step that switched to it** (`git worktree add -b`, `git checkout -b`, `git switch -c`): its own ref log's first entry (`branch: Created from …`) has the same new commit as one entry of this worktree's HEAD log and lies within one second of it (git writes both in one command; checked against real git in the tests). A branch that was only checked out there — `main`, the owner's branch, another session's branch, even one born after the session started — has a birth entry that matches no switch of this worktree, so it is `not_this_session`. On top of that, every other rule of a branch applies (born after the session started +1 s, merged or pushed, not checked out elsewhere).

A candidate that also appears in another worktree's HEAD log after its birth (another worktree switched to it too) is `not_this_session` as well. The main worktree's log is read only for this exclusion, never to adopt. A worktree without a HEAD log names nothing from 2c; this worktree's log that exists but cannot be read fails the plan; another worktree's log that cannot be read makes this repository's 2c candidates `created_unknown` (kept, not ours — fail closed without marking the row).

### What stays unseen

A worktree made outside these sources — for example `git worktree add` run by an agent into a folder of its own choice, or `/private/tmp/watchtower-<n>` made by a script — is still `not_this_session`, and so are branches made in the main worktree. The owner removes them on the Clean Up screen. If an agent removed a worktree itself, its HEAD log is gone with it, so the branches it used there are left for the Clean Up screen too (v1 limit). A branch the agent made with `git branch X` and switched to later is not adopted either (not created in the switching step): fail closed, left for the Clean Up screen.

## 3. Outcome: clean or not fully cleaned

The apply's `Result` sorts each item into one of three groups.

| Item | Group | Effect on the row |
|---|---|---|
| `done` (removed) | removed | — |
| kept for **the owner's work**: `uncommitted_changes`, `unpushed_commits`, `operation_in_progress`, `locked`, `contains_worktree`; and `default_branch_unknown` (ask #1240) | kept on purpose | none: the row is deleted; the notice names them |
| kept for **not ours / not the session's**: `not_this_session`, `existed_before_session`, `created_unknown`, `main_folder`, `workbench_folder`, `claude_home`, `default_branch`, `checked_out` (in a worktree that is not the session's); and the codes that mean "nothing to do here": `session_recent` (sweep only), `not_a_worktree` / `not_a_branch` (gone or not one), `worktree_kept` (a branch that follows its kept worktree), `bundle_exists` (an entry that is no longer stale) | not ours | none, and not shown |
| **could not**: an item with `error`, or kept for `git_refused`, `moved`, `process_running`, `process_unknown`, `session_in_it`, `check_failed`, `bundle_unreadable`, `not_attempted`; `you_are_in_it`, `not_selected`, `not_in_plan` (the background apply names no items and has no caller session, so these mean something is off); or the run failed as a whole (exit ≠ 0, no JSON, timeout) | could not | the row stays, **Not fully cleaned** |

The table is one pure function in WatchtowerCore (`SessionAutoCleanupOutcome`). Every reason code of `internal/sessioncleanup` (`allReasonCodes`, mirrored in `testdata/reason_codes.json`) is placed above, and a test fails when Go adds a reason code the table does not place. An unknown code counts as **could not**, which is fail-safe.

**The deleted session is not "a session in it".** `session_in_it` keeps a worktree in which another session works. In the background cleanup, the row being deleted is excluded from that catch unless its own terminal is still live: its terminal is closed, so it no longer works there, and counting it would leave every deleted row **Not fully cleaned** in the main case (its own worktree). Another session in the same worktree still keeps it (`session_in_it`, could not). Tests: `TestProj18_SessionInTheWorktreeKeepsIt` (the deleted row alone → removed; the deleted row with a live terminal → kept; another session in it → kept).

**Clean** (no "could not" item): the row is deleted and a notice appears on the Undo bar's place for 6 s. The text, built in the model:
- `Cleaned up “T”: removed 3 worktrees and 12 branches (~2.1 GB).`
- with kept items: `Cleaned up “T”: removed 2 worktrees (~1.4 GB). Kept 1 branch — unpushed commits.`
- nothing removed, items kept on purpose: `Cleaned up “T”: kept 2 branches — default branch unknown.`
- nothing removed and nothing kept on purpose: no notice (the row simply goes).
- with the `subagent_records_unreadable` note (§2a), the notice is shown even when nothing was removed, with the line `Could not read the subagent records of “T” — check the Clean Up screen.` after the sentence above. It appears only when a subagent worktree exists that its record does not name, or when Claude Code's projects directory is gone, never for a pruned old transcript.

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
- `terminal_session_worktrees`: the Go hooks only (cwd sightings, as on main). The row delete cascades it. The meta files and HEAD logs of §2 are written by Claude Code and git; the planner only reads them, and a file changing mid-read is a read error (the plan fails, the row is marked).
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
- **Lookups by id are unchanged**: session report, `owner_asks` joins, `review_agent`, agent analytics, `session_ticket`, `terminal_agent_turns`, the spec-review sweep. A deleting row behaves there as a finished session, and the cascade removes its rows when the row goes. No hook writes to it, because its terminal is closed.
- **Automation session steps filter deleting rows**: a run step never attaches a deleting row, and a step whose session is deleting reads as having no session, so the run's next poll launches a new session (`internal/db/automation_session_steps.go`, `AutomationQueries.unattachedSession`).

A Go guard test (`TestProj17_DeletingRowsLeaveEveryList`) lists every `FROM terminal_sessions` read outside `_test.go` and fails when a new one is neither filtered nor on the lookup allowlist.

## 5. Contracts touched

- **PROJ-17** (amended): a delete still writes nothing inside the Undo window. When the window ends, it writes `delete_requested_at` and hands the row to the background cleanup. The row is deleted only after a clean outcome or **Delete Anyway**. At quit, the pending rows get `delete_requested_at` instead of being deleted.
- **PROJ-18** (amended):
  - every Desktop delete applies the session cleanup;
  - the "Delete and Clean Up applies exactly the shown keys" sentence goes, because the background apply has no `--item` and removes what is removable when it runs;
  - the subagent-worktree, scratchpad and HEAD-log sources extend "what the session observed" (§2);

  "Only what the session observed and what was created after the session started" stays word for word.
- **Guard tests**: `testQuickDeleteNeverCleansUp` is replaced by `testProj17_EveryDeleteCleansUpAfterTheWindow`. `testProj18_DeleteAppliesOnlyThePlannedItems` is replaced by `testProj18_BackgroundApplyHasNoItemFilter`. `testProj18_FailedCleanupKeepsTheSessionRow` stays (now with the mark). New Go tests: `TestProj18_SubagentWorktreeIsTheSessions`, `TestProj18_ScratchpadWorktreeIsTheSessions`, `TestProj18_HeadLogBranchOnlyCheckedOutIsKept` (a branch only switched to — older or younger than the session — is kept) and `TestProj18_SessionInTheWorktreeKeepsIt` (§3). `TestProj18_CommandLedgerAdoptsWorktree` and `TestProj18_CommandNamedBranchOlderThanSessionIsKept` are deleted with the command parsing (ask #1244); both were added on this branch and never reached main, and their replacements guard the same promise for the new sources. The owner approved the Swift replacements in ask #1210 and the Go ones in ask #1259 (CLAUDE.md: a guard test is never weakened silently).

## 6. Schema

Two migrations, numbered after main's last one when the branch merges (main took 00186 and 00187 while this branch was open; at the time of writing they are 00188 and 00189):
- 00188: `terminal_sessions.delete_requested_at TEXT` (NULL = not deleting). The `source`/`kind` columns of `terminal_session_worktrees` that the command parsing needed are removed from this migration before it ships, so the ledger stays as it is on main: `cwd` sightings only, cap 64.
- 00189: `agent_session_tombstones` with its `BEFORE DELETE` trigger (§2).

**Editing an unshipped migration in place.** goose never re-runs an applied version, so editing or renumbering a migration is safe only while no kept database has applied the branch's version. That holds here: the branch never reached main or a release, tests build each database fresh, and agents never run a branch CLI on the live install (repo rule). Checked read-only on the owner's install while writing this: it stands at main's version, without `delete_requested_at` or `source`/`kind`. The plan repeats that read-only check (`goose_db_version` and the columns) as a gate step before the merge; a database that did apply a branch version is a throwaway test copy and is recreated, never migrated by hand.

**Tombstones grow without pruning (v1 limit, accepted).** One small row per agent uuid of a deleted session (the uuid and a time). A tombstone must outlive every row that could hold its uuid, and nothing tells when that is, so v1 never prunes. Even thousands of deletes stay well under a megabyte.

`schema.sql`, the golden snapshot and the Swift test schema are regenerated.

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
| Subagent records unreadable (§2a) | notice |
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
- New ownership sources: facts only — subagent worktrees from Claude Code's `meta.json`, the Claude scratchpad uuid, and branches from the owned worktrees' HEAD logs; no parsing of the agents' commands — owner, ask #1244 (replaces the command parsing approved in ask #1213, after the final review showed a parsed command does not prove the command ran: asks #1240/#1244).
- Kept-on-purpose items (uncommitted, unpushed, …) do not keep the row; only "could not" items do — approved by the owner — ask #1210.
- The Delete dialog loses **Delete Only** / **Delete and Clean Up** — approved by the owner — ask #1210.
- Quit inside the Undo window defers the delete to the next launch instead of deleting — approved by the owner — ask #1210.
- Guard test replacements in §5 — Swift: owner, ask #1210; Go: owner, ask #1259 (answered «Да, заменить»).
- A HEAD-log branch is the session's only when created in the same step that switched to it (§2c) — owner, ask #1259 (answered «Да, строгое правило»).
- Workbench delete unchanged; remote branches never touched — agent's call, approved with the spec in ask #1213 (a deleted workbench's sessions are not auto-cleaned).
- `default_branch_unknown` is kept on purpose, not "could not": the row is deleted and the notice names the kept items — owner, ask #1240.
- Automation session steps filter deleting rows instead of treating them as lookups by id (§4) — approved by the owner in the plan review, asks #1223/#1227.
- Implementation decisions (agent's call, all fail-closed):
  - The branch checked out in an adopted scratchpad worktree is adopted too. Every branch catch still applies: born after the uuid was acquired, merged or pushed, not checked out elsewhere.
  - A scratchpad lane is adopted only when it was born after this row acquired the uuid. A uuid ever held by a deleted row is treated as shared, using migration 00189 `agent_session_tombstones`, written by a `BEFORE DELETE` trigger on `terminal_sessions`.
  - The deleted row is not "a session in it" of its own worktree unless its terminal is live (§3) — after the final review's blocker.
  - A HEAD-log branch also switched to by another worktree is not the session's (§2c) — after the spec review of ask #1249.
  - Source 2c works for every agent kind; only 2a/2b need the Claude session-files capability (§2) — ask #1249 review.
  - Claude Code's format drift is caught by cross-checking `agent-<id>` worktrees against their records, and shown in the notice (`subagent_records_unreadable`); a pruned transcript is normal and silent (§2a) — asks #1249/#1260 review.
  - Migrations are edited in place and renumbered after main's last at merge, with a read-only check of the live install as a gate step; tombstones are never pruned in v1 (§6) — ask #1249 review.
