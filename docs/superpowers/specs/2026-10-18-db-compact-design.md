# Compacting `watchtower.db` at launch — technical spec

Board #850 (group #527). Business spec: `2026-10-18-db-compact-business.md` (the owner reviews that one). Owner decision: ask #349. Decisions and contracts only.

## Why

Migration 00134 rewrote `messages.raw_json` to `'{}'` for every row. Rows shrank but stayed one per page: on a long-running install `messages` keeps roughly one leaf page per row, so most of a multi-GB file is unused space inside pages (`dbstat`); `freelist_count` is 0, so the waste is invisible to `PRAGMA freelist_count`. Only `VACUUM` reclaims it. `auto_vacuum` is NONE and nothing runs `VACUUM` today. An earlier review ruled `VACUUM` out of the migration itself (cost; `docs/review/review-lessons.md:1852`), and the Desktop kills `db migrate` after 30 s, so compaction must be its own step.

## Goals

- G1. When compaction pays off, the first launch after it became due compacts `watchtower.db` before the Desktop opens its pool and before the daemon starts.
- G2. No data risk: an interrupted compaction leaves the database unchanged and is retried at the next launch.
- G3. No disk risk: skipped, with a notice, when free space is short.
- G4. Visible and skippable: launch screen line with size and elapsed time; "Skip for now" after 15 s.
- G5. Go owns every rule (when, whether, how); Swift runs the CLI and shows its state.

## Non-goals

