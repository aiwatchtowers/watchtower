# Database compaction at launch (2026-10-18, board #850)

- **Why.** SQLite never gives space back to the disk on its own: `auto_vacuum` is NONE, and nothing ran `VACUUM`. A migration that shrinks rows in place (00134 rewrote every `messages.raw_json` to `'{}'`) leaves the file as large as before, and the waste is not even visible in `PRAGMA freelist_count` — the rows stay one per page. Only `VACUUM` reclaims it. It cannot run inside a migration (cost; the Desktop kills `db migrate` after 30 s), so compaction is its own launch step, between the migration and opening the Desktop's pool.
- **Go owns every rule** (when, whether, how) in `internal/db/compact.go` and `cmd/db_compact.go`; the Desktop runs the CLI and shows its state (`DatabaseCompactionStep` in WatchtowerCore, `AppState+DatabaseLaunch.swift`). Design: `docs/superpowers/specs/2026-10-18-db-compact-design.md`.
- **Out of scope:** compaction while the app runs, on a schedule or in the daemon; `auto_vacuum`/`incremental_vacuum`; `agentlog.db`.

## D1. When compaction is due (`db compact --check`)

`db.CheckCompaction` decides, by reads only: it opens with `db.OpenExisting` (read-only, 5 s busy timeout), so it never creates the file, migrates or writes. In order:

1. No `watchtower.db` → not due, `disk_ok: true`.
2. Embedded migrations not all applied → not due, `reason: "schema_pending"` (compaction waits for a launch whose `db migrate` finished).
3. `compactMaxFailures` (3) consecutive failures under this CLI version → not due, `reason: "gave_up"` (see the failure cap below).
4. **Known space-freeing migration:** a version in `compactAfterMigrations` (`[]int64{134}`) is applied (`goose_db_version.is_applied = 1`) and greater than `last_compacted_version` → due, `reason: "migration:<v>"` (the highest such version). A missing `db_maintenance` table or key reads as never compacted (0).
5. **Free pages:** `freelist_count * page_size > compactFreelistMinBytes` (256 MiB) **and** `freelist_count > compactFreelistMinRatio * page_count` (0.25) → due, `reason: "freelist"`.

A fresh database is due after 00134 like any other; compacting a near-empty file takes milliseconds.

**A migration that frees a lot of space** (rewrites or deletes most of a big table) adds its version to `compactAfterMigrations`, so the next launch compacts once. The rule is in `.claude/skills/add-migration` and the doc comment above the list.

## D2. Running it (`db compact`)

```
watchtower db compact [--check | --if-due] [--force] [--json]
```

- `--check` reports and writes nothing; it takes neither `--if-due` nor `--force` (that misuse is exit 1). `--if-due` runs the D1 check first and does nothing when not due (`schema_pending` and `gave_up` included): exit 0, `"skipped": "not_due"`. Without either flag the command compacts without the due check (`reason: "manual"`; the daemon and disk rules still apply). The Desktop always runs `--check`, then `--if-due`.
- **Daemon rule:** refuses with exit 3 when the daemon runs — `daemon.FindConfirmedProcess` on `daemon.pid`, the check `sync stop` uses. Only a confirmed live daemon process, or a live pid whose identity cannot be confirmed (`daemon.ErrIdentityUnconfirmed`), counts as running; a missing, stale (dead or reused pid), unreadable or malformed pid file does not, so a broken pid file never blocks compaction at every launch. `--force` overrides.
- **Disk rule (D3):** `free_disk_bytes >= 2 * db_bytes` on the volume holding `watchtower.db` (`statfs`, `Bavail * Bsize`; `VACUUM` writes a compacted copy, then the pages through the WAL). Short → exit 2 `disk`, before the database is opened. `--force` overrides. `SQLITE_TMPDIR`/`temp_store` are not changed: a system temp on another volume is not counted, and a `VACUUM` that then fails with `SQLITE_FULL` is an ordinary failure (exit 1, nothing lost).
- **Open:** `db.OpenExistingRW` with a 30 s busy timeout (`compactBusy`) — never `db.Open`, never `openDBFromConfig`. A schema that is not current → exit 5 `schema_pending`: compaction never finishes migrations the Desktop's 30 s `db migrate` did not get through.
- **Run:** `PRAGMA wal_checkpoint(TRUNCATE)`, `VACUUM`, `PRAGMA wal_checkpoint(TRUNCATE)`. `VACUUM` runs outside any transaction and is atomic: a SIGTERM, crash or power loss leaves the old content. A checkpoint that reports busy (a reader still on an older snapshot) is not an error; the final one waits up to the busy timeout, and when it still reports busy the result carries `checkpoint_busy: true` — the file shrinks at a later checkpoint (the Desktop logs it).
- **Busy is not a failure:** a `VACUUM` or checkpoint that gives up on another process's lock (`SQLITE_BUSY`/`SQLITE_LOCKED`, `db.IsBusy`) is exit 1 with `error` saying busy, and is **not** counted against the failure cap — the file is fine and the next launch tries again.
- **Record:** on success, in one transaction, `last_compacted_version` = the highest applied goose version, `compacted_at` (RFC 3339 UTC), and the failure counter removed.
- **SIGTERM:** the command installs the shutdown context (`notifyShutdownContext`) before the `--if-due` check, and `VACUUM` runs with `ExecContext`, so a SIGTERM fires `sqlite3_interrupt` → `"skipped": "interrupted"`, exit 4, nothing recorded, due again next launch. The interrupt is honoured while the compacted copy is built, not during VACUUM's final copy-back into the main file (seconds on a large file), so a skip may take a few seconds. An interrupt racing VACUUM's commit can report `interrupted` for a file that was compacted; nothing is recorded, and the next launch re-runs it cheaply.

