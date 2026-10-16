# SQLite write-lock metrics (board #527, step 1 = #528)

**Goal.** Before tuning anything, measure who waits for the SQLite write lock,
who holds it and for how long, and who gets `SQLITE_BUSY` — in every process
that writes the shared database (daemon, `watchtower mcp`, workbench hooks,
one-off CLI, Desktop). Steps 2–5 of #527 (#529–#532) decide fixes from this
data; this plan only builds the measurement and the summary.

**Non-goals.** No behaviour change: no new retries, no timeout changes, no
batching. Live-install numbers never go into the repo (board and asks only).

## What we already know from the code

- Go: every process opens the file through `internal/db` (`Open`,
  `OpenExisting`, `OpenExistingRW`), `SetMaxOpenConns(1)`, `_txlock=immediate`.
  So inside one Go process writers queue on the `database/sql` pool, not on
  SQLite — H5 (goroutines fighting over pool connections) cannot cause
  `SQLITE_BUSY`, but the pool wait is hidden latency and is measured too.
- Busy timeouts differ per caller: 5 s default, 30 s for owner writes
  (`ownerWriteBusyTimeout`), **1 s for session-record hooks**
  (`sessionRecordBusyTimeout`), 500 ms for the ask guard. A hook therefore
  fails behind any write held > 1 s, not > 5 s — H3 is cheaper to trigger
  than the board intent assumed.
- 61 `Begin`/`BeginTx` call sites (49 in `internal/db`), plus autocommit
  `Exec` writes everywhere.
- Desktop: one GRDB `DatabasePool` (`DatabaseManager.swift`), `busy_timeout`
  5000 via pragma, ~244 write call sites.

## Design

### Event format (shared Go ↔ Swift)

One JSON object per line, appended to `<workspace>/dblock.jsonl` (same
directory as `watchtower.log`; Desktop resolves it the way it resolves the DB
path). One `write()` per line with `O_APPEND`, so concurrent processes never
interleave. Size cap 10 MB → rotate to `dblock.jsonl.1` (one generation);
rotation is best-effort and never fails the caller.

```json
{"ts":"2026-10-15T10:00:00.123Z","pid":123,"proc":"hook:session-state",
 "kind":"tx|exec|busy|pool_wait|wal",
 "wait_ms":12,"hold_ms":1840,"site":"internal/sync.(*Syncer).saveMessages",
 "err":"SQLITE_BUSY","busy_timeout_ms":1000,"wal_bytes":0}
```

- `proc` — process role, set once at start: `daemon`, `mcp`,
  `hook:<subcommand>`, `cli:<subcommand>`, `desktop`.
- `wait_ms` — time spent acquiring the write lock (BEGIN IMMEDIATE, or the
  first write statement of an autocommit Exec).
- `hold_ms` — BEGIN done → COMMIT/ROLLBACK done.
- `site` — first stack frame outside `database/sql`, `internal/db`'s
  instrumentation and the driver (Go); `#fileID:#line` of the caller (Swift).
- Thresholds: a `tx`/`exec` event is written only when `wait_ms` or `hold_ms`
  ≥ 200 ms; every busy/locked error is written. Override with
  `WATCHTOWER_DBLOCK_THRESHOLD_MS` (0 = log everything, `off` = disable).
  Default on: below the threshold the cost is two `time.Now()` and a PC
  capture per transaction.

### Go: an instrumented driver, zero call-site changes

`internal/db/lockmetrics` registers a wrapping `database/sql/driver` around
modernc's `sqlite` driver (`sqlite+metrics`), and `internal/db`'s `sql.Open`
calls switch to it. The wrapper's conn implements `BeginTx` (wait timing),
the returned `Tx` (hold timing on `Commit`/`Rollback`), and `ExecContext`
outside a transaction (autocommit; only statements that are not `SELECT`/
`PRAGMA` reads). Busy is recognised from modernc's `*sqlite.Error` code
(`SQLITE_BUSY` 5 and its extended codes, `SQLITE_LOCKED` 6).
`DB.Stats().WaitDuration` deltas are emitted as `pool_wait` from the
daemon's heartbeat. The process role is set by `cmd` from the cobra command
path in a `PersistentPreRun` (`db.SetProcessRole`).

