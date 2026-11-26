# The automatic cleanup also reaches what it leaves today

**Board:** #2402 · **Amends:** PROJ-18 (`docs/inventory/workbench.md`) · **Builds on:** #2131 (`docs/features/workbench.md`, "Finished sessions clean up on their own")

## Problem

A busy repository kept dozens of linked worktrees and hundreds of GB of builds under `.claude/worktrees/`, although the hourly automatic cleanup (#2131) ran and logged no failure. It removed branches and kept almost every worktree. Five gaps, read from the code:

1. **Only `finish_session` makes a session a candidate.** `db.FinishedSessionsForCleanup` needs `finished_at`, written only by `finish_session`. A session whose tab was closed, that crashed or that stopped without it is never cleaned up.
2. **A locked worktree is kept for ever.** W3 (`catchLocked`) keeps it before any other check, so a locked worktree whose branch is long merged stays, and the build prune skips it too (`pruneCatches` includes `catchLocked`). Plan worktrees are locked by rule while a plan runs; nobody unlocks them afterwards. Example: a locked worktree with a large build whose branch was merged.
3. **A worktree no finished session owns is never looked at.** The daemon applies session scopes only. Claude Code subagent worktrees (`agent-<hex>`) without a matching subagent record, worktrees older than the session that saw them (`existed_before_session`), those with an unknown birth (`created_unknown`), and those of sessions finished more than 14 days ago are never evaluated again (the first three are settled reasons).
4. **Any process with its cwd inside keeps the worktree**, language servers included (`gopls`, `sourcekit-lsp`, `clangd`), which an editor or an agent leaves running long after the work ended.
5. Directories under `.claude/worktrees/` that git no longer lists, and loose files there, are seen by nobody. They held a few GB; they are split off to their own low-priority target (see Out of scope).

## Decisions

- Sessions that end without `finish_session` count as ended for the cleanup after 24 h with no activity — ask #1850.
- Locked worktrees: the build output goes, and the worktree itself goes once its branch is merged into the default branch with commits and nothing else keeps it; this must not slow down builds — ask #1850 (owner's words: "п1 норм, тока оно не должно замедлить сборки").
- A repository-wide pass covers worktrees no finished session owns — ask #1850.
- Language servers do not keep a worktree — ask #1850.
- **Proposed by the author, owner approved in ask #1853:** "must not slow down builds" is read as: a build folder is removed only from a worktree idle for 3 days (§2, "Last activity") with no live session and no blocking process in it, so a build in use or used recently is never thrown away. The same 3 days gate the removal of a locked worktree and the repository pass.
- **Proposed by the author, owner approved in ask #1853:** orphan directories and loose files under `.claude/worktrees/` are not part of this spec; they get their own low-priority target, #2404, shown in the Clean Up screen and removed only by the owner's tick.
- Global level: the fix lives in Watchtower's cleanup (`internal/sessioncleanup`, the daemon), not in this repository's rules; project-specific build habits are #2403 — conversation.

## Design

Every removal below still goes through the PROJ-18 catches, re-checked right before it, with no `--force`, no fetch and no signal (`NoTerminate`), exactly as today. What changes is which sessions and worktrees get evaluated, and three catches.

### 1. Ended sessions without `finish_session`

`db.FinishedSessionsForCleanup` becomes `db.EndedSessionsForCleanup`. A row is a candidate when it is an agent row of a workbench, not being deleted, and either:

- `finished_at` is set and within the window (as today), or
- `finished_at` is NULL, the row has no live run in the session host, and its last activity — the newest of `last_active_at`, `agent_state_at` and `closed_at` — is at least `autoQuiet` (24 h) old and within the window.

The row's **ended-at** is `finished_at`, else that last activity. The window (`autoWindow`, 14 days) and the retry rule (`autoDue`) are measured from ended-at. The session-host live set is already read before each apply (`AutoDeps.Live`); a quiet row that is live there is skipped for this pass, like today's W6.

A quiet row that becomes active again simply moves its last activity forward: the next pass no longer lists it (under 24 h), and W6 keeps its worktree anyway while it reports from inside.

The apply passes `RequireEnded: false` for such a row (it is ended by this rule, not by `finished_at`); everything else about the apply is today's automatic apply.

### 2. The repository pass

After the session applies, each pass runs one **repository pass** per distinct repository of the workbenches' folders (keyed by the git common dir, under the same repository cleanup lock, `TryLock`; busy → next pass).

**Scope.** Linked worktrees whose root is under `<main checkout>/.claude/worktrees/` — the folder Watchtower's placement and Claude Code's `isolation: worktree` both create worktrees in. A worktree anywhere else is never touched by this pass: outside that folder Watchtower cannot tell an agent's worktree from one the owner made and works in by hand, so a worktree there that the owner made by hand is covered by the same checks and the 3-day idle rule (no session working in it, clean, merged or pushed, idle). The owner's worktrees elsewhere are the owner's. Those outside stay reachable through the Clean Up screen's sweep, as today.

**Skip.** A worktree is skipped (not evaluated) when any of these hold:

- a session working in it (W6's rule: live in the session host, or a not-ended row reporting from inside within 24 h). In this pass a live plain shell holds a tree only when it was opened inside it; a live agent session that has not reported its directory yet holds every tree of the repository. A shell that later cd's into a tree is a process there, covered by the process scan (W5) in the final re-check;
- it is **not idle**: its last activity is less than `idleFor` (3 days) old.

**Last activity of a worktree** is the newest of:

- the mtimes of its admin dir's `HEAD`, `index` and `logs/HEAD` (`<common dir>/worktrees/<name>/`);
- the newest `terminal_session_worktrees.last_at` of any session for that root;
- for **every** build folder the prune would find in it (§4 — at any depth, e.g. `WatchtowerDesktop/.build`, not only at the root): the newest mtime of the folder and of the directories inside it down to `buildActivityDepth` (8) levels, skipping the fetched-package folders (`checkouts`, `repositories`, `artifacts`, `SourcePackages`). A compiler writes its outputs by create-and-rename, which moves the containing directory's mtime, so an incremental build shows up here even when the build folder's own mtime does not move. Only directories are stat-ed, not files, under the walk budget W9 already uses.

A stat that fails, or a walk over its budget, counts as "now" (fail closed: the worktree is not idle, nothing is pruned or removed).

**Evaluate.** The pass plans the idle worktrees in sweep mode — the catches of the owner's Clean Up sweep (`Request.Sweep`), which already judge a worktree without a session — and then:

- removable → applied by name (the sweep apply already takes named items only), its branch with it when the branch item is removable;
- kept for a reason the build prune accepts (§4) → its build output is pruned.

At most `sweepBatch` (20) worktrees are removed per repository per pass, oldest activity first; the rest wait for the next pass. Candidates are evaluated in batches of 20, each batch under its own `TryLock` of the repository lock, so 20 kept worktrees cannot starve the ones behind them. A half-removed (`prunable`) worktree is never a candidate; it is left for the owner's Clean Up. The repository pass runs after the session applies with its own budget (10 min), so long session applies never starve it; when its budget runs out it stops, and the next pass starts again from scratch.

The repository pass makes the "settled" reasons of a session scope matter less: a worktree a session will never claim (`existed_before_session`, `created_unknown`, an `agent-*` without a record) is reached here once it is idle.

### 3. Locked worktrees

W3 changes from "locked → keep" to "locked → keep, unless **merged and idle**":

- **merged**: its HEAD branch has at least one commit of its own and is merged into the default branch — the drift check's detection (`workbenchgit`, `OpenRepositoryAgainst`), under which a commit-less branch cut from the base is *not* merged (a freshly cut umbrella stays). A detached HEAD is never merged for this rule;
- **idle**: last activity (§2) at least `idleFor` old.

When both hold, W3 does not keep it and the other catches decide. If every catch passes, the apply runs `git worktree unlock` and then `git worktree remove` (no `--force`), re-checking every catch right before the unlock. If the remove then fails, the worktree is locked again (`git worktree lock --reason "<the old reason>"`) and kept as `check_failed`.

The same rule applies in a session apply, in the automatic pass and in the owner's Clean Up screen (one catch, one meaning). The Clean Up screen needs no change: it shows a removable worktree as removable (no reason) and a kept one with its reason label (`SessionCleanupPresentation`, `locked` stays as is); the unlock is a step inside the Go apply, not a row of its own. Its Go side is covered by `TestProj18_SweepUnlocksOnlyRightBeforeTheRemove`.

**Undoing an interrupted unlock.** Before it unlocks, the apply writes the old lock reason to `<admin dir>/watchtower-unlocked` (the worktree's own admin dir, which git deletes with the worktree). Every apply and every pass first walks the repository's admin dirs: a marker whose worktree still exists is turned back into a lock (`git worktree lock --reason <saved reason>`) and the marker deleted, before anything is evaluated. So a pass interrupted between the unlock and the remove leaves the worktree locked again on the next run, whichever catch keeps it then. If the relock fails, the marker stays and the worktree is kept as `check_failed` (the marker still counts as locked for W3).

### 4. Build prune

- `pruneReasons` gains `locked`: a locked worktree's build output goes even when the worktree stays.
- **An Xcode DerivedData folder is recognised by its content, whatever its name.** Today only a folder named `DerivedData` counts; `-derivedDataPath` folders named otherwise (seen: `.build-mobile-dd`, `.derived`, `.derived-mobile`, GBs each) stay. A directory at the worktree's root, or one level below it, holding `info.plist`, `Build/` and at least one of `Logs/`, `Index.noindex/`, `ModuleCache.noindex/` is a DerivedData folder for the prune and for W10's cache exemption (so it does not count as unsaved ignored work either). The same content check guards it as today's `DerivedData` kind (`buildKind.files`/`dirs`).
- `pruneCatches` drops `catchLocked` and gains an **idle** check: a build folder is pruned only from a worktree idle for `idleFor`. This applies to every prune of a locked worktree (a locked plan worktree keeps its build at its session's end until it has been idle 3 days) and to the repository pass. The existing prune at a session's end (#2131, ask #1695) of a worktree kept for any other reason is unchanged.
- A quiet session (§1) counts as ended for the prune too, so its kept worktrees lose their build in the same apply, like a finished session's.
- The live-process and session-in-it checks stay in `pruneCatches`, so a build in use is never removed.

### 5. Language servers

A process whose executable's base name is a known **native** language server — `gopls`, `sourcekit-lsp`, `clangd`, `rust-analyzer`, `jdtls`, `lua-language-server`, `zls` — no longer keeps a worktree (W5, `catchProcesses`) and is never signalled. Any other process keeps it, as today. Servers that run under `node` or `python` (`tsserver`, `pyright`, `pylsp`) cannot be told apart from a build or a dev server by the executable, so they keep the worktree: being wrong there removes a worktree under a running build. The list is a fixed set in code (a new server is a one-line change with its test), not a setting: an owner-editable list would let a typo unblock removals.

## Failure modes

| Situation | What happens | Test |
|---|---|---|
| Daemon stops (quit, crash, update) mid-pass | The ctx cancels; the current git command finishes or is killed; the next pass re-plans from scratch. A worktree half-removed by `git worktree remove` shows as `prunable`; the unattended repository pass never touches it (a prunable entry is also what an unmounted or unreadable folder looks like, and pruning detaches it without any check), so it is left for the owner's Clean Up. | `TestAutoRun_StoppedMidRepositoryPassReplans` |
| Unlock succeeded, remove failed | Re-locked with its old reason, kept as `check_failed`. | `TestProj18_LockedMergedRemoveFailureRelocks` |
| Unlock succeeded, daemon killed before remove or relock | The `watchtower-unlocked` marker is left; the next apply or pass relocks the worktree with its old reason first, then evaluates it as usual. It is never left half-deleted or silently unlocked. | `TestProj18_UnlockedByAnInterruptedPassIsRelocked` |
| Relock from a marker fails | Marker kept, worktree kept as `check_failed`, retried next pass. | `TestProj18_FailedRelockKeepsTheWorktree` |
| A session starts in a worktree between plan and remove | Every catch is re-checked right before the unlock and the remove; W6 keeps it. | `TestProj18_SessionStartedBeforeTheRemoveKeepsIt` |
| An incremental build yesterday deep in `WatchtowerDesktop/.build` | The nested build folder's directory mtimes count as activity: not idle, not pruned. | `TestIdle_NestedIncrementalBuildCountsAsActivity` |
| A build starts during the prune | A build is a process inside the worktree: the prune re-checks before each folder (existing `PruneRechecksBeforeEachFolder`), and idle no longer holds once `.build` is touched. | `TestProj18_BuildStartedDuringThePruneStops` |
| The session host cannot be asked for live runs | The session apply skips that row (today); the repository pass skips the whole repository for this pass. | `TestAutoRun_RepositoryPassNeedsLiveRuns` |
| An activity stat fails | Counts as "now": not idle, not pruned, not removed. | `TestIdle_UnreadableStatIsNotIdle` |
| Another cleanup holds the repository lock | The repository pass waits for the next pass. | `TestAutoRun_RepositoryPassWaitsForTheLock` |

## Writers of the same data

- **Worktrees and branches** are written by: placement (`worktree create`), agents and their subagents (git), the owner by hand, the Desktop's delete cleanup, the Clean Up screen, the agent's own pre-finish cleanup and this daemon pass. All Watchtower cleanups share the repository cleanup lock, so only one runs at a time. Git itself refuses a remove of a dirty worktree. Agents and the owner take no lock: the guard against them is the re-check right before each removal, plus idle ≥ 3 days. If an agent writes into the worktree after the last re-check, git's own refusal wins (the remove fails and the item is kept). No writer silently loses work.
- **Worktree locks** are written by agents (`git worktree lock`, plan rule) and by §3. §3 unlocks only right before a remove and re-locks on failure. An agent that locks after the re-check makes git refuse the remove, so the agent wins.
- **`terminal_sessions.cleanup_at` / `cleanup_result`** are written by the automatic pass and by a session's own cleanup, under the repository lock (today's rule). The repository pass writes no session row; it logs its result line only.

## Contract change (PROJ-18 amendment)

The PROJ-18 Observable gains:

- an ended session also means one quiet for 24 h with no live run;
- the automatic pass also evaluates idle linked worktrees under `.claude/worktrees/` that no finished session owns, in sweep mode;
- a locked worktree is kept unless its branch is merged with commits of its own and it is idle for 3 days; then it is unlocked right before its removal and re-locked if the removal fails;
- a build folder of a kept, locked or unowned worktree is pruned only when the worktree is idle for 3 days;
- a native language server (§5's fixed list) does not keep a worktree and is never signalled;
- an Xcode DerivedData folder is recognised by its content, whatever its name.

Guard tests:

- `TestProj18_LockedWorktreeIsKept` keeps all its current cases (locked and not merged; locked, merged and active) and gains the new exception as a separate guard, `TestProj18_LockedMergedIdleWorktreeGoes`.
- `TestProj18_LiveProcessKeepsTheWorktree` is unchanged; `TestProj18_LanguageServerDoesNotKeepTheWorktree` is added.
- `TestProj18_BuildOfAWorktreeInUseStays` is unchanged; `TestProj18_IdleLockedWorktreeLosesItsBuild` and `TestProj18_RecentBuildStays` are added.
- `TestProj18_AutoCleanupOfAResumedSessionRemovesNothing` is unchanged and gains a case for a quiet row that became active again.
- New: `TestProj18_SweepUnlocksOnlyRightBeforeTheRemove`, `TestProj18_UnlockedByAnInterruptedPassIsRelocked`, `TestProj18_FailedRelockKeepsTheWorktree`, `TestProj18_RenamedDerivedDataIsABuild`, `TestProj18_QuietSessionIsCleanedUp`, `TestProj18_LiveQuietSessionIsSkipped`, `TestProj18_RepositoryPassStaysUnderClaudeWorktrees`, `TestProj18_RepositoryPassSkipsActiveWorktrees`, `TestProj18_RepositoryPassRemovesAnUnownedMergedWorktree`, `TestProj18_CommitlessLockedBranchStays`.

No existing guard is relaxed: every current case keeps its assertion.

## Promises → tasks → tests

| Promise | Task | Test |
|---|---|---|
| Quiet sessions are cleaned up (§1) | 1 | `TestProj18_QuietSessionIsCleanedUp`, `TestProj18_LiveQuietSessionIsSkipped`, `TestEndedSessionsForCleanup_*` (db) |
| Idle detection (§2), nested builds included | 2 | `TestIdle_*`, `TestIdle_NestedIncrementalBuildCountsAsActivity` |
| Language servers do not keep (§5) | 2 | `TestProj18_LanguageServerDoesNotKeepTheWorktree` |
| Locked + merged + idle goes, with unlock/relock (§3) | 3 | `TestProj18_LockedMergedIdleWorktreeGoes`, `TestProj18_CommitlessLockedBranchStays`, `TestProj18_LockedMergedRemoveFailureRelocks`, `TestProj18_UnlockedByAnInterruptedPassIsRelocked` |
| DerivedData recognised by content (§4) | 3 | `TestProj18_RenamedDerivedDataIsABuild` |
| Interrupted unlock is undone (§3) | 3 | `TestProj18_UnlockedByAnInterruptedPassIsRelocked`, `TestProj18_FailedRelockKeepsTheWorktree`, `TestProj18_SweepUnlocksOnlyRightBeforeTheRemove` |
| Build prune in locked/idle worktrees only (§4) | 3 | `TestProj18_IdleLockedWorktreeLosesItsBuild`, `TestProj18_RecentBuildStays`, `TestProj18_BuildStartedDuringThePruneStops` |
| Repository pass (§2) | 4 | `TestProj18_RepositoryPass*`, `TestAutoRun_RepositoryPass*`, `TestAutoRun_StoppedMidRepositoryPassReplans` |
| Contract and docs updated | 5 | `go test ./docs/guide` (if the guide changes), inventory entry reviewed |

Task 5 updates `docs/inventory/workbench.md` (PROJ-18 amendment + changelog line), `docs/features/workbench.md` (the #2131 entry), `docs/features/README.md` summary, and the user guide page on cleanup if it describes what is kept.

## Known limits

- A W3 worktree that carries a leftover `watchtower-unlocked` marker shows as `check_failed` in a plan made before any apply (the marker is undone by the next apply or pass, not by a plan, which writes nothing).
- The lock identity check compares content, mtime and inode. On a file system with coarse mtimes that reuses inodes, a lock dropped and retaken with the same text within one tick reads as the same lock. APFS is not affected.
- A FIFO in place of a lock file delays `git worktree list` by at most its 30 s timeout; the cleanup fails closed when that happens (the repository's worktrees are all kept).

## Out of scope

- Directories and loose files under `.claude/worktrees/` that git does not list: a separate low-priority target, shown in the Clean Up screen, never removed automatically.
- How this repository builds (`-trimpath`, copying `.build` into worktrees, per-package build folders): #2403.
- The Go build cache, Xcode DerivedData outside worktrees and simulators: tools' own caches, not Watchtower's.
