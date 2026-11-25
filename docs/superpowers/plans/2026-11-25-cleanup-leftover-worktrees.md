# Plan: the automatic cleanup also reaches what it leaves today

**Spec:** `docs/superpowers/specs/2026-11-25-cleanup-leftover-worktrees-design.md` (approved in ask #1853)
**Board:** #2402 · **Umbrella branch:** `feature/session-cleanup-sweep` (each task on its own branch cut from the umbrella, merged into it locally; one PR umbrella → main at the end)

Go only. No Swift, no migration, no schema change (every column used already exists).

## Rules for every task

- Read `docs/inventory/workbench.md` PROJ-18 before touching `internal/sessioncleanup`. No existing `TestProj18_*` assertion is relaxed, renamed or split; new cases are added as new guards with the names the spec lists.
- Self-review against `docs/review/review-rules.md` (Go sections) before hand-back.
- Inner loop only: `go test ./internal/sessioncleanup` (plus the packages the task names), `make lint-diff`. The full gate runs once before the umbrella PR.
- **Guard suites every task runs before hand-back:** `go test ./internal/sessioncleanup ./internal/db -run 'Proj18|Cleanup|Ended|Finished'`, `go test ./cmd -run 'Cleanup|Proj18'`, `go test ./internal/daemon -run Cleanup`.
- Tests use fakes/test clocks for time (no wall-clock waits); any subprocess a test starts is reaped in `t.Cleanup`; packages creating git repos keep `gittest.DisableBackgroundGit()` in `TestMain` (already true in `internal/sessioncleanup`).
- Every new path names its failure and has the test the spec's "Failure modes" table lists.

## Task 1 — Quiet sessions are candidates

**Depends on:** none · **Spec:** §1

Files: `internal/db/terminal_session_worktrees.go` (`FinishedSessionsForCleanup` → `EndedSessionsForCleanup`, `FinishedSessionForCleanup` gains `EndedAt` and `Quiet bool`), `internal/sessioncleanup/auto.go` (`autoQuiet = 24 * time.Hour`; window and `autoDue` measured from `EndedAt`; a quiet candidate that is live in the host is skipped this pass; apply with `RequireEnded: false` for a quiet row, and a new `Request.Quiet` flag that `sessionEnded()` (`builds.go`) honours, so a quiet row's kept worktrees lose their build like a finished one's), `cmd/workbench_cleanup_auto.go` (wiring).

Steps:
1. Query: agent rows of a workbench, not deleting, and either `finished_at >= since`, or `finished_at IS NULL` with last activity = max(`last_active_at`, `agent_state_at`, `closed_at`) ≤ now − 24 h and ≥ since. Compute max in Go if SQL text comparison of stamps is not safe (stamps are `AgentStateStamp` strings — check their format before comparing in SQL). An unparsable stamp skips the row (as today).
2. `autoDue` and the 14-day window use `EndedAt`.
3. `AutoRun`: the live set is already read before each apply; skip (not fail) a quiet row present in it.
3a. `sessionEnded()` returns true for `Request.Quiet` (set only by `AutoRun` for a quiet row; the CLI never sets it).
4. Tests: `TestEndedSessionsForCleanup_*` in `internal/db` (finished; quiet ≥ 24 h; active < 24 h excluded; outside window; deleting excluded; unparsable stamp), `TestProj18_QuietSessionIsCleanedUp`, `TestProj18_LiveQuietSessionIsSkipped`, a new case in `TestProj18_AutoCleanupOfAResumedSessionRemovesNothing` (quiet row active again), `TestProj18_QuietSessionLosesKeptWorktreesBuild` (its kept worktree's build is pruned in the same apply).

## Task 2 — Worktree idleness and language servers

**Depends on:** none · **Spec:** §2 "Last activity", §5

Files: new `internal/sessioncleanup/idle.go` (+ `idle_test.go`), `internal/sessioncleanup/catches.go` / `procs.go` (W5), `internal/sessioncleanup/deps.go` if a clock/stat seam is needed.

Steps:
1. `lastActivity(ctx, root, adminDir) (time.Time, error)`: newest of admin `HEAD`, `index`, `logs/HEAD` mtimes; the newest `terminal_session_worktrees.last_at` for the root (new small db read, any session); for every build folder `findBuildDirs` finds (any depth): newest mtime of the folder and its sub-directories down to `buildActivityDepth = 8`, skipping `checkouts`, `repositories`, `artifacts`, `SourcePackages`; directories only, under W9's walk budget. Any stat error or budget overrun → return `now` (fail closed). `idleFor = 72 * time.Hour`; `isIdle` uses the deps clock.
2. W5: a process whose executable base name is in `languageServers = {gopls, sourcekit-lsp, clangd, rust-analyzer, jdtls, lua-language-server, zls}` neither keeps a worktree nor is ever an orphan to signal. A process whose cwd is inside but executable outside (node, python) is unchanged.
3. Tests: `TestIdle_*` (each source moves activity; nested build `WatchtowerDesktop/.build/x/y/z` dir mtime counts — `TestIdle_NestedIncrementalBuildCountsAsActivity`; fetched-package dirs ignored; unreadable stat → not idle — `TestIdle_UnreadableStatIsNotIdle`; budget overrun → not idle), `TestProj18_LanguageServerDoesNotKeepTheWorktree` (and is not signalled), `TestProj18_LiveProcessKeepsTheWorktree` unchanged and passing.

## Task 3 — Locked worktrees, relock marker, DerivedData by content, prune

**Depends on:** Task 2 · **Spec:** §3, §4

Files: `internal/sessioncleanup/catches.go` (W3), `apply.go` (unlock right before remove; relock on failure; marker restore at the start of every apply), new `internal/sessioncleanup/unlock.go` (+ test), `builds.go` (`pruneReasons` += `locked`; `pruneCatches` drops `catchLocked`, adds the idle check for every prune of a **locked** worktree (also at a session's end) and for the repository pass — the #2131 end-of-session prune of a worktree kept for any other reason is unchanged; DerivedData by content), `ignored.go` / `nested.go` (W10/W9 cache exemption for content-recognised DerivedData).

Steps:
1. **Merged with commits of its own:** reuse the drift check's detection (`internal/workbenchcheck`, `OpenRepositoryAgainst`, under which a commit-less branch cut from the base is not merged) or extract its predicate into a shared helper; do not re-implement it. Detached HEAD → not merged.
2. W3: locked → keep, unless merged (step 1) and idle (Task 2). Re-checked right before the unlock like every catch.
3. Apply: write `<admin dir>/watchtower-unlocked` (old lock reason) → `git worktree unlock` → `git worktree remove` (no `--force`). Remove fails → `git worktree lock --reason <old>`, delete marker, keep as `check_failed`. W3 treats a present marker as locked.
4. Marker restore: at the start of every apply (session, sweep, automatic), for each admin dir with a marker whose worktree still exists, relock with the saved reason and delete the marker; relock failure leaves the marker and the item is `check_failed`.
5. DerivedData by content: a directory at the worktree root or one level below with `info.plist`, `Build/` and one of `Logs/`, `Index.noindex/`, `ModuleCache.noindex/` is a DerivedData build kind for the prune and for the W9/W10 cache exemptions. Keep the existing named-`DerivedData` kind's checks.
6. Tests: `TestProj18_LockedWorktreeIsKept` keeps every current case and passes; new `TestProj18_LockedMergedIdleWorktreeGoes`, `TestProj18_CommitlessLockedBranchStays`, `TestProj18_LockedMergedRemoveFailureRelocks`, `TestProj18_UnlockedByAnInterruptedPassIsRelocked`, `TestProj18_FailedRelockKeepsTheWorktree`, `TestProj18_SweepUnlocksOnlyRightBeforeTheRemove`, `TestProj18_SessionStartedBeforeTheRemoveKeepsIt`, `TestProj18_IdleLockedWorktreeLosesItsBuild`, `TestProj18_RecentBuildStays`, `TestProj18_LockedWorktreeBuildStaysAtSessionEndUntilIdle`, `TestProj18_BuildStartedDuringThePruneStops`, `TestProj18_RenamedDerivedDataIsABuild`. `TestProj18_BuildOfAWorktreeInUseStays` and the #2131 prune guards unchanged and passing.

## Task 4 — The repository pass

**Depends on:** Task 2, Task 3 · **Spec:** §2

Files: `internal/sessioncleanup/auto.go` (after the session applies: one repository pass per distinct git common dir of the workbenches' folders), new `internal/sessioncleanup/repopass.go` (+ test), `cmd/workbench_cleanup_auto.go` (deps: folders of every workbench, the live set), `internal/daemon/session_cleanup.go` only if the pass needs new wiring.

Steps:
0. The repository pass runs after the session applies with **its own** budget (`repoPassBudget = 10 * time.Minute`, a fresh ctx from the daemon's ctx), so long session applies never starve it; the daemon's per-pass bound becomes the sum (`sessionCleanupBudget` covers the session part only).
1. Per repository, under `TryLock` (busy → next pass): marker restore (Task 3 step 4); list linked worktrees under `<main checkout>/.claude/worktrees/`; skip those with a session working in them (W6 rule) or not idle; oldest activity first, at most `sweepBatch = 20`.
2. Plan them in sweep mode (`Request.Sweep`), apply the removable worktree and branch items by name; for kept items whose reason the prune accepts, prune builds (idle already holds).
3. Live set unreadable → skip the repository this pass. ctx done → stop; next pass starts over. Log one line per repository that removed or failed something (existing `Logf`).
4. Tests: `TestProj18_RepositoryPassStaysUnderClaudeWorktrees`, `TestProj18_RepositoryPassSkipsActiveWorktrees`, `TestProj18_RepositoryPassRemovesAnUnownedMergedWorktree` (an `agent-*` with no record), `TestAutoRun_RepositoryPassNeedsLiveRuns`, `TestAutoRun_RepositoryPassWaitsForTheLock`, `TestAutoRun_StoppedMidRepositoryPassReplans`, batch cap honoured, `TestAutoRun_RepositoryPassHasItsOwnBudget` (session part exhausting its budget still lets the repository pass run).

## Task 5 — Contract and docs

**Depends on:** Tasks 1–4 · **Spec:** "Contract change"

Files: `docs/inventory/workbench.md` (PROJ-18: a dated amendment paragraph citing asks #1850/#1853 and this spec, the new guard list; a changelog line at the end), `docs/features/workbench.md` (the #2131 entry: quiet sessions, repository pass, locked rule, DerivedData by content, language servers), `docs/features/README.md` (summary line), the user guide page that describes the cleanup (`grep -rl -i "clean up" docs/guide`) if it says what is kept — then `go test ./docs/guide`.
