# SQLite write-lock metrics (2026-10-15, board #527 step 1)

- **Why.** Every Watchtower process writes the one shared SQLite file: the daemon, `watchtower mcp`, the workbench hooks Claude Code and Codex run, one-off CLI commands and the Desktop app. When one of them holds the write lock too long, another fails with `SQLITE_BUSY` after its busy timeout — and those timeouts differ per caller (5 s by default, 1 s for session-record hooks, 500 ms for the ask guard, 30 s for owner writes, 5 s on the Desktop). Board #527 step 1 builds measurement only, so the later steps (#529–#532) pick fixes from data instead of guesses. **No behaviour change**: no new retries, no timeout changes, no batching. Live numbers stay on the board and in asks, never in the repo.
- **One log, every process.** Events go, one JSON object per line, to `<workspace>/dblock.jsonl` — the directory of the DB file (the same directory as `watchtower.log`). Go processes write through `internal/db/lockmetrics`; the Desktop writes the same format from `WatchtowerDesktop/Sources/WatchtowerCore/Database/DBLockMetrics.swift`. `watchtower db lockstats` reads it. An in-memory database has no sink.
- **Default on, threshold 200 ms.** A `tx`/`exec` event is written only when its wait or its hold is at or above the threshold; every busy/locked error is written whatever the threshold. `WATCHTOWER_DBLOCK_THRESHOLD_MS` overrides it, read once per process, the same way on both sides: unset or empty → 200; an integer ≥ 0 → that many ms (`0` records every write transaction); `off` (any case) → nothing is recorded, no WAL sample taken; anything else → 200 and a warning (Go). Below the threshold the cost is two clock reads and a PC capture per transaction.
- **The sink is best effort.** `Record` never returns an error and never panics; the first sink failure in a process is logged once (`slog.Warn` in Go, once per sink in Swift) and later ones are dropped, so a metrics failure can never break a DB write. The Swift sink writes off the caller's thread on one serial queue.

## Event format

`Event` in `internal/db/lockmetrics/lockmetrics.go` is the contract; its JSON keys are shared with the Swift writer and the `db lockstats` reader — do not rename them. Zero values are omitted on both sides.

