# Database encryption, Stage 1 — engine swap, no key (board #603)

Goal: every Go process and every Swift app opens SQLite through one
SQLCipher-capable engine, with **no key yet**: every file stays plaintext and
nothing changes for the owner. In Go, `modernc.org/sqlite` is replaced by an
in-repo cgo fork of `mattn/go-sqlite3` built on the SQLCipher 4.x community
amalgamation. In Swift, the Desktop, the Kit and the phone move to a GRDB
fork linked against `SQLCipher.swift`. An idle connection in a long-lived
non-daemon process (MCP servers, warm `ai session`) closes after 30 s, so that
Stage 3 and `db compact` stop fighting MCP servers. `.goreleaser.yaml` is
deleted. Stage 2 (the key) and Stage 3 (one-time encryption) are separate
plans; the G1–G5 gate that Stage 2 depends on is at the end of this plan.

Spec: `docs/superpowers/specs/2026-10-21-db-encryption-design.md` §4 (Stage 1)
and §10 (Stage 1 tests). Approved by the owner on 2026-10-21 (ask #483), with
option (a) for Q1–Q4. Spike: `docs/superpowers/specs/2026-10-21-sqlcipher-spike.md`
on `spike/602-sqlcipher`.

## Global Constraints

- Inner loop only, per task: `go test ./internal/<pkg>` for the touched
  packages (plus the extra packages a task names) and `make lint-diff` for
  Go. For Swift: `make test-swift FILTER=<Class>`, `make kit-test FILTER=<Class>`
  and **`make lint-swift`**. `lint-diff` is Go-only and never checks Swift.
  No `-count=1` by reflex: it defeats the cache, and the amalgamation costs
  about 30 s to compile cold. The full gate (`make test`, `make test-swift`,
  `make lint-all`, `go test ./cmd/...`, `make mobile-test`) runs once, by the
  controller, in Task 10.
- **Never delete `WatchtowerDesktop/.build`.** The GRDB swap re-resolves
  packages and rebuilds GRDB and its dependants, not the ML stack. When a
  resolve fails, run `swift package resolve` again, never `rm -rf .build`. A
  new worktree copies main's `.build` first and deletes only the path-bound
  `ModuleCache`.
- **Heavy Swift work runs in one lane at a time** (Tasks 7 and 8). Two
  concurrent ML-stack links on a 16 GB machine cost more than they save. Go
  lanes run in parallel with each other and with one Swift lane. Each lane has
  its own worktree and branch, and the controller merges them into
  `feature/603-db-encryption`. Never put two implementers in one working tree.
- Run `bash scripts/dev-health.sh` before each phase. On `HEALTH: overloaded`,
  stop dispatching.
- **No dev CLI on the live database.** A repo-built CLI migrates the live
  `watchtower.db` ahead of the installed app. The engine is tested on test
  fixtures and on a copy of an install (`sqlite3 .backup` into the
  scratchpad). It is never tested on `~/.local/share/watchtower/...`.
- Public repo hygiene (CLAUDE.md): no live-install data in tests, fixtures,
  docs or commits. The test key is a fixed literal (`x'00…01'`), not a real one.
- Behavior inventory: Stage 1 changes no contract. The guard tests stay as
  they are, among them IDEA-01's `sqliteMaxVariables`
  (`internal/ideas/consolidate_test.go`), `TestCompact_PreservesRowids`, the
  `TestTxLock_*` tests and `TestOpen_PathWithQuestionMarkOpensThatFile`. If
  one of them fails on the new engine, fix the engine, never the assertion.
  When an assertion pins a modernc-only detail, such as an error message
  wrapper, ask the owner first.
- Every pinned `--json` and `dblock.jsonl` `Event` key stays as it is.
- Tests that spawn processes (the Swift interop test runs a Go helper) kill
  and wait for the child in teardown, including on the failure path.
- Swift: read the "Swift / Desktop conventions" section of
  `docs/review/review-rules.md`. Pure tests go in `WatchtowerCore`/`Tests/Core`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Review checklist for every implementer: `docs/review/review-rules.md`
  §§ Go conventions and Swift / Desktop conventions. Self-review against it
  before hand-back.

## Decisions fixed by this plan

- **Versions.** Go: `mattn/go-sqlite3` **v1.14.52** (the spike's version), with
  the SQLCipher **v4.19.0** community amalgamation (SQLite 3.53.4). Swift: GRDB
  **v7.11.1** (the spike's version; main resolves 7.10.0 today, so this is also a
  GRDB minor bump) and `SQLCipher.swift` **exactly 4.19.0**. Go and Swift move
  in lockstep. The interop test (Task 8) fails when they drift.
- **Package layout.** `internal/sqlcipher/` holds the vendored mattn sources
  (upstream file names kept, `LICENSE` kept), the amalgamation
  (`sqlite3-binding.c`/`.h` replaced), our additions in files named `wt_*.go`,
  and `VERSION` (mattn tag, SQLCipher tag, amalgamation SHA-256). The import
  path is `watchtower/internal/sqlcipher`, and the registered driver name is
  `sqlite3` (mattn's).
- **Forked behaviour, kept to the minimum:**
  1. `Connector{Path string; Params string; Key func() ([]byte, error)}`
     implements `driver.Connector`. `Connect` runs mattn's open with
     `sqlite3_key_v2` added between `sqlite3_open_v2` and mattn's own PRAGMAs
     when `Key != nil`, followed by `PRAGMA cipher_compatibility = 4`. The key
     bytes are zeroed after the call. With `Key == nil` (all of Stage 1) it
     is mattn's open unchanged.
  2. `BeginTx` honours `opts.ReadOnly`: a ReadOnly transaction issues plain
     `BEGIN` (deferred) even when `_txlock=immediate`. Upstream mattn ignores
     `TxOptions` and would make every read transaction take the write lock,
     which would break CLAUDE.md's ReadOnly rule and `TestTxLock_ReadOnlyTxDoesNotTakeWriteLock`.
  3. A `//go:build !cgo` file stops a `CGO_ENABLED=0` build at compile time,
     with an identifier that says why (`watchtower_needs_cgo_for_sqlcipher`).
     Silently falling back to some other engine is never allowed.
- **Upstream mattn tests are not vendored.** Only our `wt_*_test.go` files run
  in `go test ./...` and the race shards.
- **Idle close is the default** for file handles opened by `db.Open`,
  `db.OpenSidecar` and `db.OpenExisting*`: `SetConnMaxIdleTime(30 * time.Second)`.
  `:memory:` handles and test clones are never idle-closed, because their
  data lives in the connection. The daemon opts out on its `watchtower.db`
  handle (`(*DB).KeepConnectionWarm()` in `runSyncDaemon`, `cmd/sync.go`): its
  one connection holds the page cache that Stage 2 sizes. This covers
  `watchtower mcp`, `ai session` and any later long-lived process without a
  per-command list, which is what spec §4.1 asks for.
- **goreleaser is deleted, not ported.** `aiwatchtowers/homebrew-tap` does not
  exist (checked with `gh repo view` on 2026-10-21), and no workflow, Makefile
  target or `/release` step calls goreleaser.
- **Linux is a CI-only build** with `SQLCIPHER_CRYPTO_OPENSSL`. Every Ubuntu Go
  job installs `libssl-dev` explicitly.

## Lanes

| Lane | Tasks | Kind |
|---|---|---|
| A (Go engine) | 1 → 3 → 5 | Go |
| B (Go value pin) | 4 (before 3 is merged) | Go, short |
| C (CI) | 2 (after 1) | YAML |
| D (Swift, one at a time) | 6 → 7 → 8 (8 also needs 1) | Swift |
| — | 9 (docs) after 3, 5, 7, 8; 10 (gate) last | controller |

## Task 1: `internal/sqlcipher` — the vendored engine

Depends on: none.

- `scripts/sqlcipher-amalgamation.sh <sqlcipher-tag>` (new): clone
  `github.com/sqlcipher/sqlcipher` at the tag into a temp dir. Run
  `./configure --with-tempstore=yes --disable-tcl` and `make sqlite3.c` (this
  needs `tclsh`, which macOS has). Copy `sqlite3.c`/`sqlite3.h` to
  `internal/sqlcipher/sqlite3-binding.c`/`.h` with mattn's
  `#ifndef USE_LIBSQLITE3` guard. Write `internal/sqlcipher/VERSION`. The
  script is how an upgrade is done (Task 9 documents it). It never downloads
  a prebuilt binary.
- `internal/sqlcipher/`: copy mattn v1.14.52's non-test `.go`, `.c` and `.h`
  files and its `LICENSE`. Drop the `libsqlite3` build-tag files: nothing may
  link a system or Homebrew `libsqlite3`, because two SQLite copies in one
  process break POSIX locks on the same file.
- `internal/sqlcipher/wt_cgo.go` (`//go:build cgo`): the cgo flags.
  - Common: `-DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 -DSQLITE_ENABLE_FTS5
    -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown`,
    plus mattn's existing defines (`SQLITE_ENABLE_RTREE`, JSON is built in,
    `SQLITE_THREADSAFE=1`, …). Keep what mattn sets today and add only these.
  - darwin: `-DSQLCIPHER_CRYPTO_CC`, LDFLAGS `-framework Security -framework CoreFoundation`.
  - linux: `-DSQLCIPHER_CRYPTO_OPENSSL`, LDFLAGS `-lcrypto`.
- `internal/sqlcipher/wt_connector.go`: `Connector` (Decision 1). The key goes
  in as `x'<64 hex>'` through `sqlite3_key_v2(db, "main", …)`. A key that is
  not 32 bytes is an error before open. The key never enters a DSN string.
- `internal/sqlcipher/wt_tx.go` (or a patch to mattn's `BeginTx`, marked
  `// watchtower:`): Decision 2.
- `internal/sqlcipher/wt_nocgo.go` (`//go:build !cgo`): Decision 3.
- `internal/sqlcipher/wt_engine_test.go`:
  - `TestEngine_IsSQLCipher`: `PRAGMA cipher_version` is non-empty and starts
    with the `VERSION` tag; `sqlite_version()` matches `VERSION`;
    `PRAGMA compile_options` has `ENABLE_FTS5` and `HAS_CODEC`.
  - `TestEngine_FTS5JSONBM25Smoke`: an FTS5 table, `MATCH … ORDER BY bm25()`,
    `snippet()`, `json_extract`/`json_each`.
  - `TestEngine_KeyedRoundTrip`: a fixed test key writes a WAL file; the file
    has no `SQLite format 3\0` header; a marker string does not appear in the
    raw bytes; it reopens with the key; a wrong key and no key both fail
    with `file is not a database`. Opens with `Key == nil` read plaintext.
  - `TestEngine_ReadOnlyTxIsDeferred`: on a `_txlock=immediate` handle, a
    `ReadOnly` tx does not block a writer on a second connection, and a
    non-ReadOnly one does.
  - `TestEngine_VacuumPlaintext` (spike footnote 1, **a blocker for this
    plan**): a file migrated with the full schema (`db.Open` on a temp path in
    a test in `internal/db`, because `internal/sqlcipher` cannot import `db`;
    put this one test in `internal/db/compact_engine_test.go`), seeded with
    FTS rows across several tables, then `VACUUM` through the new engine with
    no key, plus `db.Compact` end to end. The spike saw `unable to open
    database` here, and `db compact` VACUUMs plaintext files throughout
    Stages 1–2. If it reproduces, investigate before Task 3 is merged. Likely
    leads: `SQLITE_TEMP_STORE=2` against the temp database VACUUM attaches,
    and the codec attach path. The fallbacks, in order: fix the flags; use
    `VACUUM INTO` plus the compaction swap; use `sqlcipher_export` into an
    unkeyed file. Write the finding into the feature note (Task 9).
- `go test ./internal/sqlcipher` (macOS) and, if Docker or a Linux box is
  available, once on Linux with `libssl-dev`. Otherwise Task 2's CI run is the
  Linux check.

## Task 2: CI, release and goreleaser

Depends on: Task 1.

- `.github/workflows/ci.yml`: add a step
  `sudo apt-get update && sudo apt-get install -y --no-install-recommends libssl-dev`
  before the first Go command in every Ubuntu job that compiles Go:
  `guide-check` (`go test ./docs/guide/ ./internal/kb/ ./internal/chat/`),
  `go-lint` (golangci-lint type-checks with cgo), `go-test`, `go-test-race`
  (all three shards) and both code-index jobs. `gate`, `leak-check` and
  `prune-spm-cache` compile no Go and are left alone. `actions/setup-go`'s
  build cache already keeps the compiled amalgamation between runs. Check
  that the cache key covers `internal/sqlcipher` (it hashes `go.sum`, and the
  build cache is content-addressed, so a changed `.c` file recompiles).
- `.github/workflows/release.yml`: the same step in "Go Release Gate" and
  "Go Release Race".
- macOS jobs (`Swift Test`, `Mobile App`, the release Swift job) build the
  CLI with CommonCrypto, so they need no package.
- `.golangci.yml`: add `exclusions.paths` for the vendored upstream files in
  `internal/sqlcipher` (everything but `wt_*.go`), so lint covers only our
  code. Keep `gofmt` clean on the vendored files anyway.
- Delete `.goreleaser.yaml`. `git grep -i goreleaser` outside
  `docs/superpowers` must come back empty.
- `make race-packages`: `internal/sqlcipher` lands in a shard by itself, so
  `RACE_HEAVY` needs no change. Read its race time from the first main run.
- Push the branch and run the workflow with `workflow_dispatch`, so that
  the race shards run once on Linux before the PR.

## Task 3: `internal/db` and `lockmetrics` on the new engine

Depends on: Task 1, Task 4 (the parity test must exist on modernc first).

- **DSN** (`internal/db/db.go`):
  - `connPragmas`/`connPragmaParams` become mattn params: `_foreign_keys=1`,
    `_synchronous=NORMAL`. `openDSN` becomes
    `?_txlock=immediate&_busy_timeout=5000&_foreign_keys=1&_synchronous=NORMAL`.
  - `existingDSN` keeps `mode=rw` (it is passed through in a `file:` URI) and
    uses `_busy_timeout=N`. `OpenExisting` uses `_query_only=1` instead of
    `_pragma=query_only(1)`.
  - `setPragmas` keeps its `PRAGMA …` statements: those are SQL, not DSN.
    Split `connPragmas` into a DSN form and a statement form instead of
    sharing the `name(value)` string.
  - `schema_upgrade.go`'s DSN changes the same way.
  - `sqliteDSN`'s `?`-in-path rule: mattn also cuts at the first `?`, and
    passes a `file:` DSN to SQLite as a URI. Re-run
    `TestOpen_PathWithQuestionMarkOpensThatFile` and
    `TestRunSchemaUpgrade_PathWithQuestionMark` and keep them unchanged.
- **Connector** (`pragmaConnector`): its `drv driver.Driver` + `dsn` becomes a
  `base driver.Connector` (a `sqlcipher.Connector` with `Key: nil`, wrapped by
  lockmetrics). `Connect` calls `base.Connect` and then re-runs the
  `SetBusyTimeout`/`SetReadOnly` pragmas as today. `openPool`/`openPoolWith`
  take the connector, and `metricsDriver`/`plainDriver`/`registeredDriver`
  are removed. `OpenSidecar` uses the unwrapped `sqlcipher.Connector`, which
  keeps its "not through lock metrics" rule.
- **lockmetrics** (`internal/db/lockmetrics/driver.go`):
  - `init`'s `sql.Register(DriverName, …)` over modernc becomes
    `func Wrap(base driver.Connector, dsn string) driver.Connector`. `dsn`
    feeds `isMemoryDSN`/`dsnQueryOnly`/`dsnBusyTimeoutMS`.
  - Keep `DriverName` registered, over the `sqlite3` driver, only if a caller
    still needs `sql.Open`. `schema_upgrade.go` moves to
    `sql.OpenDB(lockmetrics.Wrap(...))`, so check with grep, and delete it
    when nothing uses it.
  - `dsnBusyTimeoutMS`/`dsnQueryOnly` parse `_busy_timeout`/`_query_only`
    (mattn's names). Their table tests in `driver_test.go` (the DSN maps
    around lines 393 and 549) change to the new param spelling, with the same
    cases: percent-encoding, `ON`/`true`/`0`, memory.
  - `busyName`: `*sqlite.Error`/`sqlite3.SQLITE_*` become `sqlite3.Error`
    (`errors.As` on the value type) with `Code`/`ExtendedCode`. Wherever
    `internal/sqlcipher` has no constant, define it locally
    (`SQLITE_BUSY_TIMEOUT` = 773, `SQLITE_LOCKED_VTAB` = 518) next to the
    name map. The names written to `dblock.jsonl` stay the same.
  - `siteSkipPrefixes`: `"modernc.org/"` becomes
    `modulePrefix + "internal/sqlcipher."`.
  - `baseConn`: check that mattn's `*SQLiteConn` implements every listed
    interface (`SessionResetter`, `Validator`: mattn has both since 1.14.x).
    A missing one means a silent "unmeasured" fallback, so add a test that
    fails when `Wrap` hands back an unwrapped conn.
- **Errors**:
  - `db.go` `IsForeignKeyViolation` becomes
    `errors.As(err, &se) && se.ExtendedCode == sqlite3.ErrConstraintForeignKey`.
  - `busy.go` `IsBusy` becomes `se.Code == ErrBusy || se.Code == ErrLocked`.
  - `busy_test.go` builds mattn errors.
  - Production code that matches message text keeps working, because mattn's
    message is SQLite's `errmsg` and the matched text is a substring of it:
    `internal/db/review_agent.go:119`, `internal/db/workbenches.go:127`,
    `internal/inbox/pipeline.go:707`. Keep a test on each path.
- **Test template** (`internal/db/init_test_template.go`): `migratedSnapshot`
  and `cloneFromSnapshot` open `:memory:` through `sqlcipher.Connector`
  (`sql.OpenDB`). `serializer`/`deserializer` become mattn's
  `Serialize(schema string) ([]byte, error)` / `Deserialize(b []byte, schema string) error`,
  called with `"main"`. Both are compiled in by default (`sqlite3_opt_serialize.go`).
  `TestInitTestTemplate_CloneMatchesFreshMigration` must stay green.
- **Imports**: the 13 test files that import `modernc.org/sqlite` (listed by
  `git grep -l modernc.org/sqlite -- '*_test.go'`: `chat_migration_test.go`,
  `decisions_split_migration_test.go`, `google_accounts_migration_test.go`,
  `inbox_demolition_migration_test.go`, `jira_accounts_migration_test.go`,
  `json_ids_migration_test.go`, `migration_fk_recreation_test.go`,
  `migrations_cleanup_test.go`, `reaction_seed_migration_test.go`,
  `slack_accounts_migration_test.go`, `tool_trust_migration_test.go`,
  `voice_registry_migration_test.go`, `lockmetrics/driver_test.go`) switch
  from `sql.Open("sqlite", …)` to the `sqlite3` driver, or to a shared test
  helper `db.openRawForTest(path)` if more than three of them repeat the
  same DSN. Then `go mod tidy`: `modernc.org/sqlite` and its `modernc.org/*`
  dependencies leave `go.mod`/`go.sum`.
- **Comments that name modernc**: `db.go` (`pragmaConnector`), `lockmetrics`,
  `init_test_template.go` and `internal/ideas/consolidate_test.go:464`. In
  the last one the constant stays 32766, the default since SQLite 3.32, and
  only the comment changes to "the engine's SQLITE_MAX_VARIABLE_NUMBER".
- **Error-text assertions in tests** (they may pin modernc's wrapper text):
  `internal/agentlogdb/move_test.go`, `internal/db/open_existing_test.go`,
  `internal/db/proj15_archive_now_test.go`,
  `internal/db/proj15_board_archive_test.go`,
  `internal/db/workbench_methodology_test.go`,
  `internal/devpack/codex_install_test.go`, `internal/tracks/run_window_test.go`.
  Where an assertion holds a modernc-only fragment (`(2067)`,
  `constraint failed: `), change it to the SQLite message itself. Where it
  is a guard test (`TestProj15_…`), list the change for the owner in the
  hand-back first, per the inventory rule.
- Run: `go test ./internal/db/... ./internal/agentlogdb ./internal/ideas
  ./internal/inbox ./internal/tracks ./internal/devpack`, then
  `go test ./cmd -run 'Mcp|DB|Compact|Lockstats'`. Also run
  `go test -race ./internal/db/lockmetrics ./internal/sqlcipher` once at the
  end.

## Task 4: `TestDriverValueParity` — pin what lands on disk

Depends on: none. Write it **on modernc**, before Task 3. Task 3 must keep it
green without changing an expected value.

- `internal/db/driver_parity_test.go`: open a file DB through the package's
  normal `Open`. Create a table with columns of no type, `TEXT`, `INTEGER`,
  `REAL` and `BLOB`. Insert with `?` args: `time.Time` (UTC; non-UTC
  `FixedZone`; with nanoseconds; zero), `string` (ASCII, emoji, empty),
  `[]byte`, `json.RawMessage`, `bool` (true/false), `nil`, `int64`, `float64`,
  `sql.NullString`/`sql.NullInt64` and a `*time.Time` (nil and non-nil, the
  `SetAutomationSchedule` shape). Then read back `typeof(c)` and `quote(c)`
  and compare them with **literal expected strings** written into the test.
  Those strings are what modernc produces today, and they are exactly what
  the Desktop's GRDB readers see.
- In the same test, scan each value into `any`, `string`, `[]byte`,
  `time.Time` and `sql.NullTime`, and pin the Go type and value read back.
  mattn returns TEXT as `string`, and parses `time.Time` only for declared
  `DATE`/`DATETIME`/`TIMESTAMP` columns. `internal/db/schema.sql` and the
  agentlog migrations have none (checked with grep on 2026-10-21).
- **Audit**: `git grep -n 'time\.Time' -- 'internal/db/*.go' 'internal/agentlogdb/*.go' ':!*_test.go'`.
  For each `time.Time`/`*time.Time` that reaches an `Exec`/`Query` argument,
  either confirm it is formatted first (as `nullAutomationTime` does), or
  add its shape to the parity table. Wherever the two engines would write
  differently, format the value explicitly at that call (spec §4.1), so that
  the result no longer depends on the driver. Record the list in the PR
  description.
- `go test ./internal/db -run TestDriverValueParity` (on modernc; it is
  re-run in Task 3).

## Task 5: Idle connections close

Depends on: Task 3 (it edits `db.go`; this avoids a merge fight).

- `internal/db/db.go`: `const idleCloseAfter = 30 * time.Second`. After
  `openPool…` builds a file-backed handle (`Open` with a path other than
  `:memory:`, `OpenSidecar`, `openExistingDSN`), call
  `sqlDB.SetConnMaxIdleTime(idleCloseAfter)`. In-memory handles, the
  `openMemoryHook` clones and `cloneFromSnapshot` never get it.
- `func (db *DB) KeepConnectionWarm()` sets `SetConnMaxIdleTime(0)`. Call it
  in `runSyncDaemon` (`cmd/sync.go`) on the daemon's `watchtower.db` handle,
  and only there.
- Connection state that an idle close would lose: `pragmaConnector` already
  re-applies `SetBusyTimeout`/`SetReadOnly`. Check with grep that no
  long-lived path keeps other per-connection state:
  `git grep -n -E 'Exec\(.?PRAGMA|TEMP TABLE|TEMPORARY|ATTACH ' -- 'internal/*.go' 'cmd/*.go' ':!*_test.go'`
  (on 2026-10-21 it matched only `internal/db` itself and a comment in
  `internal/codeindex/masks.go`). Anything found either moves into
  `connState` or goes on a pinned `sql.Conn`.
- Tests (`internal/db/idle_close_test.go`):
  - a file handle's idle connection closes. Test seam: `idleCloseAfter` as a
    `var` that tests shorten. Count opens through a counting wrapper on the
    connector, or check `db.Stats().MaxIdleTimeClosed`;
  - after the close, `SetReadOnly` and `SetBusyTimeout` still hold on the
    next query, the `TestPragmasSurviveInterruptedQuery` shape;
  - `:memory:` keeps its data across a gap longer than the timeout;
  - `KeepConnectionWarm` keeps the connection.
- `docs/features/db-compact.md` D6: the accepted MCP effect now applies only
  to an MCP server in the middle of a call. One sentence (Task 9 writes it).
- Run `go test ./internal/db -run 'Idle|Pragmas'` and
  `go test ./cmd -run 'SyncDaemon|MCP'`.

## Task 6: The GRDB fork

Depends on: none. **Needs the owner's go-ahead** before the repo is created:
it is a new public repo in the `aiwatchtowers` org
(`aiwatchtowers/GRDB.swift` did not exist on 2026-10-21).

- Fork `groue/GRDB.swift` to `aiwatchtowers/GRDB.swift`, branch
  `sqlcipher-7.x` from tag `v7.11.1`.
- `Package.swift`, following GRDB's own "GRDB+SQLCipher" comments in that
  file:
  - remove the `GRDBSQLite` system-library target and its use;
  - add `.package(url: "https://github.com/sqlcipher/SQLCipher.swift", exact: "4.19.0")`
    and make the `GRDB` target depend on its `SQLCipher` product;
  - add `swiftSettings`/`cSettings` defines: `SQLITE_HAS_CODEC`, `GRDBCIPHER`
    (if that tag's sources gate on it), `SQLITE_ENABLE_FTS5`.
- Keep the product name `GRDB` and the package identity `GRDB.swift`: the
  last URL component stays the same, so no `.product(name:package:)` line
  changes downstream.
- Run GRDB's own test suite once on the branch (`swift test`, macOS), plus
  its SQLCipher tests if the tag has them.
- Tag `7.11.1-sqlcipher.1` (semver pre-release, so SPM can pin it `exact:`).
  Write the fork's `README` section on how to upgrade: rebase on a GRDB tag,
  bump SQLCipher.swift together with `internal/sqlcipher/VERSION`, run the
  interop test, tag `<grdb>-sqlcipher.<n>`.
- Check whether `SQLCipher.xcframework` is a **dynamic** framework. Inspect
  the unzipped slice with `file` and `otool -L` and record the result for
  Task 7.

## Task 7: Desktop, Kit and phone on the fork

Depends on: Task 6. Heavy Swift, one lane.

- `WatchtowerKit/Package.swift`, `WatchtowerDesktop/Package.swift`: the GRDB
  line becomes
  `.package(url: "https://github.com/aiwatchtowers/GRDB.swift", exact: "7.11.1-sqlcipher.1")`.
  Both have to change in the same commit. The Desktop depends on the Kit by
  path, and SPM refuses two URLs with one identity.
- `swift package resolve` in both; commit `WatchtowerDesktop/Package.resolved`
  and `WatchtowerKit/Package.resolved`, which now carry `SQLCipher.swift` as
  well. The Swift Test job's SPM cache key hashes `Package.resolved`, so its
  first run is a cold GRDB build, with the ML stack's products restored
  under the `runner.os-spm-v2-` fallback key.
- `WatchtowerMobile/project.yml`: the `GRDB` package `url` and `exactVersion`
  change to the same pin. Update the comment ("same URL and version as the
  Kit's dependency"). Then run `make mobile-gen` and commit the regenerated
  `WatchtowerMobile.xcodeproj`.
- **A dynamic `SQLCipher.framework`** (per Task 6's finding):
  `scripts/build-app.sh` copies it from `swift build --show-bin-path` into
  `Watchtower.app/Contents/Frameworks/`. `app-codesign` signs it
  (`--options runtime`, the same identity; ad-hoc on the ad-hoc branch)
  **before** the bundle, inside out. Check with `otool -l` that the main
  binary's rpath includes `@executable_path/../Frameworks`. If it does not,
  add it at link time (`linkerSettings: .unsafeFlags` is not allowed in a
  dependency, so use `install_name_tool -add_rpath` in the script). Add a
  `scripts/tests/test-build-app-*.sh` case that reads the script (as
  `test-build-app-notices.sh` does) and asserts both the copy and the sign
  order. The phone embeds the framework through Xcode by itself. If the
  framework is static, skip this item and say so in the feature note.
- **Engine tests**:
  - `WatchtowerDesktop/Tests/Core/SQLCipherEngineTests.swift`: a
    `DatabaseQueue()` in memory and a `DatabasePool` on a temp file, each
    configured the way `DatabaseManager` configures them
    (`WatchtowerDesktop/Sources/Database/DatabaseManager.swift`). Assert that
    `PRAGMA cipher_version` is non-empty and equals the pinned 4.19.0, that
    `sqlite_version()` matches `internal/sqlcipher/VERSION` (read the file
    from the repo through `#filePath`), and that `compile_options` has
    `ENABLE_FTS5`. This proves that GRDB runs on SQLCipher and not on the
    system `libsqlite3`.
  - The same assertion in `WatchtowerKit/Tests/WatchtowerSyncTests/`, for the
    replica `DatabasePool`.
  - `QueryTests.testSearchFTS5Available` and `DBLockMetrics`'s busy-callback
    tests are re-run as they are.
- Run: `make test-swift FILTER='SQLCipherEngineTests|QueryTests|DBLockMetrics|DatabaseManager'`,
  `make kit-test FILTER=SQLCipherEngine`, `make mobile-build`,
  `make mobile-test MOBILE_FILTER=<a replica/HubRegistry test class>`,
  `make lint-swift`, and `bash scripts/tests/test-build-app-<new>.sh`.
- One `make app-dev` (ad-hoc) build, launched once on a **copy** of an
  install's workspace (`WATCHTOWER_…` workspace override, or a scratch
  config). Check that the app opens, Search returns FTS hits and the menu bar
  works. This is the only check that the framework embedding loads at run
  time.

## Task 8: Go↔Swift interop test

Depends on: Task 1, Task 7. Swift lane.

- `internal/sqlcipher/cmd/interop/main.go` (`package main`, test-only helper;
  `scripts/build-app.sh` builds only `.`, so it never ships). Subcommands, JSON
  on stdout:
  - `write --path P [--key-hex H]`: WAL file; an FTS5 table shaped like
    `kb_fts` with 2 000 rows, then a rebuild; 200 transactions × 50 rows; a
    `VACUUM`. With a key, the keyed `Connector`.
  - `read --path P [--key-hex H] --expect-table T`: reopen; check that the
    table and row written by Swift exist.
  - `versions`: `{"cipher_version":…,"sqlite_version":…}`.
- `WatchtowerDesktop/Tests/Core/SQLCipherInteropTests.swift`:
  - Build the helper once per class (`go build -o <tmp>/interop
    ./internal/sqlcipher/cmd/interop` from the repo root), following
    `CodeNavRealCLITests.builtCLI()`.
  - With no Go toolchain the test skips locally, but **fails** when
    `WATCHTOWER_REQUIRE_GO=1`, which the CI Swift Test job sets.
  - Two cases, keyed (the fixed test key) and plaintext:
    1. Go `write`.
    2. GRDB `DatabasePool` with
       `prepareDatabase { try $0.execute(sql: "PRAGMA key = \"x'…'\""); try $0.execute(sql: "PRAGMA cipher_compatibility = 4") }`
       (keyed case only) runs `kb_fts MATCH … ORDER BY bm25(kb_fts)` and
       gets rows back, then creates a table and inserts a row.
    3. Go `read` sees them.
  - First assert that Go's `versions` equals Swift's `cipher_version` and
    `sqlite_version()`. On a mismatch the failure message names both
    versions and points at the upgrade steps.
  - The helper process is terminated and waited for in `tearDown`, and every
    `Process` call has a timeout.
- `.github/workflows/ci.yml` and `release.yml` Swift Test jobs: `env:
  WATCHTOWER_REQUIRE_GO: "1"` on the Test step. Both jobs already run
  `setup-go`.
- Run `make test-swift FILTER=SQLCipherInteropTests` and `make lint-swift`.

## Task 9: Docs

Depends on: Task 3, Task 5, Task 7, Task 8.

- `docs/features/db-encryption.md` (new feature note), section **Stage 1 —
  engine**. It covers:
  - `internal/sqlcipher` (versions, the three forked behaviours, the
    amalgamation script, the no-system-libsqlite rule);
  - the connector/lockmetrics shape;
  - the default idle close and the daemon opt-out;
  - the GRDB fork and its pin, and the framework embedding (or "static");
  - the upgrade procedure in lockstep, with the interop test as the gate;
  - the Linux CI-only build;
  - the VACUUM finding from Task 1;
  - "no key yet: every file is plaintext". Add a `## Stage 2 gate (G1–G5)`
    heading where the owner's results go.
- `CLAUDE.md`:
  - the Backend line becomes "SQLite via an in-repo SQLCipher build of
    `mattn/go-sqlite3` (`internal/sqlcipher`, cgo; `database/sql`)";
  - the Desktop line names the GRDB fork;
  - add one Feature Notes index entry for `db-encryption.md`;
  - add an inner-loop note: "the first `go test` after a clean cache compiles
    the amalgamation (~30 s); `CGO_ENABLED=0` no longer builds".
- `docs/features/db-lock-metrics.md`: the Go wrapping section moves from
  "modernc's registered `sqlite` driver" to the connector; the `site` row
  changes `modernc` to `internal/sqlcipher`; the pinned keys stay unchanged.
- `docs/features/db-compact.md`: the `TestCompact_PreservesRowids` sentence
  names the new engine; D6 says idle MCP servers hold no handle.
- `THIRD_PARTY_NOTICES.md`, new section **SQLite engine**, with rows for:
  - the mattn fork (MIT);
  - the SQLCipher community amalgamation (BSD-style Zetetic licence, full
    text), noting SQLite's public-domain dedication;
  - `SQLCipher.swift` (the same licence, shipped in the app);
  - the GRDB fork (MIT).

  Extend `scripts/tests/test-build-app-notices.sh` so it checks that
  `internal/sqlcipher/VERSION`'s tags appear in the file.
- `.claude/skills/debate-review/references/agent-prompts.md:9`: the engine name.
- `docs/guide`: there is no user-visible change, so no guide page changes.
  Confirm with `git grep -n -i 'sqlite' docs/guide` that no page names the
  old engine.
- `go test ./docs/guide`, if anything under it changed.

## Task 10: Phase gate (controller)

Depends on: all tasks.

- `bash scripts/dev-health.sh`, then `make test`, `make test-swift`,
  `make lint-all`, `go test ./cmd/...`, `make mobile-test` and
  `make test-scripts`.
- A `workflow_dispatch` CI run on the branch: the race shards on Linux, plus
  every Ubuntu job with OpenSSL.
- A copy check: `sqlite3 .backup` an install's `watchtower.db` and
  `agentlog.db` into the scratchpad. Point a repo-built CLI at the copy with
  `--db` and the workspace flags, and run `watchtower db migrate`,
  `watchtower db compact --force --json`, `watchtower search …`,
  `watchtower agents stats` and one `sync --now` with network off (it
  should fail cleanly). Then open the copy in the `make app-dev` build. The
  live file is never touched.
- Spot timings on the copy: an `OpenExisting` hook open, and the inbox
  mentions scan. The spike expects plaintext reads 20–45 % faster than on
  modernc, and anything slower is a finding. Write the numbers in the
  feature note.
- Release-notes line for the version that ships Stage 1: "Faster database
  engine; no change to your data."
- Then `local-review` / `debate-review` on the whole branch, and a PR into
  `main`.

## Stage 2 gate: G1–G5 on a notarized build

Spec §5.3 makes these the gate **before any Stage 2 code**. They run on a
throwaway probe, not on Watchtower itself, and do not block merging Stage 1.
The probe lives on its own branch, `spike/603-keychain-gate`, and is never
merged. The results go into `docs/features/db-encryption.md` § Stage 2 gate.

**The probe (an agent builds it; nothing here needs the owner):**

- `probe/` on the spike branch: a Go cgo program that makes exactly the
  calls Stage 2 will make (spec §5.1), through `Security.framework` from C,
  always with `kSecUseDataProtectionKeychain = true` and never falling back
  to the file keychain. Its own item names, so it never touches the real
  hub keys: service `com.watchtower.dbkey.probe`, SE tag
  `com.watchtower.dbkey.se.probe`. Subcommands print JSON
  `{op, osstatus, elapsed_ms, console_locked}`, where `console_locked` comes
  from `ioreg -n Root -d1 -a` `IOConsoleLocked`:
  - `se-create`: P-256 `kSecAttrTokenIDSecureEnclave`, permanent,
    `AfterFirstUnlockThisDeviceOnly` + `.privateKeyUsage`;
  - `wrap`: 32 random bytes, wrapped with
    `eciesEncryptionCofactorVariableIVX963SHA256AESGCM`, stored as a generic
    password `AfterFirstUnlockThisDeviceOnly`, not synchronizable;
  - `get`: read the wrapped item, read the SE key, decrypt, print the SHA-256
    of the plaintext;
  - `loop --every 5s --for 3m --log FILE --detach`: re-execs itself with
    `SysProcAttr{Setsid: true}` (macOS has no `setsid` command), runs `get`
    on every tick and appends each JSON line to `FILE`;
  - `cleanup`: delete both probe items.
  Each call has a 10 s timeout. A prompt blocks `SecItem*`, so a timeout is
  recorded as `prompt_suspected`.
- `probe/make-bundles.sh`:
  - `Probe.app` (CFBundleIdentifier `com.watchtower.desktop`, the same app id
    as the real app, so the existing Developer ID profile applies) with the
    probe as its main executable;
  - `Probe.app/Contents/Helpers/Watchtower CLI.app/Contents/MacOS/watchtower`
    (the same binary; helper bundle id `com.watchtower.desktop.cli`);
  - both embed the profile, with entitlements `com.apple.application-identifier
    = <TEAM>.com.watchtower.desktop`,
    `com.apple.developer.team-identifier = <TEAM>` and
    `keychain-access-groups = [<TEAM>.com.watchtower.desktop]`, merged at sign
    time from the profile, the way `provision-profile-check` in
    `scripts/build-app.sh` does it. The team id is never written in the repo;
  - the helper bundle is copied to
    `~/Library/Application Support/WatchtowerProbe/bin/Watchtower CLI.app`,
    with a symlink `…/WatchtowerProbe/bin/watchtower`. This is a probe
    directory: the real `Watchtower/bin` is never touched.
  - It has three modes: `--sign developer-id` (uses
    `WATCHTOWER_PROVISION_PROFILE` and `CODESIGN_IDENTITY`, as `build-app.sh`
    does), `--sign adhoc` and `--notarize` (uses the existing notary profile).

**Checklist** (the owner ticks it; "Agent" means an agent may run the step
once the owner has done the steps before it):

- [ ] **Prep — Owner.** The Mac is unlocked. The Developer ID identity and
  `WATCHTOWER_PROVISION_PROFILE` are available (a locked Mac makes the
  notary keychain item read as missing). Run
  `probe/make-bundles.sh --sign developer-id --notarize` (or let an agent
  run it in your session). Approve any codesign keychain prompt for the
  signing key: that prompt concerns the signing identity, not the probe.
  Record `codesign -dv --verbose=4` (Authority, TeamIdentifier, cdhash) for
  both bundles and `spctl -a -vv` for `Probe.app`.
- [ ] **G3, part 1 — Owner (watches the screen) or agent.** Run
  `open Probe.app --args se-create` and then `--args wrap`, so that the
  *app* creates both items. Pass: `osstatus 0` for both, and no dialog.
- [ ] **G1 + G3, part 2 — Agent, with the owner watching for a dialog.** Run
  `~/Library/Application Support/WatchtowerProbe/bin/watchtower get` from
  Terminal, five times. Pass: `osstatus 0` every time, the same plaintext
  SHA-256 as the app's, `elapsed_ms` under 50, no `prompt_suspected` and no
  dialog. A fail on G1 → try the helper's CFBundleIdentifier =
  `com.watchtower.desktop` once, then the spec's fallback (a second App ID
  `com.watchtower.cli` + shared group `<TEAM>.com.watchtower.shared`).
- [ ] **G1 via a hook-like parent — Agent.** Run the same `get` from a
  Claude Code hook stub and from `launchctl asuser $(id -u) …`, so that the
  parent is not Terminal. Pass: the same as above.
- [ ] **G2 — Owner (locks the screen).** Run
  `watchtower loop --every 5s --for 3m --log /tmp/g2.jsonl --detach`, lock
  the screen with ⌃⌘Q at once, wait at least 2 minutes and unlock. Then the
  owner or an agent reads the log. Pass: every line with
  `console_locked: true` has `osstatus 0`. Optional, owner only: the same
  check after a reboot, from an SSH session before the first login, where
  the expected result is `errSecInteractionNotAllowed` (-25308), which Stage
  2 maps to `ErrLocked`. Skip it if FileVault makes it impractical.
- [ ] **G4 — Owner signs, agent runs.** Change the probe's version string,
  rebuild and re-sign with the same identity and profile (a new cdhash;
  confirm with `codesign -dv`), notarize and replace both bundles in place.
  Run `get` (as the helper through the symlink) and `open Probe.app --args get`.
  Pass: `osstatus 0`, no dialog, the same SHA-256. Fail → the spec's last
  resort (a key served over the daemon/session-host socket after an
  audit-token team-ID check); stop and ask before designing it.
- [ ] **G5 — Agent, no owner needed.** Run `probe/make-bundles.sh --sign adhoc`
  into a separate scratch directory, then `get` and `wrap` from the ad-hoc
  helper. Pass: `errSecMissingEntitlement` (-34018) returned at once
  (`elapsed_ms` under 50), no dialog, and
  `security find-generic-password -s com.watchtower.dbkey.probe ~/Library/Keychains/login.keychain-db`
  finds nothing, so no file-keychain item was created.
- [ ] **Cleanup — Agent.** Run `watchtower cleanup` from the signed helper
  (both items gone, checked with a second `get` → `errSecItemNotFound`).
  Delete `~/Library/Application Support/WatchtowerProbe` and the build
  directory.
- [ ] **Record — Agent.** Write each step's JSON lines, the codesign facts
  (the team id redacted to `<TEAM>`) and pass/fail into
  `docs/features/db-encryption.md` § Stage 2 gate. If anything failed,
  open an ask with the fallback the spec names.
