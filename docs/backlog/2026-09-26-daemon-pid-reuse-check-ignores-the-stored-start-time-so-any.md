---
type: bug
title: "Daemon PID-reuse check ignores the stored start time, so any other watchtower process counts as the daemon"
status: done
priority: med
tags: [daemon, pidfile, lifecycle, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** internal/daemon/pidfile.go:85-128, internal/daemon/pidfile.go:130-142, cmd/sync.go:206-238, cmd/sync.go:343-351
**Confidence:** med

`WritePID` stores `pid starttime`, and the doc says the timestamp is "compared against the process's actual start time". In practice `FindProcess` only calls `isReusedPID`, which checks whether `ps -o comm=` contains "watchtower". Watchtower spawns many short-lived `watchtower` processes: `watchtower mcp`, `ai query`, the ~50 Desktop CLI call sites. After a daemon crash or SIGKILL leaves a stale `daemon.pid`, a reused PID held by one of them is reported as the running daemon. Consequences:
- `sync --daemon --detach` refuses to start ("daemon already running").
- `sync --now` signals an unrelated process with SIGUSR1, whose default action terminates it.
- `sync stop --force` can SIGTERM/SIGKILL it.

Separately, `runSyncStop` calls `RemovePID` without checking the file still names the PID it stopped. A daemon respawned quickly by the Desktop can lose its fresh pid file, and the tray then shows it as not running. Fix: compare the process start time (`ps -o lstart=`/sysctl) with the stored timestamp, or test the `sync.lock` flock. Remove the pid file only if its content still matches.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution:** `isReusedPID` (`internal/daemon/pidfile.go`) now takes the stored start time and compares it against the process's real OS-recorded start time (`processStartTime`, via `ps -o lstart=`, parsed with `time.ParseInLocation` in the local zone), tolerating up to `pidReuseTolerance` (2 minutes, covering the gap between actual fork and `WritePID`'s call partway through daemon startup) before calling it reused — replacing the old `ps -o comm=` name-substring check entirely. `FindProcess` passes the stored timestamp through. Pinned by `TestIsReusedPID_MatchingStartTime`/`_MismatchedStartTime`/`_NonexistentProcess`/`_ZeroStoredStart` and `TestFindProcess_LiveProcessWithTimestamp`/`_ReusedPIDWithMismatchedTimestamp` in `internal/daemon/pidfile_test.go` (the two pre-existing tests that asserted the *old*, name-based behavior — `TestIsReusedPID_OwnProcess`/`TestFindProcess_LiveProcessWithTimestamp` — were updated in place since they pinned the exact bug this fixes, not an unrelated contract).

Separately, `runSyncStop`'s plain-stop path (`cmd/sync.go`) no longer calls `daemon.RemovePID` unconditionally once the target process is confirmed gone; it calls the existing `verifyDaemonAlive` seam instead (ignoring its return value, relying only on its underlying `FindProcess` call's side effect), matching `forceStopSync`'s already-fixed escalation path — so a fresh daemon that starts and claims the same pid-file path during the grace-period wait keeps its file. Pinned by two new `cmd/sync_stop_test.go` tests: `TestRunSyncStop_PlainStopRemovesPIDFileOnCleanExit` (regression: normal cleanup still happens) and `TestRunSyncStop_PlainStopSparesFreshDaemonThatWonTheRace` (new: a second live, correctly-identified helper process that takes over the pid file mid-wait is never touched or signalled) — the latter was confirmed to fail against the pre-fix `cmd/sync.go` (deletes the fresh daemon's pid file).

Tests: `go test ./internal/daemon/...` (exit 0), `go test ./cmd/... -run 'TestRunSyncStop|TestForceStopSync|TestSyncStop'` (exit 0).