| Key | Meaning |
|---|---|
| `ts` | When the event was recorded (after COMMIT/ROLLBACK for a `tx`, when the error returned for a `busy`). UTC with exactly three fractional digits, `2026-10-15T10:00:00.123Z` — a strict fractional-seconds parser rejects Go's default encoding of a zero fraction, so both writers pin the layout. |
| `pid` | Writer's process id. |
| `proc` | Process role (below). |
| `kind` | `tx`, `exec`, `busy`, `pool_wait`, `wal`. |
| `wait_ms` | `tx`: time to take the write lock (the BEGIN IMMEDIATE, or a deferred Desktop transaction's first write). `busy`: how long the caller waited before giving up (Desktop). `pool_wait`: database/sql connection-pool wait since the previous sample. |
| `hold_ms` | `tx`: BEGIN done → COMMIT/ROLLBACK done. `exec`: the whole autocommit write, which is both wait and hold. |
| `site` | Who wrote. Go: the first stack frame outside the runtime, `database/sql`, modernc and the wrapper, `watchtower/` cut (`internal/sync.(*Syncer).saveMessages`); a generic helper is followed by its caller (`internal/db.(*DB).WithTx <- internal/x.F`). Desktop: `desktop:<table>` — the first table the transaction wrote — or `desktop:?`. |
| `err` | `busy`: `SQLITE_BUSY` / `SQLITE_LOCKED`, with the extended name when it differs (`SQLITE_BUSY_SNAPSHOT`). `wal`: a stat or checkpoint error. |
| `busy_timeout_ms` | `busy`: the connection's busy timeout at the time — Go tracks the DSN's `_pragma=busy_timeout(N)` and every later `PRAGMA busy_timeout=N`. |
| `wal_bytes` | `wal`: size of the `-wal` file (absent = 0 or none yet). |
| `checkpoint` | `wal`: `busy=N log=N ckpt=N`, the three columns of `PRAGMA wal_checkpoint(PASSIVE)`. |

**Process roles** (`proc`). Go sets the role once at start (`cmd/root.go` → `roleFor` in `cmd/process_role.go`, before `Execute`, because the hook subcommands replace the root's `PersistentPreRunE`): `daemon` (`sync --daemon`), `mcp`, `hook:<subcommand>` for the hook commands (`workbench brief|check|ask-guard|session-state`), `cli:<command path>` for everything else (`cli:sync`, `cli:workbench cleanup`), `cli` for the bare root. The Desktop is `desktop`. A new hook subcommand belongs in `hookCommands`.

## How each side measures

- **Go — a wrapping driver.** `internal/db` opens every handle (`Open`, `OpenExisting`, `OpenExistingRW`, the schema upgrade) with the `sqlite+metrics` driver (`lockmetrics.DriverName`, `internal/db/lockmetrics/driver.go`): modernc's registered `sqlite` driver wrapped so every DSN, pragma, error and transaction mode passes through unchanged. It times a non-ReadOnly `BeginTx` (wait) and BEGIN → COMMIT/ROLLBACK (hold) as a `tx`; an autocommit `Exec`, or a `Query` that writes (`UPDATE … RETURNING`), as an `exec`; and records any `SQLITE_BUSY`/`SQLITE_LOCKED` from BeginTx, Exec, Query, Commit or Rollback as a `busy`. The stack is captured as PCs at BEGIN and symbolized only when an event is written. A connection whose DSN sets `query_only` (`OpenExisting`, dev-mode MCP) never takes the write lock: its transactions are not timed, only its busy errors recorded. A ReadOnly transaction stays deferred and is not timed either. A connection lacking one of the driver interfaces the wrapper forwards (a different modernc version) goes back unwrapped — it keeps working, unmeasured.
- **Go — per-cycle samples.** The daemon calls `(*DB).SampleLockStats` (`internal/db/lockstats.go`) once per sync cycle (`Daemon.sampleLockStats`, skipped on a cancelled ctx): a `pool_wait` event with database/sql's `WaitDuration` growth since the previous cycle (only when 1 ms or more, since `wait_ms` is whole milliseconds — with `SetMaxOpenConns(1)` writers inside one Go process queue on the pool, not on SQLite, so this is hidden latency, never a busy), and a `wal` event with the `-wal` size and a `PRAGMA wal_checkpoint(PASSIVE)`, which never waits on or blocks a writer. Only the daemon samples.
- **Desktop — the writer only.** `DBLockInstrumentation.install` (wired in `DatabaseManager.swift`) gives the GRDB writer connection a **busy callback in place of `PRAGMA busy_timeout`**: it sleeps on SQLite's own default schedule (`SQLiteBusyWait`) within the same 5000 ms budget and records a `busy` with the measured wait when it gives up. One difference from the pragma: the callback is in place from the connection's start, so the writer's own setup pragmas now wait for a busy lock where they used to fail at once — more tolerant, never less. Readers keep the plain pragma and are not measured. The writer also gets a profile trace (`WriteTransactionTracker`): a `BEGIN IMMEDIATE`/`EXCLUSIVE` takes the lock — its duration is the wait and the hold runs to COMMIT/ROLLBACK; a deferred BEGIN (GRDB runs one on the writer for every `ValueObservation` start and `isolated(readOnly:)`) is measured only from its first write statement, and a deferred transaction that never writes records nothing. `ROLLBACK TO` keeps the transaction open.

## File location and rotation — a Go↔Swift dual path

The write protocol is spelled out in the `internal/db/lockmetrics` package doc, and `DBLockMetrics.swift` follows it. **Both writers must change together**: a key, the `ts` layout, the cap, the file names or the rotation rule changed on one side only corrupts or loses the other side's lines.

- One line = one JSON object + `\n`, written with a single `write()` on a file opened `O_APPEND|O_CREAT|O_WRONLY`, mode 0600, so concurrent processes never interleave.
- A writer keeps the file open, stats the path before each write and re-opens when the path is gone or names another inode (another process rotated it).
- Past 10 MB (`MaxFileBytes`) a writer takes a **non-blocking** exclusive `flock` on the sidecar `dblock.jsonl.lock` (0600, same directory, never deleted). Holding it, it re-stats the path and renames it to `dblock.jsonl.1` (replacing the previous generation) only if the path is still the inode it saw over the cap and still over the cap. A writer that cannot get the lock skips rotation and just appends. The re-check under the lock keeps a second rotator from moving a fresh, small file over the generation the first just rotated. So at most ~20 MB of history survives.

## What is not measured

Known gaps, by design or for now:

- A prepared statement's `Exec` outside a transaction (Go) — the repo prepares only inside transactions, which the `tx` event covers.
- A busy error from a later `rows.Next` (a WAL read step) — only a query's first step is seen.
- A Go autocommit statement starting with `WITH` is treated as a read (a CTE almost always is), so a `WITH … INSERT` outside a transaction is not timed; its busy error still is.
- Desktop autocommit writes (a write outside a transaction) — the tracker only sees transactions. Their busy errors are still recorded by the busy callback.
- A Desktop `WITH … INSERT` is not recognised as a write: in an immediate transaction the site falls back to `desktop:?`; in a deferred transaction it never starts the hold, so no line.
- A Desktop `busy` always names `desktop:?`: the busy callback does not know the statement.
- Desktop readers, a Go `query_only` connection's and ReadOnly transactions' timings, and holds under the threshold — so a `busy` with no recorded holder means no *slow* holder was logged, not that nobody held the lock.
- `pool_wait` and `wal` come from the daemon only.

## `watchtower db lockstats`

`watchtower db lockstats [--since 24h] [--json]` (`cmd/db_lockstats.go`, `internal/lockstats`) reads `dblock.jsonl.1` then `dblock.jsonl` of the active workspace and summarises the events with `ts` in `[now − since, now]` (`--since` must be positive; default 24 h). With neither file it prints `no lock events recorded yet (<path>)` and exits 0. A line that is not a JSON object, has no `ts` or names an unknown kind is counted as malformed and skipped (a writer may be mid-append; a future writer may add kinds). Events are re-sorted by `ts`, since two files and several processes are not globally ordered.

`--json` keys are pinned by `TestReport_JSONKeysPinned` — add, never rename:

- `window` — `from`, `to`, `since_seconds`, `events` (inside the window), `files` (the files read).
- `malformed` — skipped lines.
- `sites[]` — slow `tx`/`exec` per site across processes, by total hold: `site`, `count`, `total_hold_ms`, `max_hold_ms`, `max_wait_ms`, `over_1s`, `over_5s`. A missing site is `(unknown)`.
- `busy[]` — busy errors per process role and site: `proc`, `site`, `count`, `busy_timeouts_ms` (distinct, ascending), `errs` (distinct, ascending).
- `busy_holders[]` — each busy with the other pids' slow holds that overlapped its wait: `ts`, `pid`, `proc`, `site`, `err`, `busy_timeout_ms`, `holders[]` (`ts` = when the hold ended, `pid`, `proc`, `kind`, `site`, `hold_ms`). Overlap: a hold ran `[ts − hold_ms, ts]`, a busy waited `[ts − busy_timeout_ms, ts]`.
- `wal` — `samples`, `min_bytes`, `median_bytes`, `max_bytes`, `checkpoints`, `checkpoint_busy` (busy ≠ 0), `checkpoint_incomplete` (ckpt < log), `checkpoint_unparsed`, `last_checkpoint`.
- `pool_wait[]` — per role: `proc`, `count`, `total_wait_ms`, `max_wait_ms`.

The text form prints the same sections as tables, capped at 15 sites and the latest 20 busy errors (`--json` has every row).

**Reading the report.**
- *Slow write sites* answers "who holds the lock": a high `total_hold_ms` is the site that costs everyone the most; `over_1s` is the count that can fail a session-record hook (1 s budget) by itself, `over_5s` the count that can fail a default-budget caller. A high `max_wait_ms` with a short hold means the site queues behind someone else.
- *Busy errors* answers "who fails": a `hook:*` row next to `busy_timeouts_ms` of 1000 or 500 is a hook losing to its short budget; `SQLITE_BUSY_SNAPSHOT` means a deferred read-then-write transaction lost the upgrade (it should be `BEGIN IMMEDIATE`, see CLAUDE.md "Database & Migrations").
- *Who held the lock* pairs each failure with the culprit. "no recorded holder" means the holder was under the threshold, the Desktop wrote outside a transaction, or the holder was one of the unmeasured paths above — lower `WATCHTOWER_DBLOCK_THRESHOLD_MS` in the processes involved to see more.
- *WAL size* growing with many `incomplete` checkpoints means a long reader or writer keeps the WAL from being reset; `busy` checkpoints mean one ran into a held lock.
- *Pool waits* are in-process queueing on the single connection: latency, never `SQLITE_BUSY`.

Plan: `docs/plans/2026-10-15-db-lock-metrics.md`.