H4: the daemon's sync heartbeat logs a `wal` event each cycle with the size
of `<db>-wal` and the result of `PRAGMA wal_checkpoint(PASSIVE)` (busy,
log, checkpointed frames) — a passive checkpoint never blocks writers.

### Desktop: GRDB hooks, zero call-site changes

In `DatabaseManager.init(path:)`:
- `config.busyMode = .callback { retries in … }` replaces
  `PRAGMA busy_timeout = 5000`: the callback sleeps the way SQLite's default
  busy handler does and gives up after the same 5 s; it records how long the
  writer waited and, on give-up, a `busy` event. Behaviour stays equal.
- A statement-profile trace (`db.trace(options: .profile)`) on the writer
  connection only, matching `BEGIN`/`COMMIT`/`ROLLBACK`, measures wait and
  hold. `site` comes from a task-local set by the existing write helpers
  where one exists; otherwise `desktop` with the first statement's table —
  enough to rank, without touching 244 call sites.
- Events go to the same `dblock.jsonl` through a small serial writer in
  `WatchtowerCore`.

### Summary command

`watchtower db lockstats [--since 24h] [--json]` reads `dblock.jsonl`
(+ `.1`) and prints:
1. top sites by total and max `hold_ms`, with counts > 1 s and > 5 s;
2. every busy error grouped by `proc` × `site`, with its `busy_timeout_ms`;
3. who held the lock when each busy happened (the overlapping `tx` events
   from other pids);
4. WAL size min/median/max and checkpoint results;
5. pool waits per process.

Step 2 (#529) is running this on the live install for 1–2 days.

## Tasks

1. **Go event sink** — `internal/db/lockmetrics`: event type, JSON line
   writer with O_APPEND + size rotation, threshold/env parsing, process role.
   Tests: concurrent writers produce whole lines; rotation; `off`.
   *Depends on: none.*
2. **Go instrumented driver** — wrapping driver (BeginTx/Tx/ExecContext),
   site capture, busy detection; `internal/db` opens through it in all three
   open functions; `cmd` sets the role. Tests: a hold above threshold is
   logged with the right site; a forced busy (second connection holding
   `BEGIN IMMEDIATE`, short busy timeout) is logged with `err`; below
   threshold nothing is written; `go test ./internal/db/...` and the `cmd`
   packages that open the DB stay green. *Depends on: 1.*
3. **Daemon WAL + pool sampling** — `wal` and `pool_wait` events from the
   sync heartbeat. Test with a fake heartbeat tick. *Depends on: 1.*
4. **`watchtower db lockstats`** — parser + report + `--json`. Tests on a
   fixture log with synthetic placeholder data (no live data in the repo).
   *Depends on: 1.*
5. **Desktop instrumentation** — busy callback replacing the pragma, profile
   trace on the writer, the shared sink in `WatchtowerCore`. Tests in
   `Tests/Core`: a held writer from a second pool produces a `busy` event; a
   slow write above threshold produces a `tx` event; behaviour of the busy
   wait (gives up after 5 s) unchanged. *Depends on: 1 (format only).*
6. **Docs** — `docs/features/` note (format, env var, `lockstats`), a line in
   CLAUDE.md's feature list. *Depends on: 2, 4, 5.*

Tasks 2–4 are Go-only and may run in parallel lanes; task 5 is the single
Swift lane. One PR for #528.

## Risks

- **Overhead on hot paths.** PC capture per transaction; measured with a
  benchmark in task 2, must stay < 5 µs per transaction.
- **Log write failures** (disk full, permissions) are swallowed after one
  `slog.Warn` per process — metrics must never break a write.
- **Inventory.** The driver wrap changes how `internal/db` opens the file;
  `_txlock=immediate`, pragmas and `query_only` handles must behave exactly
  as before (existing tests cover them; no guard test is relaxed).
- **GRDB busy callback** must not change Desktop's waiting behaviour; if it
  cannot match, fall back to keeping the pragma and measuring only via the
  profile trace (busy then shows up as the thrown `DatabaseError` at the
  write helpers that already log errors).
