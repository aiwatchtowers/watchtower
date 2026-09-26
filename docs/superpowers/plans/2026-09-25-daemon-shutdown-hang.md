# Daemon Shutdown Hang Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** a stopping daemon exits within seconds on any vault, a second SIGTERM always kills it, and the memory eviction pass stops being O(candidates × history) on every cycle.

**Architecture:** four independent fixes from the incident RCA — memory memo + cancellation points, go-git per-file staging, shutdown-context helper, `sync stop --force`. No schema, no config keys, no Swift.

**Tech Stack:** Go 1.25, go-git v5.19.1, cobra.

**Spec:** none — the incident RCA is the requirements source: `docs/incidents/2026-09-25-daemon-shutdown-hang.md` (added by Task 4; until then read the same text at `/private/tmp/claude-501/-Users-user-PhpstormProjects-watchtower/81fdf01c-e953-4f48-b77f-1b6edc45847a/scratchpad/shutdown-hang-rca.md`). Section numbers below refer to it.

**Worktree:** `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/shutdown-hang`, branch `fix/daemon-shutdown-hang`.

## Global Constraints

1. English only in repo files; one commit per task, files by path (never `git add -A`, never `git stash`); verify `git branch --show-current` = `fix/daemon-shutdown-hang`; trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
2. Inner-loop tests only (`go test ./internal/<pkg>`, `go test ./cmd -run <Name>`; never `-race ./cmd` whole). Log to files, check `$?` explicitly.
3. Never run the `watchtower` binary; never touch the live workspace, vault, DB or config. Tests use temp dirs.
4. `docs/inventory/memory.md` contracts are load-bearing: MEM-03 (owner-edit detection), MEM-04 (`TestMemory04_InterruptedRunKeepsCommittedBatchesBehindWatermark` must stay green UNCHANGED), MEM-07 (eviction never thins provenance). Any change that would weaken a `Test<Module>NN_` guard → stop, report BLOCKED.
5. Every new guard mutation-checked (scratch copy OUTSIDE the repo in `/private/tmp/claude-501/-Users-user-PhpstormProjects-watchtower/81fdf01c-e953-4f48-b77f-1b6edc45847a/scratchpad`, restore from it, `diff -q`).
6. Sentrux: split, don't grow; `runSemantic` is already long — add the ctx checks through a small helper, not inline branches.
7. SIGKILL is never the default stop path (go-git's index write is non-atomic — RCA §6c).

## Review Focus

1. A cancelled run must write NOTHING partial: every post-cancel step either completes cleanly or is skipped before its first write (MEM-04 atomicity).
2. The memo swap must be semantically identical to per-call `OwnerEdited` — an owner-edited episode is still protected from eviction (MEM-03/MEM-07).
3. `SkipStatus` staging must not start committing unrelated worktree dirt (MEM-03: owner edits are committed only by `CommitOwnerEdits`).
4. The second-signal kill must not fire on the FIRST signal (normal graceful shutdown still runs defers, releases the flock, removes the pid file).

---

### Task 1: memory — eviction memo + cancellation points (RCA §6 a0 + a1)

**Files:** `internal/memory/evict.go`, `internal/memory/aging.go`, `internal/memory/pipeline.go` (`runSemantic`, `Run`), `internal/memory/rewrite.go`, `internal/memory/reflect.go`, `internal/memory/index.go` (Reconcile loop), dedupe/promote files only if their signature must take `ctx`; tests beside each.

- [ ] (a0) `EvictEpisodes`: build `newOwnerEditedMemo(v)` once before the candidate loop, call `.lookup(rel)` instead of `v.OwnerEdited(rel)` (evict.go ~131). If `Vault.OwnerEdited` then has no production caller, delete it and move its tests onto the memo (or keep it test-only only if a test needs the per-call form — say which in the report). Test `TestEvictEpisodes_OwnerTouchReadsHistoryOnce`: N candidates, a counting seam around the history walk → exactly one walk; plus the existing owner-touch/retention evict tests stay green unchanged.
- [ ] (a1) Cancellation points: `runSemantic` checks `ctx.Err()` before dedupe, age, evict, reflect (skip the rest, record the step rows as skipped the way a gated-off step records them — read how skips are recorded today); `Run` skips `runRenders` and `runDigestCompare` when ctx is done; `AgeEpisodes`/`EvictEpisodes` (and dedupe/promote if they loop over nodes) take `ctx` and check it at the top of each candidate iteration, returning `(0, ctx.Err())` before any write; `RewriteEntityPages` checks ctx before each Generate and does NOT stamp an attempt whose error `errors.Is(err, context.Canceled)` (rewrite.go ~143-146, ~190); same for Reflect's stamp (reflect.go ~153); Reconcile's per-file loop (index.go ~54) checks ctx between files and returns early (a reconcile is re-runnable — say how a partial reconcile leaves the index).
- [ ] Tests: `TestPipeline_CancelledCtxSkipsPostBeliefSteps` (cancel inside the fake generator on the first rewrite call → no `memory(age)`/`memory(evict)`/`memory(index)`/`memory(map)` commit lands); `TestEvictEpisodes_CancelledCtxWritesNothing`, `TestAgeEpisodes_CancelledCtxWritesNothing` (pre-cancelled ctx → 0, ctx.Err(), vault HEAD unchanged); `TestRewriteEntityPages_CancelledCallDoesNotStampAttempt`; `TestReconcile_CancelledCtxStopsEarly`. MEM-04 guard unchanged and green.
- [ ] Mutations: per-call OwnerEdited restored → history-once test fails; remove one ctx check → its test fails; stamp on cancel → stamp test fails.
- [ ] `go test ./internal/memory`, lint new-from-rev. Commit `fix(memory): evict via the owner-edit memo; honour cancellation between and inside post-belief steps`.

### Task 2: vault — stage one file without walking the worktree (RCA §6 a2)

**Files:** `internal/memory/vault.go` (`WriteNodes` ~545, `WriteFile` ~571), `internal/memory/vault_test.go`.

- [ ] Replace `wt.Add(rel)` with `wt.AddWithOptions(&git.AddOptions{Path: rel, SkipStatus: true})`. Verify in the vendored/module go-git source (v5.19.1 `worktree_status.go` doAdd/doAddFile) that SkipStatus + a single file path stages exactly that file and never other dirt; quote the lines in the report.
- [ ] Tests: `TestWriteNodes_UnchangedContentStillNoCommit` (byte-identical write → no new commit, same as before); `TestWriteNodes_DoesNotStageUnrelatedDirt` (an unrelated modified file in the worktree is NOT in the commit — MEM-03); existing vault tests green unchanged.
- [ ] Mutation: `Path: "."`/`All: true` → the dirt test fails.
- [ ] Commit `perf(memory): stage a written node without a whole-vault status walk`.

### Task 3: shutdown context — the second signal kills (RCA §6 b)

**Files:** new `cmd/shutdown.go` (helper), `cmd/sync.go` (~347), the other long-running `signal.NotifyContext` sites the RCA §3 lists (`cmd/targets_ai.go`, `cmd/inbox.go`, `cmd/ideas.go`, `cmd/ai.go`, `cmd/ask.go`, `cmd/logs.go`) — adopt the helper where the command runs long; tests `cmd/shutdown_test.go`.

- [ ] `notifyShutdownContext(parent context.Context, logf func(string, ...any)) (context.Context, context.CancelFunc)`: wraps `signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM)` and starts `go func(){ <-ctx.Done(); if parent not done { logf("shutdown requested; send the signal again to force") }; stop() }()` so the FIRST signal cancels ctx and restores default disposition; the second kills.
- [ ] Tests (helper-process pattern, `GO_WANT_HELPER_PROCESS`): `TestShutdownContext_SecondSignalTerminates` (child installs the helper, prints ready, on ctx done prints "cancelled" then blocks; parent SIGTERM → waits for "cancelled" → SIGTERM → child exits within ~2 s with `Signaled() && Signal()==SIGTERM`); `TestShutdownContext_SingleSignalReturnsNormally` (child returns normally after the first signal and its deferred cleanup runs — prints "deferred"). Unix-only build tag if needed.
- [ ] Mutation: drop the `stop()` goroutine → second-signal test times out/fails.
- [ ] Commit `fix(cmd): a second SIGTERM always terminates a shutting-down command`.

### Task 4: `sync stop --force` + incident record (RCA §6 c)

**Files:** `cmd/sync.go` (`runSyncStop` ~153-181 + flag), `cmd/sync_stop_test.go` (or the existing sync test file), new `docs/incidents/2026-09-25-daemon-shutdown-hang.md` (the RCA, lightly edited into an incident record: timeline, root causes, fixes with commit refs, follow-ups), `CLAUDE.md` (one bullet in the Menu-Bar Tray + Daemon Lifecycle section: stop semantics, `--force`, second-signal kill), `docs/audit/…` not touched.

- [ ] On the 10 s timeout, print the PID and `still shutting down; run 'watchtower sync stop --force' to kill it` and exit non-zero (as today). `--force`: send SIGTERM (after Task 3 a second SIGTERM kills), wait up to 5 s, then SIGKILL, remove the stale pid file, report which signal ended it.
- [ ] Tests with a helper process that ignores/swallows SIGTERM: `TestRunSyncStop_TimeoutReportsForceHint`, `TestRunSyncStop_ForceKillsStuckDaemon` (process gone, pid file removed); degenerate: `--force` with no daemon running → clean "not running" exit 0. Use a short injectable grace for tests (a package var or param — not a config key).
- [ ] Commit `feat(cmd): sync stop --force; incident record for the 2026-09-25 shutdown hang`.

Execution order: 1 → 2 → 3 → 4 (tasks 1 and 2 both touch internal/memory; 3 and 4 both touch cmd/sync.go). Final gate: `make test`, `make lint-all`, `sentrux gate` (no Swift change), then `local-review` → PR → merge on green.