Compaction while the app runs, on a schedule, or in the daemon. `auto_vacuum`/`incremental_vacuum` (switching modes needs a full `VACUUM` anyway; revisit later). Scrubbing free blocks on disk (#595). `agentlog.db` (#849; small, its own file).

## Decisions

### D1. When compaction is due (`db compact --check`)

Due when either holds:
- **Known space-freeing migration:** a Go list `compactAfterMigrations = []int64{134}`. Due if any listed version is applied (`goose_db_version.is_applied = 1`) and greater than the stored `last_compacted_version` (D4). A new migration that frees a lot of space adds its version here — a one-line rule in `.claude/skills/add-migration` and the migration doc comment.
- **Free pages:** `freelist_count * page_size > 256 MiB` and `freelist_count > 0.25 * page_count`.

`--check` never writes and never migrates (spec call): it opens with `db.OpenExisting` (read-only, no migration, no file creation). No `watchtower.db` → `due: false`, exit 0. Missing `db_maintenance` table (a database not yet migrated to it) → treated as never compacted. A database whose embedded migrations are not all applied → `due: false`, `reason: "schema_pending"` (compaction waits for a launch whose `db migrate` finished). Output (`--json`): `{"due": bool, "reason": "migration:134"|"freelist"|"", "db_bytes": N, "wal_bytes": N, "free_disk_bytes": N, "needs_disk_bytes": N, "disk_ok": bool}`. `db_bytes` = file size of `watchtower.db`; `needs_disk_bytes` = `2 * db_bytes` (D3).

A fresh database is due after 00134 like any other; compacting a near-empty file takes milliseconds, so no special case.

### D2. Running it (`db compact`)

1. Refuse with a clear error when the daemon is running (pid file + live process, the existing check `sync --stop` uses), unless `--force`.
2. Refuse when `disk_ok` is false (D3), unless `--force`.
3. Open with `db.OpenExistingRW` (no migration, no file creation), `SetBusyTimeout(30 s)`. If the schema is not current (the same check `setupSchema` uses before migrating), refuse: `"skipped": "schema_pending"`, exit 5 — compaction never finishes migrations the Desktop's 30 s `db migrate` did not get through. The `db_maintenance` write in step 5 therefore always finds its table.
4. `PRAGMA wal_checkpoint(TRUNCATE)`; `VACUUM`; `PRAGMA wal_checkpoint(TRUNCATE)`. `VACUUM` runs outside any transaction (it cannot run inside one) and is atomic: interruption (SIGTERM, crash, power) leaves the old content.
5. On success, record `last_compacted_version` = the highest applied goose version and `compacted_at` (D4), then print `{"compacted": true, "reason", "bytes_before", "bytes_after", "duration_ms"}` (`--json`).
6. Exit codes: 0 compacted or nothing due (`{"compacted": false, "skipped": "not_due"}`), 2 skipped for disk (`"skipped": "disk"`), 3 refused because the daemon runs (`"skipped": "daemon_running"`), 1 any other error.
7. SIGTERM: the command installs the shutdown context (`notifyShutdownContext`, cmd/shutdown.go) and runs `VACUUM` with `ExecContext`, so cancellation fires `sqlite3_interrupt`; the result is `"skipped": "interrupted"`, exit 4. The interrupt is checked while the compacted copy is built, **not** during VACUUM's final copy-back into the main file (seconds at ~1 GB), so a skip may take several seconds; the Desktop bounds it (D5.3). Nothing is recorded, so the step is due again next launch.
8. **Rowids are preserved.** `messages` has no INTEGER PRIMARY KEY, and SQLite documents that `VACUUM` may change such rowids; saved cursors depend on them (`internal/doclinks/linkscan` `rowid > ?` cursors, the knowledge-index cursors, `synced_at|rowid` cursors). The SQLite in `modernc.org/sqlite` keeps rowids through `VACUUM` (verified on 3.51 with a composite PK, a stored generated column and deleted rows). Spec call: rely on it and pin it with a guard test (below); if that test ever fails after a driver upgrade, compaction must reset the affected cursors instead.

`--if-due` runs D1 first and does nothing when not due (exit 0, `not_due`). The Desktop always calls `--check` then `--if-due`.

### D3. Disk rule

`VACUUM` writes the compacted copy to a temporary file and then the pages through the WAL; peak extra space is bounded by twice the database's size. Rule: `free_disk_bytes >= 2 * db_bytes` on the volume holding `watchtower.db` (`statfs` / `syscall.Statfs` `Bavail * Bsize`). Short → skip with `disk`. `SQLITE_TMPDIR`/`temp_store` are not changed (temp files land next to the system default; if the system temp is on another volume the rule is conservative for the db volume and may miss the temp volume — the Desktop shows the SQLite error if `VACUUM` then fails with `SQLITE_FULL`, and nothing is lost).

### D4. State

New table via a goose migration (next free number at implementation time; follow `.claude/skills/add-migration`): `db_maintenance(key TEXT PRIMARY KEY, value TEXT NOT NULL)`, keys `last_compacted_version` (integer as text), `compacted_at` (RFC 3339 UTC). Mirrored into `schema.sql`, `TestAllTablesExist`, the golden and the Swift test schema. Absent key = never compacted (0).

### D5. Desktop launch step

In `AppState.initialize()`'s launch task, between the migration and opening the pool: today `DatabaseManager.migrateAndOpen()` does both, so split it: `runCLIMigrations()` → compaction step → `DatabaseManager(path:)`.

Compaction step (a `DatabaseCompactionStep` in WatchtowerCore with an injected process runner, plus the launch-screen state on `AppState`):
0. If `resolveDBPath` fails (fresh install, no workspace) → skip the step.
1. Run `db compact --check --json` (timeout 30 s; a failure or timeout skips the step and logs — never blocks the launch).
2. Not due → continue. Due but `disk_ok` false → continue and show a non-blocking notice once per launch: "Watchtower could not optimize its database: it needs N GB free, M GB available." (sizes via `ByteCountFormatter`).
3. Due and disk ok → stop the daemon (the existing bounded stop used by `ensureDaemonRunning`; it restarts the daemon after the launch anyway), then run `db compact --if-due --json` with **no** timeout, showing on the launch screen: "Optimizing database — 2.0 GB, 0:42" and below it "This happens rarely, usually after an update." The elapsed time ticks every second. From 15 s on, a "Skip for now" button sends SIGTERM to the child; if it has not exited 10 s later, SIGKILL (safe: `VACUUM` is atomic, the database stays as it was); the launch continues once it has exited.
   While the step runs, every Desktop path that can start the daemon (the tray's start/sync-now items, Settings, `ensureDaemonRunning`, onboarding finish) is gated by an `AppState` flag `databaseCompactionInProgress`: they do nothing (the tray item shows disabled) until the step ends.
4. Exit 3 (`daemon_running`, the stop failed) → continue the launch without compacting; logged.
5. Any result → continue to `DatabaseManager(path:)`, then the rest of the launch as today (`ensureDaemonRunning` starts the daemon).

Strings in English. The launch screen is the existing splash (`isLoading`); the step adds its line and button there.

### D6. Other processes during the step

- Daemon: stopped (D5.3).
- `watchtower mcp` servers and hooks of terminal sessions that survived the update (PROJ-20) keep idle connections; an idle connection does not block `VACUUM`. Their writes during the step wait up to their busy timeouts (MCP owner writes 30 s, hooks 1 s, ask guard 0.5 s) and may fail. Accepted: the state hooks rewrite the current state on their next event. Documented in the feature note.
- A CLI command started by the owner during the step: waits up to 5 s, may fail with busy. Accepted.

## Error handling

- `--check` fails (CLI missing, DB unreadable) → skip, log, launch continues (G1 is best effort; data first).
- `VACUUM` fails (`SQLITE_FULL`, `SQLITE_BUSY` after 30 s, I/O) → the DB is unchanged; exit 1 with the SQLite error on stderr; the Desktop logs it and continues; due again next launch. To avoid a launch-time loop on a persistent failure, after 3 consecutive failures (counter in `db_maintenance` key `compact_failures`, reset on success) the step is skipped until the next app version (key `compact_failures_version` = the app version that failed); the notice says so once.

## Tests that must exist

Go (`cmd/db_compact*_test.go`, `internal/db/compact*_test.go`):
- `--check` on a db with 00134 applied and no record → due, `migration:134`; after a compaction → not due.
- Freelist rule: delete enough rows to exceed both thresholds → due `freelist`; below either → not due (table test, thresholds as named constants).
- Compaction shrinks a sparse fixture (insert large `raw_json`, apply the 00134 UPDATE, compact): `bytes_after < bytes_before / 2`; row counts and a checksum of `messages(text)` equal before and after.
- Refuses with exit 3 while a daemon pid file points at a live process; `--force` overrides.
- Disk rule with an injected `statfs` seam: short → exit 2 `disk`, DB untouched.
- Interrupt: cancel during `VACUUM` (seam: a big fixture and a context cancelled after start) → exit 4 `interrupted`, DB opens and has every row, nothing recorded.
- Failure counter: three failures → `--check` reports not due for that version; a new version resets.
- `db migrate` still never compacts (guard that `migrate` stays within its 30 s contract).
- `--check` on a path with no database creates no file and reports not due; on a database with a pending migration reports `schema_pending` and leaves `goose_db_version` unchanged.
- `db compact` on a database with a pending migration → exit 5 `schema_pending`, nothing migrated.
- **Rowid guard** `TestCompact_PreservesRowids`: seed `messages` (composite PK) with gaps from deletes, plus one row in each table that has a rowid-based cursor today (find them by grepping `rowid` in `internal/`), compact, assert every `(rowid, primary key)` pair is unchanged.

Swift (`Tests/Core`, `make test-swift FILTER=DatabaseCompactionStep`):
- not due → no daemon stop, no compact run;
- due + disk short → notice text, no compact run;
- due → stop then compact, in that order; a `--check` failure → continue;
- Skip after 15 s sends terminate to the child; a child that ignores it is killed 10 s later; the button is hidden before 15 s;
- while the step runs, the daemon-start paths are no-ops (`databaseCompactionInProgress`), and work again after it;
- `resolveDBPath` failure → no CLI call at all;
- elapsed formatting `0:42`, `1:05`.

## Inventory and docs

- New inventory entries are not needed unless the owner wants the launch contract pinned; add a line to `docs/features/tray-daemon-lifecycle.md` (launch order: migrate → compact → open → daemon) and a feature note `docs/features/db-compact.md` (rules, thresholds, D6 accepted effects).
- `.claude/skills/add-migration/SKILL.md`: a migration that frees a lot of space adds its version to `compactAfterMigrations`.
- `docs/app-guide.md`: the launch line and Skip.
