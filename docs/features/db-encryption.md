# Database encryption (board #603)

Design: `docs/superpowers/specs/2026-10-21-db-encryption-design.md` (approved 2026-10-21, ask #483, Q1–Q4 = (a)). Plan for Stage 1: `docs/superpowers/plans/2026-10-21-db-encryption-stage1.md`. Stage 2 (the key) and Stage 3 (one-time encryption of existing installs) have their own plans.

**No key yet: every file is plaintext.** Stage 1 only swaps the engine. Every Go process and every Swift app now opens SQLite through one SQLCipher-capable engine, and nothing on disk changes: `watchtower.db`, `agentlog.db` and every sidecar still start with `SQLite format 3`, and the system `sqlite3` still opens them.

## Stage 1 — engine

### Go: `internal/sqlcipher`

- **What it is.** A vendored fork of `mattn/go-sqlite3` **v1.14.52** (its non-test files with upstream names, its `LICENSE`, no `libsqlite3` build-tag files), with `sqlite3-binding.c`/`.h` and `sqlite3ext.h` replaced by the **SQLCipher v4.19.0 community amalgamation (SQLite 3.53.4)**. Import path `watchtower/internal/sqlcipher`; the registered driver name stays `sqlite3`. `modernc.org/sqlite` is gone from `go.mod`.
- **`VERSION`** holds four lines: `mattn/go-sqlite3 v1.14.52`, `sqlcipher v4.19.0`, `sqlite 3.53.4` and `sqlite3-binding.c sha256 <hex>`. `TestEngine_IsSQLCipher` checks the running engine against it, and both Swift engine tests read it.
- **Amalgamation.** `scripts/sqlcipher-amalgamation.sh <tag>` clones `sqlcipher/sqlcipher` at the tag, builds `sqlite3.c` from source (`make sqlite3.c`, macOS's `tclsh`), wraps the files in mattn's `#ifndef USE_LIBSQLITE3` guard, and rewrites `VERSION`. It never downloads a prebuilt binary.
- **Build flags** (`wt_cgo.go`): `SQLITE_HAS_CODEC`, `SQLITE_TEMP_STORE=2`, `SQLITE_ENABLE_FTS5`, `SQLITE_EXTRA_INIT=sqlcipher_extra_init`, `SQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown`, on top of mattn's own. Darwin uses CommonCrypto (`SQLCIPHER_CRYPTO_CC`, `-framework Security -framework CoreFoundation`). Linux uses OpenSSL (`SQLCIPHER_CRYPTO_OPENSSL`, `-lcrypto`).
- **No system `libsqlite3`, ever.** Two SQLite copies in one process break POSIX locks on the same file, so nothing links a system or Homebrew SQLite.
- **cgo only.** `wt_nocgo.go` stops a `CGO_ENABLED=0` build at compile time on the undefined `watchtower_needs_cgo_for_sqlcipher`. There is no silent fallback to another engine.
- **Upstream mattn tests are not vendored.** Only our `wt_*_test.go` files run.

**The three forked behaviours** (in `wt_*.go`, or marked `// watchtower:` in the vendored files):

1. **`Connector{Path, Params, Key func() ([]byte, error)}`** (`wt_connector.go`), used through `sql.OpenDB`. With a key, `open` calls `sqlite3_key_v2(db, "main", "x'<64 hex>'")` right after `sqlite3_open_v2` and before any PRAGMA or page read, then `PRAGMA cipher_compatibility = 4`. The key is raw (`sqlcipher.KeyLen` = 32 bytes, so SQLCipher runs no PBKDF2). It never enters a DSN string, and every buffer that held it is zeroed after the call. A wrong key or no key on an encrypted file fails with `file is not a database`. `Key == nil` (all of Stage 1) is mattn's open unchanged.
2. **A ReadOnly transaction stays deferred** (`sqlite3_sql.go`). `BeginTx` with `ReadOnly: true` issues plain `BEGIN` even under `_txlock=immediate`. Upstream ignores `TxOptions`, which would make every read transaction take the write lock (`TestEngine_ReadOnlyTxIsDeferred`, `TestTxLock_ReadOnlyTxDoesNotTakeWriteLock`).
3. **The cgo stop** above.

**Value patches** (`// watchtower:`), so what lands on disk is what modernc wrote, which `TestDriverValueParity` pins with every literal unchanged:

- a `time.Time` argument binds as its `String()` text, not mattn's own layout;
- an empty BLOB scans as a nil `[]byte`;
- `Deserialize` marks the image `RESIZEABLE`, so a test clone loaded from a snapshot can grow (`init_test_template.go` clones through `Serialize`/`Deserialize("main")`).

### `internal/db` and lock metrics

- **DSN.** modernc's `_pragma=busy_timeout(N)/foreign_keys/synchronous/query_only` became mattn's `_busy_timeout`, `_foreign_keys`, `_synchronous` and `_query_only`. `_txlock=immediate` and `mode=rw` stay. `TestOpen_PathWithQuestionMarkOpensThatFile` holds against mattn's split.
- **Connector shape.** `engineConnector(dsn)` builds a `sqlcipher.Connector` (no key). `watchtower.db` handles go through `lockmetrics.Wrap(base, dsn)`. Sidecars (`OpenSidecar`) are opened unwrapped. `pragmaConnector` still re-applies `SetBusyTimeout`/`SetReadOnly` on every new connection.
- **Errors.** `db.IsBusy`, `db.IsForeignKeyViolation` and the inbox's `isUniqueConflict` read `sqlcipher.Error`'s `Code`/`ExtendedCode`. SQLite's own message (`database is locked`) replaces modernc's `SQLITE_BUSY` suffix.
- **Lock metrics follow mattn's timing.** The engine steps a query's first row in `rows.Next`, not in `Query`, and reads the schema while it opens a connection. So the wrapper times a writing query up to its first `Next` and records a busy error there, and a busy error during the open is recorded as well. A connection or rows that lacks an interface the wrapper forwards fails the open, checked at compile time, instead of going unmeasured. A DSN with no busy timeout reports the engine's 5 s default. The stack-site filter skips `watchtower/internal/sqlcipher` frames. The pinned `Event` keys did not change. See [db-lock-metrics.md](db-lock-metrics.md).
- **Interrupted queries.** The engine keeps an interrupted connection in the pool where modernc's was replaced, so `TestPragmasSurviveInterruptedQuery` drops the pool's connection itself.

### Idle connections close after 30 s

`Open` (file paths), `OpenSidecar` and `OpenExisting*` set `SetConnMaxIdleTime(idleCloseAfter)` = 30 s. An idle `watchtower mcp` server, a warm `ai session` or any later long-lived process then holds no file handle, without a per-command list. `db compact` and the Stage 3 encryption step stop fighting them (compaction's D6 shrinks, see [db-compact.md](db-compact.md)). `pragmaConnector` brings the handle's pragmas back on the fresh connection. `:memory:` handles and the test clones never idle-close, because their data lives in the connection. **The daemon opts out**: `runSyncDaemon` (`cmd/sync.go`) calls `(*DB).KeepConnectionWarm()` on its `watchtower.db` handle, so its one connection keeps the page cache that Stage 2 sizes. Tests: `internal/db/idle_close_test.go`.

### VACUUM on a plaintext file

The spike saw a `VACUUM` failure on a plaintext file. It does not reproduce on the vendored engine. `TestEngine_VacuumPlaintext` (`internal/db/compact_engine_test.go`) pins it, and `TestCompact_PreservesRowids` holds on the new engine.

### Swift: the GRDB fork

- **Pin.** The Kit, the Desktop and the phone (`WatchtowerMobile/project.yml`) depend on `https://github.com/aiwatchtowers/GRDB.swift`, `exact: "7.11.1-sqlcipher.2"`: GRDB 7.11.1 with GRDB's own SPM SQLCipher recipe, linked against `SQLCipher.swift` pinned to exactly **4.19.0**, plus `SQLITE_ENABLE_FTS5` and `SQLITE_HAS_CODEC`. SPM allows one GRDB identity in the graph, so all three always change in one commit, and both `Package.resolved` files carry `SQLCipher.swift`.
- **Why `.2`.** SQLCipher is built without `SQLITE_ENABLE_API_ARMOR`, so a call on an already closed connection, which the system SQLite tolerates, crashed. Tag `.2` carries the fork's patch for it.
- **Framework embedding.** `SQLCipher.xcframework` is **dynamic**. `scripts/build-app.sh`'s `embed-frameworks` block copies every SwiftPM framework the binary loads through `@rpath` into `Contents/Frameworks/`, fails when one is missing, and adds the `@executable_path/../Frameworks` rpath once (`install_name_tool`, since a dependency cannot add linker flags). `app-codesign` signs the frameworks first, inside out: hardened runtime with our identity, or ad-hoc. `scripts/tests/test-build-app-frameworks.sh` pins the copy, the rpath and the signing order. The phone embeds it through Xcode.
- **Swift side of a keyed open** (Stage 2): `PRAGMA key = "x'<64 hex>'"`, then `PRAGMA cipher_compatibility = 4`, in `prepareDatabase`.
- **The phone never encrypts.** Its replica is E2E-sealed under iOS Data Protection. It ships SQLCipher only because of the one-GRDB rule, and opens with no key (spec §4.3).
- **Engine tests.** `SQLCipherEngineTests` (Desktop `Tests/Core`, and the Kit's `WatchtowerSyncTests` for the replica pool) assert `cipher_version` 4.19.0, `sqlite_version()` 3.53.4, `ENABLE_FTS5` and `HAS_CODEC`, so GRDB never runs on the system `libsqlite3`. The Desktop one also compares with `internal/sqlcipher/VERSION`.

### The Go↔Swift interop test

`WatchtowerDesktop/Tests/Core/SQLCipherInteropTests.swift` builds `internal/sqlcipher/cmd/interop` once per class. The helper is test-only, and `build-app.sh` builds only the repo root, so it never ships. It runs three cases:

- `versions`: Go's `cipher_version` and `sqlite_version()` equal GRDB's. A mismatch fails every case, and its message names both sides.
- Keyed (the fixed test key `x'00…01'`) and plaintext round trips:
  1. Go writes a WAL file: a `kb_chunks` + `kb_fts` pair shaped like the app's, 2 000 rows, an FTS `rebuild`, 200 transactions × 50 rows and a `VACUUM`.
  2. GRDB's `DatabasePool` runs `kb_fts MATCH … ORDER BY bm25(kb_fts)` and creates and fills a table.
  3. Go reopens the file, finds the table, gets FTS hits back and an `ok` from `integrity_check`.

  The keyed file has no plaintext header, and Go without the key gets `file is not a database`.

Every helper process has a timeout and is killed and reaped in `tearDown`. With no Go toolchain the class skips locally. The CI Swift Test steps (`ci.yml`, `release.yml`) set `WATCHTOWER_REQUIRE_GO=1`, which turns that skip into a failure.

### Upgrading the engine (lockstep)

Go and Swift move together, and the interop test is the gate:

1. `scripts/sqlcipher-amalgamation.sh v<new>`. This regenerates the amalgamation and `VERSION`. A new mattn tag means re-vendoring and re-applying the `// watchtower:` patches.
2. In the GRDB fork, rebase on the GRDB tag, bump `SQLCipher.swift` to the same SQLCipher version, and tag `<grdb>-sqlcipher.<n>` (see the fork's README).
3. Move the pin in `WatchtowerKit/Package.swift`, `WatchtowerDesktop/Package.swift` and `WatchtowerMobile/project.yml` in one commit, resolve both packages, and run `make mobile-gen`.
4. Update `pinnedCipherVersion`/`pinnedSQLiteVersion` in both `SQLCipherEngineTests`, and the versions in `THIRD_PARTY_NOTICES.md` (`scripts/tests/test-build-app-notices.sh` checks them against `VERSION`).
5. Run `go test ./internal/sqlcipher/... ./internal/db/...`, `make test-swift FILTER='SQLCipher'`, `make kit-test FILTER=SQLCipher` and `make test-scripts`.

### Build, CI and release

- **Local.** The first `go test` or build after a clean cache compiles the amalgamation (~30 s). After that the Go build cache keeps it, so never pass `-count=1` by reflex. `CGO_ENABLED=0` no longer builds.
- **Linux is a CI-only build** with OpenSSL. Every Ubuntu job that compiles Go installs `libssl-dev` explicitly (Guide Check, Go Lint, Go Test, the race shards, Code Index full grammars, and the release Go gate and race shards). CI therefore tests the engine that ships, never another one.
- **`.goreleaser.yaml` is deleted.** It built `CGO_ENABLED=0` binaries, nothing called it, and its Homebrew tap does not exist. There is no Linux or Intel release binary.
- **Notices.** `THIRD_PARTY_NOTICES.md` § SQLite engine lists the mattn fork, the SQLCipher amalgamation, `SQLCipher.swift` and the GRDB fork, with the Zetetic licence text. `scripts/tests/test-build-app-notices.sh` checks that `VERSION`'s tags appear there.

## Stage 2 gate (G1–G5)

Spec §5.3: these run on a notarized throwaway probe (`spike/603-keychain-gate`, never merged) before any Stage 2 code. The owner's results go here.

Not run yet.
