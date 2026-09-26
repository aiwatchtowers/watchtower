---
type: bug
title: "Daemon PID-reuse check ignores the stored start time, so any other watchtower process counts as the daemon"
status: open
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