### Exit codes and JSON

| Exit | `skipped` | Meaning |
|---|---|---|
| 0 | — / `not_due` | Compacted, or nothing due |
| 1 | — | Any other error (`error` filled; flag misuse, config, workspace, the `--check` read, `VACUUM` failure, busy) |
| 2 | `disk` | Not enough free disk (D3) |
| 3 | `daemon_running` | The daemon runs |
| 4 | `interrupted` | SIGTERM; the database is unchanged |
| 5 | `schema_pending` | Migrations pending; run `watchtower db migrate` |

With `--json` the result is the **last** stdout line on every outcome, errors included; the Desktop decodes the last non-empty line, so a line printed before it is not part of the contract. `db compact` sets its own no-op `PersistentPreRunE`, so the root's `ensureSchemaFormat` (a schema-format upgrade and a config write) does not run for it: `--check` writes nothing, the config included. Keys (snake_case, `internal/db/compact.go`; `TestDBCompact_WireKeys` pins them):

- `--check`: `due`, `reason` (`migration:<v>`, `freelist`, `schema_pending`, `gave_up` or `""`), `db_bytes`, `wal_bytes`, `free_disk_bytes`, `needs_disk_bytes` (= 2 × `db_bytes`, `needsDiskBytes`), `disk_ok`. A `--check` that fails (flag misuse, config, workspace, the read) prints the run shape instead: `{"compacted":false,"error":"…"}`, exit 1.
- run: `compacted`, then as they apply `skipped`, `reason`, `bytes_before`, `bytes_after`, `duration_ms`, `error`, `failures`, `gave_up`, `checkpoint_busy`.

## D4. State — `db_maintenance` (migration 00142)

`db_maintenance(key TEXT PRIMARY KEY, value TEXT NOT NULL)`, values as text: `last_compacted_version`, `compacted_at`, `compact_failures`, `compact_failures_version`. Absent key = never compacted / no failures. A value that is not an integer where one is expected is an error, not a zero.

**Failure cap.** A failed compaction (`VACUUM` error, an I/O error after the `VACUUM`, a failed record) increments `compact_failures` under `compact_failures_version` = the CLI build version (`cmd.Version`; the bundled CLI ships with the app, so this is the app release); a new version restarts the count at 1, and a success removes both keys. At 3 the result carries `gave_up: true` and `--check` reports `gave_up` (not due) until the version changes, so a persistent failure cannot cost every launch.

## D5. The Desktop launch step

Launch order: `db migrate` → **compaction step** → `DatabaseManager(path:)` (the pool) → `ensureDaemonRunning` (`AppState.migrateCompactOpen`). The step never fails the launch:

0. `DatabaseManager.resolveDBPath()` fails → no CLI call at all; `databaseNotFound` (a fresh install) is silent, any other error is logged.
1. `db compact --check --json`, 30 s timeout; a spawn failure, timeout, non-zero exit or undecodable line is logged and the launch continues (a quit during it logs "cancelled by quit").
2. Not due → continue. Due but `disk_ok` false → continue with a notice: **Watchtower could not optimize its database: it needs <N> free, <M> available.** (sizes via `ByteCountFormatter`, `.file` style).
3. Due and disk OK → `DaemonManager.stopDaemonBounded()` — on the daemon-start queue (`serializeDaemonStop`), so a start already running finishes first; the step records `stoppedDaemon` — then `db compact --if-due --json` with **no** timeout. The splash (`SplashView`, the existing `isLoading` screen) shows **Optimizing database — <size>, <m:ss>** with **This happens rarely, usually after an update.** under it; the time ticks every second. From 15 s a **Skip for now** button sends SIGTERM; if the child is still alive more than 10 s later, SIGKILL (safe: `VACUUM` is atomic). The launch continues once the child has exited.
4. The exit is read with its termination reason (`CompactionExit.reason`): a child ended by a signal is logged as "killed by signal N" with stderr. Exit 2 shows the disk notice and exits 3, 4 and 5 are logged as their skip only when the result line's `skipped` agrees (`disk`, `daemon_running`, `interrupted`, `schema_pending`); any other combination is logged with the exit status and stderr. Exit 1 with `gave_up` shows **Watchtower could not optimize its database after 3 attempts. It will try again after the next update.**; exit 0 without a result line logs stderr; `checkpoint_busy` is logged ("the space is reclaimed at the next checkpoint"). Any result → open the pool, then the rest of the launch as before.
5. The database then fails to open after the step stopped the daemon, or after a restart was refused during the launch's database steps → on a finished install (onboarding complete) the daemon is brought back (`restoreDaemonStoppedForCompaction`): a refused restart (`deferredRestartDuringLaunch`) restarts it (`bringUpDaemonInBackground(startOnly: false)`) so it reads the new config, a stop alone only starts it. A launch that lands in onboarding with a database never had onboarding complete (`reconcileOnboarding` keeps a complete step), so it needs no restore.

