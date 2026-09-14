---
type: chore
title: Stray loggers still write to daemon.log, which cannot be rotated in-process
status: open
priority: med
tags: [daemon, logging, jira, audit-2026-09-13]
context: surfaced by the task-5 review of audit fix wave 5 (one daemon log stream, rotation while running)
created: 2026-09-14
---

Wave 5 made `watchtower.log` the daemon's one log stream: `logWriterFor` (`cmd/logfile.go`)
stopped adding `os.Stderr` for a detached child, and `rotatingFile` keeps that file under
`maxLogSize` while the process runs. `daemon.log` keeps its role as the stderr channel and its
open-time rotation.

That leaves a residue the fix did not address. Several components log to stderr rather than
through the daemon's logger, so their output still lands in `daemon.log` — the one file that
**cannot** be rotated while the daemon runs, because the detached child holds it as a descriptor
inherited from a parent that has already exited. Renaming the path leaves the child appending to
the renamed inode. So every line below is, by construction, unbounded until the next daemon
restart.

## The sites

**The standard library's default logger** (`log.Printf`, output `os.Stderr`), reachable from
daemon phases:

- `internal/db/targets.go:471`, `internal/db/targets.go:520`
- `internal/db/targets_jira.go:105`, `:136`, `:155`
- `internal/ai/context_builder.go:228`, `:249`
- `cmd/tracks.go:255`

**Four Jira sub-loggers that `wireJiraSyncers` never replaces.** It sets only
`Syncer.SetLogger` (`cmd/sync.go:734`), so `jira.Client`, `UserMapper`, `KeyDetector` and
`BoardAnalyzer` keep their own defaults. `BoardAnalyzer` is the chatty one:
`NewBoardAnalyzer` hardcodes `log.New(os.Stderr, "[jira-analyzer] ", …)`
(`internal/jira/board_analyzer.go:145`), `CheckAndRefreshProfiles` runs on every Jira sync
(`internal/jira/sync.go:188-189`), and it logs per board per cycle (`internal/jira/board_analyzer.go:221`, `:389`, `:400`, `:404`).

**Direct stderr writes** in `internal/daemon/pidfile.go:104`, `:114`, `:123`, `:135`.

## Why it matters

1. **Unbounded growth in the unrotatable file.** On an install with several Jira boards,
   `daemon.log` keeps taking per-cycle lines forever, which softens wave 5's premise that its
   volume is now low enough for open-time rotation alone.
2. **An operator looks in the wrong place.** `docs/daemon-pipeline.md`'s data-paths table and the
   Desktop Settings → Logs captions both describe `watchtower.log` as the daemon's log. Someone
   hunting a `[jira-analyzer]` or `[jira]` line will not find it there. Both texts were widened to
   name this residue rather than claim it away; the real fix is to remove the residue.

## Fix shape

Route these through the daemon's logger the way `Syncer` already is: extend `wireJiraSyncers` to
call the matching `SetLogger` on the analyzer, client, mapper and key detector, and give the
`internal/db` / `internal/ai` sites an injected logger instead of the package default. That is a
wiring change across several packages with its own review surface, which is why wave 5 left it
out of a commit whose point was to stop one stream duplicating into another.

A cheaper partial step, if the full wiring is too wide: `BoardAnalyzer` alone accounts for most of
the volume.