The notice is non-blocking and shown once per launch, in the main window's detail header; it is hidden while a daemon banner shows (the banner takes the slot). It is not shown in the tray.

**Daemon starts are gated** from before `db migrate` until the open (`launchDatabaseStepsRunning`), and while the step runs (`databaseCompactionInProgress`) — `AppState.daemonStartBlocked`: `ensureDaemonRunning`, `bringUpDaemonInBackground`, `startDaemonFromBanner`, `restartOnChain` (Features turn-on and other config changes) and the Slack disconnect restart do nothing, and the tray's **Sync Now** is disabled. Starts queued on the daemon-start queue re-check the gate when they run, not only when enqueued. A restart refused this way (`restartOnChain`, `bringUpDaemonInBackground`) sets `deferredRestartDuringLaunch`: after a successful open the launch's own `ensureDaemonRunning` starts the daemon with the current config; after a failed open the D5.5 restore replays it as a restart. The account view models' `restartLoggingQueued` is not gated: they are built after the database opens.

**Quit during the step** (⌘Q, tray Quit): the quit path calls `terminateDatabaseCompactionForQuit` before it stops the daemon — a running `--check` is cancelled and a running `db compact` child gets SIGTERM, then SIGKILL if it has not exited within `DatabaseCompactionStep.quitGrace` (3 s), so neither outlives the app under launchd; the launch then neither runs the step nor starts the daemon.

## D6. Other processes during the step (accepted effects)

- **Daemon:** stopped for the step.
- **`watchtower mcp` servers and terminal-session hooks** that survived the update keep idle connections; an idle connection does not block `VACUUM`. Their writes during the step wait up to their busy timeouts (MCP owner writes 30 s, hooks 1 s, ask guard 0.5 s) and may fail. Accepted: an agent left running across the update may lose a status update; the state hooks rewrite the current state on their next event.
- **A CLI command started by the owner** during the step waits up to 5 s and may fail with busy. Accepted.

## Rowid guard

`messages` (and several other tables) have no `INTEGER PRIMARY KEY`, and SQLite documents that `VACUUM` may renumber such rowids — but saved cursors depend on them (`internal/doclinks/linkscan` `synced_at|rowid` cursors, memory's rowid identities, the knowledge-index cursors). The SQLite inside `modernc.org/sqlite` keeps rowids through `VACUUM`, and `TestCompact_PreservesRowids` (`internal/db/compact_rowid_test.go`) pins it: it seeds every table in `rowidTables` with gaps from deletes, compacts, and asserts every `(rowid, primary key)` pair is unchanged. A new table with a rowid-based cursor must be added to `rowidTables`.

**If the guard fails** (typically after a driver upgrade): do not ship that driver with compaction as is. Either keep the old driver, or make `Compact` reset the affected cursors after a successful `VACUUM` (they then rescan once) before upgrading.

## Tests

- Go: `go test ./internal/db -run 'TestCompact|TestCheckCompaction|TestSchemaCurrentErr'`, `go test ./cmd -run 'TestDBCompact|TestDBMigrate'` (`TestDBMigrate_NeverCompacts` keeps `db migrate` within its 30 s contract). Package-level seams (`freeDiskBytes` — from `cmd` through the test-only `db.SetFreeDiskBytesForTest` —, `compactBusy`, `compactAfterMigrations`, `compactFreelistMinBytes`/`compactFreelistMinRatio`, `compactVacuumHook`, `compactVacuumSQL`, `compactRecord`, `daemonRunningForCompact`) are mutated by tests: no `t.Parallel` in those tests.
- Swift: `make test-swift FILTER='DatabaseCompactionStep|DatabaseCompactionLaunch|ProcessCompactionCLI'` (the last runs `/bin/sh` stubs and reaps them in `tearDown`).
