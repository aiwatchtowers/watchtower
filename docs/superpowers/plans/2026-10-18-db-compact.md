# Compacting `watchtower.db` at launch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The first launch after compaction became due runs `VACUUM` on `watchtower.db` before the Desktop opens its pool and before the daemon starts — visibly, skippably, never at the cost of data or disk.

**Architecture:** Go owns every rule: a `db_maintenance` table (migration 00142), a check/run engine in `internal/db/compact.go`, and the `watchtower db compact [--check|--if-due] [--force] [--json]` command with fixed exit codes. The Desktop only runs the CLI: `DatabaseCompactionStep` (WatchtowerCore, injected CLI runner and clock) drives the step and its launch-screen state; `AppState.initialize()` splits migrate → compact → open and gates every daemon start while the step runs.

**Tech Stack:** Go 1.26, `modernc.org/sqlite`, goose, cobra; SwiftUI/Observation (macOS 14), WatchtowerCore + XCTest.

**Spec:** `docs/superpowers/specs/2026-10-18-db-compact-design.md` (authoritative; business view in `2026-10-18-db-compact-business.md`). Read the spec's D1–D6 before your task; this plan does not restate their reasoning.

## Global Constraints

- Migration number **00142** (`internal/db/migrations/00142_db_maintenance.sql`); the highest on `main` at planning time is 00141. If another branch lands 00142 first, renumber at merge (file name only; nothing else keys on the number).
- `compactAfterMigrations = []int64{134}`; freelist rule: `freelist_count * page_size > 256 MiB` **and** `freelist_count > 0.25 * page_count`; disk rule `free_disk_bytes >= 2 * db_bytes`; failure cap 3 per CLI version.
- `--check` never writes and never migrates (opens with `db.OpenExisting`); `db compact` opens with `db.OpenExistingRW`, `SetBusyTimeout(30 * time.Second)`; neither ever calls `db.Open`/`openDBFromConfig`.
- Exit codes of `db compact`: 0 compacted / not_due, 1 other error, 2 `disk`, 3 `daemon_running`, 4 `interrupted`, 5 `schema_pending`. Flag misuse (e.g. `--check --force`) is exit **1**, never `usageError` (that is exit 2 = disk).
- JSON keys verbatim from the spec (snake_case). `db_maintenance` keys: `last_compacted_version`, `compacted_at` (RFC 3339 UTC), `compact_failures`, `compact_failures_version`.
- UI strings in English, exactly: `Optimizing database — <size>, <m:ss>`, `This happens once after an update.`, `Skip for now`, `Watchtower could not optimize its database: it needs <N> free, <M> available.` (sizes via `ByteCountFormatter`, `.file` style).
- Skip button appears at 15 s elapsed; SIGKILL 10 s after the SIGTERM if the child is still alive.
- Public repo: no local absolute paths, no live data (the 3.4 GB / 813k-row numbers stay in the spec only). Repo text in English.
- Inner loop only per task (`go test ./internal/db -run …`, `go test ./cmd -run …`, `make test-swift FILTER=…`, `make lint-diff`); the full gate (`make test`, `make test-swift`, `make lint-all`) runs once at the end, by the controller.
- Tests that spawn processes kill and reap them in `t.Cleanup` / `tearDown` (CLAUDE.md).

## Review Focus

1. **The owner quits the app (⌘Q) while the step runs.** Expect the compact child to get SIGTERM from the quit path, not to keep running orphaned under launchd next to the next launch. → Task 6 test `testQuitDuringCompactionTerminatesChild`.
2. **An MCP server / hook holds an open read transaction during `VACUUM`.** Expect compaction to succeed (or fail cleanly as exit 1 with the DB intact) — never a hang past the 30 s busy timeout and never data loss; `wal_checkpoint(TRUNCATE)` reporting busy is not an error. → Task 3 test `TestCompact_ConcurrentReaderDoesNotFail`.
3. **A stale `daemon.pid` pointing at a dead (or reused) pid.** Expect `db compact` to proceed, not to refuse with exit 3 forever. → Task 4 test `TestDBCompact_StalePIDFileDoesNotRefuse`.
4. **A database path with spaces and non-ASCII characters** (workspace dirs are owner-named). Expect check and compact to work (`existingDSN` escapes the path). → Task 3 test `TestCompact_PathWithSpacesAndUnicode`.
5. **CLI stdout carries a line before the JSON** (e.g. `ensureSchemaFormat`'s pre-run output, a deprecation line). Expect the Desktop to decode the last non-empty stdout line and not treat the step as failed. → Task 5 test `testDecodesLastJSONLineAfterPreamble`.

---

## Lanes

- **Lane A (Go):** Task 1 → Task 2 → Task 3 → Task 4.
- **Lane B (Swift, one heavy lane):** Task 5 → Task 6. Lane B needs only the JSON/exit-code contract above, so it runs **in parallel with Lane A** from the start.
- **Task 7 (docs)** after both lanes.

---

### Task 1: `db_maintenance` table (migration 00142)

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00142_db_maintenance.sql`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist` list)
- Regenerate: `internal/db/testdata/*.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Produces: table `db_maintenance(key TEXT PRIMARY KEY, value TEXT NOT NULL)`; Down drops it.

Follow `.claude/skills/add-migration` steps 1, 3–6. The Up carries a doc comment: what the table is for (#850), the four keys, "absent key = never compacted / no failures".

- [ ] **Step 1:** add `db_maintenance` to `TestAllTablesExist`; run `go test ./internal/db -run TestAllTablesExist` → FAIL (table missing).
- [ ] **Step 2:** write the migration and the `schema.sql` mirror.
- [ ] **Step 3:** `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema'` → PASS.
- [ ] **Step 4:** commit `feat(db): db_maintenance table for compaction state (#850)`.

---

### Task 2: Compaction check engine (D1, D3, D4 reads, failure cap)

**Depends on:** Task 1

**Files:**
- Create: `internal/db/compact.go`, `internal/db/compact_disk_darwin.go` (or a `unix` build-tagged file — `syscall.Statfs`, `Bavail * uint64(Bsize)`), `internal/db/compact_check_test.go`
- Modify: `internal/db/db.go` (export the schema check)

**Interfaces:**
- Consumes: `OpenExisting(dbPath string, busy time.Duration) (*DB, error)`; `(*DB).schemaCurrent() bool`.
- Produces:
  ```go
  func (db *DB) SchemaCurrent() bool // exported wrapper, same semantics as schemaCurrent

  var compactAfterMigrations = []int64{134}
  const (
      compactFreelistMinBytes = 256 << 20
      compactFreelistMinRatio = 0.25
      compactMaxFailures      = 3
  )

  // Reasons: "migration:<v>", "freelist", "schema_pending", "gave_up", "".
  type CompactCheck struct {
      Due            bool   `json:"due"`
      Reason         string `json:"reason"`
      DBBytes        int64  `json:"db_bytes"`
      WALBytes       int64  `json:"wal_bytes"`
      FreeDiskBytes  int64  `json:"free_disk_bytes"`
      NeedsDiskBytes int64  `json:"needs_disk_bytes"`
      DiskOK         bool   `json:"disk_ok"`
  }

  // version is the CLI build version (cmd.Version), compared with
  // compact_failures_version.
  func CheckCompaction(dbPath, version string) (CompactCheck, error)

  // freeDiskBytes is the statfs seam (tests replace it).
  var freeDiskBytes = func(dir string) (int64, error)

  // readMaintenance: a missing db_maintenance table or key → ("", false, nil).
  func readMaintenance(q Queryer, key string) (string, bool, error)
  ```
  (`Queryer` = whatever minimal `QueryRow` interface the package already has, or `*DB`.)

Precedence inside `CheckCompaction`: no file → `{Due:false, DiskOK:true}`, no file created; open fails → error; `!SchemaCurrent()` → `{Due:false, Reason:"schema_pending"}`; failures ≥ 3 for this version → `{Due:false, Reason:"gave_up"}`; migration rule (highest listed applied version > `last_compacted_version`, reason names that version); freelist rule. Sizes and disk fields are filled on every outcome where the file exists. `NeedsDiskBytes = 2 * DBBytes`, `DiskOK = FreeDiskBytes >= NeedsDiskBytes`.

- [ ] **Step 1: Write the failing tests** in `compact_check_test.go` (fixtures: `Open` a temp file, close, then call `CheckCompaction`):
  - `TestCheckCompaction_DueAfterMigration134`: fresh migrated DB, no record → `Due == true`, `Reason == "migration:134"`, `NeedsDiskBytes == 2*DBBytes`, `DBBytes > 0`.
  - `TestCheckCompaction_NotDueAfterRecord`: write `last_compacted_version` = highest applied version → `Due == false`, `Reason == ""`.
  - `TestCheckCompaction_FreelistRule` (table test over a fake `pragma` reader seam or real fixture; thresholds referenced by the named constants): `{pages: 100_000, free: 30_000, pageSize: 16384}` → due `freelist` (30k*16 KiB = 469 MiB, 30 %); `{free: 20_000}` (20 %) → not due; `{pages: 40_000, free: 15_000, pageSize: 16384}` (234 MiB, 37 %) → not due. Record present so the migration rule is off. Implementer may extract `freelistDue(freelist, pageCount, pageSize int64) bool` to keep it a pure table test.
  - `TestCheckCompaction_NoFileCreatesNothing`: path in an empty temp dir → `Due == false`, `DiskOK == true`, `os.Stat(path)` and its parent's entries unchanged (no `-wal`/`-shm` either).
  - `TestCheckCompaction_SchemaPending`: migrated DB, then `DELETE FROM goose_db_version WHERE version_id = (SELECT MAX(version_id) …)` → `Reason == "schema_pending"`, `Due == false`; `goose_db_version` row count unchanged after the call.
  - `TestCheckCompaction_DiskShort`: `freeDiskBytes` stub returns `DBBytes*2 - 1` → `DiskOK == false`, `Due == true`; stub returns exactly `2*DBBytes` → `DiskOK == true`.
  - `TestCheckCompaction_GaveUpForThisVersionOnly`: `compact_failures=3`, `compact_failures_version="1.0.0"` → with `version "1.0.0"`: `Due == false`, `Reason == "gave_up"`; with `"1.0.1"`: `Due == true`, `Reason == "migration:134"`; with `compact_failures=2` and `"1.0.0"`: due.
  - `TestCheckCompaction_MissingMaintenanceTableReadsNeverCompacted`: unit test of `readMaintenance` on a DB where the table was dropped → `("", false, nil)`.
- [ ] **Step 2:** `go test ./internal/db -run 'TestCheckCompaction'` → FAIL (undefined).
- [ ] **Step 3:** implement per Interfaces.
- [ ] **Step 4:** `go test ./internal/db -run 'TestCheckCompaction'` → PASS; `make lint-diff` clean.
- [ ] **Step 5:** commit `feat(db): compaction due check (#850)`.

---

### Task 3: Compaction run engine (D2 steps 2–5, 7, 8; failure counter)

**Depends on:** Task 2

**Files:**
- Modify: `internal/db/compact.go`
- Create: `internal/db/compact_run_test.go`, `internal/db/compact_rowid_test.go`

**Interfaces:**
- Consumes: Task 2's `CompactCheck`, `readMaintenance`, `freeDiskBytes`, `SchemaCurrent`; `OpenExistingRW`, `SetBusyTimeout`.
- Produces:
  ```go
  type CompactOptions struct {
      Force   bool   // skip the disk rule (the daemon rule lives in cmd)
      Reason  string // carried into the result: the check's reason, or "manual"
      Version string // CLI build version, for the failure counter
  }

  type CompactResult struct {
      Compacted   bool   `json:"compacted"`
      Skipped     string `json:"skipped,omitempty"` // not_due|disk|daemon_running|interrupted|schema_pending
      Reason      string `json:"reason,omitempty"`
      BytesBefore int64  `json:"bytes_before,omitempty"`
      BytesAfter  int64  `json:"bytes_after,omitempty"`
      DurationMS  int64  `json:"duration_ms,omitempty"`
      Error       string `json:"error,omitempty"`
      Failures    int    `json:"failures,omitempty"`
      GaveUp      bool   `json:"gave_up,omitempty"`
  }

  // Skips return (result, nil); a VACUUM/IO failure returns (result, err)
  // with Error/Failures/GaveUp filled.
  func Compact(ctx context.Context, dbPath string, opts CompactOptions) (CompactResult, error)

  // compactVacuumHook, nil in production, runs right before the VACUUM Exec
  // (test seam for the interrupt test).
  var compactVacuumHook func()
  // compactVacuumSQL is the statement run (test seam for a forced failure).
  var compactVacuumSQL = "VACUUM"
  ```

Order inside `Compact`: disk rule (unless `Force`) → `skipped:"disk"`, DB not opened; `OpenExistingRW` + `SetBusyTimeout(30s)`; `!SchemaCurrent()` → `skipped:"schema_pending"`; `wal_checkpoint(TRUNCATE)`; `ExecContext(ctx, "VACUUM")` on the pool (no tx); `wal_checkpoint(TRUNCATE)`; success → one write tx: `last_compacted_version` = `MAX(version_id) WHERE is_applied=1`, `compacted_at`, delete `compact_failures`/`compact_failures_version`. `ctx.Err() != nil` after a VACUUM error → `skipped:"interrupted"`, nothing written. Any other VACUUM error → increment `compact_failures` (reset to 1 when `compact_failures_version != opts.Version`), set `compact_failures_version`, `GaveUp = failures >= compactMaxFailures`; a failed counter write is appended to the returned error, never hides the VACUUM error. `BytesBefore`/`BytesAfter` = main file size before the first checkpoint / after the last.

- [ ] **Step 1: Write the failing tests** (`compact_run_test.go`; a helper `sparseFixture(t, rows int) string` inserts `rows` messages with an 8 KiB `raw_json` in one tx, then runs `UPDATE messages SET raw_json = '{}' WHERE raw_json != '{}'` — the 00134 statement):
  - `TestCompact_ShrinksSparseFixture`: 4000 rows → `Compacted == true`; `BytesAfter < BytesBefore/2`; `SELECT COUNT(*) FROM messages` equal before/after; SHA-256 of `SELECT group_concat(text, char(31)) FROM (SELECT text FROM messages ORDER BY rowid)` equal; then `CheckCompaction(path, v).Due == false`.
  - `TestCompact_DiskShortLeavesDBUntouched`: stub `freeDiskBytes` → 0 → `Skipped == "disk"`, err nil; file size and mtime unchanged; no `db_maintenance` row. With `Force: true` → `Compacted == true`.
  - `TestCompact_SchemaPendingRefuses`: delete the newest `goose_db_version` row → `Skipped == "schema_pending"`; `goose_db_version` count unchanged (nothing migrated).
  - `TestCompact_InterruptLeavesDBIntact`: `sparseFixture(t, 8000)` (≥ ~64 MiB before the UPDATE); `compactVacuumHook` starts a goroutine that cancels ctx after 20 ms → `Skipped == "interrupted"`, err nil; reopen with `Open`: row count equal; no `last_compacted_version`, no `compact_failures`. If this flakes as "compacted", enlarge the fixture — never accept both outcomes.
  - `TestCompact_FailureCounter`: force a VACUUM failure through the unexported seam `compactVacuumSQL` (production `"VACUUM"`; the test sets `"VACUUM no_such_schema"`, which fails with "unknown database" while the counter write still succeeds). Three calls with `Version "1.0.0"` → `Failures` 1, 2, 3; `GaveUp` false, false, true; `CheckCompaction(path, "1.0.0").Reason == "gave_up"`; one call with `"1.0.1"` → `Failures == 1`; a later success deletes both failure keys.
  - `TestCompact_ConcurrentReaderDoesNotFail` (Review Focus 2): a second `OpenExisting` handle holds `BEGIN` + one `SELECT` open across the call → no hang beyond the busy timeout; result is `Compacted == true` or a returned error with the DB still opening and all rows present (assert which one modernc gives and pin it — expected: compacted, possibly `BytesAfter` not yet reduced).
  - `TestCompact_PathWithSpacesAndUnicode` (Review Focus 4): fixture under `t.TempDir()/"my space é"/watchtower.db` → `Compacted == true`, and `CheckCompaction` on the same path works.
- [ ] **Step 2: Rowid guard** `compact_rowid_test.go` — `TestCompact_PreservesRowids`: seed rows (gaps via `DELETE` of every third row) in `messages` (composite PK), `gmail_messages`, `imap_messages`, `jira_issues`, `jira_comments` (the `linkscan` synced cursors), `user_interactions`, `decision_reads` (`memory.go` rowid identity), and `kb_chunks` + its `kb_fts` rows; collect `SELECT rowid, <pk cols…> FROM <t> ORDER BY rowid` per table and `SELECT rowid FROM kb_fts ORDER BY rowid`; compact with `Force`; assert every list is identical. A failure here means compaction must reset those cursors (spec D2.8) — do not relax the test.
- [ ] **Step 3:** `go test ./internal/db -run 'TestCompact_'` → FAIL.
- [ ] **Step 4:** implement.
- [ ] **Step 5:** `go test ./internal/db -run 'TestCompact_|TestCheckCompaction'` → PASS; `make lint-diff` clean.
- [ ] **Step 6:** commit `feat(db): VACUUM-based compaction with failure cap (#850)`.

---

### Task 4: `watchtower db compact` command

**Depends on:** Task 3

**Files:**
- Create: `cmd/db_compact.go`, `cmd/db_compact_test.go`
- Modify: `cmd/db.go` (register the subcommand), `cmd/db_test.go` (migrate guard)

**Interfaces:**
- Consumes: `db.CheckCompaction`, `db.Compact`, `db.CompactOptions`, `db.CompactResult`; `pidFilePath(cfg)`, `daemon.FindConfirmedProcess`; `notifyShutdownContext(parent, stderrLogf)`; `exitCodeError{code, err}`; `Version`.
- Produces: `dbCompactCmd` with flags `--check`, `--if-due`, `--force`, `--json`;
  ```go
  // compactExitCode maps a result/err to 0..5 per the spec.
  func compactExitCode(res db.CompactResult, err error) int
  // daemonRunningForCompact is a seam (tests stub it); production:
  // daemon.FindConfirmedProcess(pidFilePath(cfg)) → pid != 0; an
  // ErrIdentityUnconfirmed reads as running (fail safe).
  var daemonRunningForCompact = func(cfg *config.Config) bool
  ```

Config: `config.Load(flagConfig)`, `--workspace` override, `ValidateWorkspace()`; DB path `cfg.DBPath()`. Never `openDBFromConfig`. Flow: `--check` (with `--if-due`/`--force` → error exit 1) → print `CompactCheck`, exit 0. Otherwise: if `--if-due`, run the check; not due → `{"compacted":false,"skipped":"not_due"}` exit 0 (also for `schema_pending`/`gave_up` reasons — the check said no); daemon running and no `--force` → `skipped:"daemon_running"` exit 3; `Compact(ctx, …, {Force, Reason: check reason or "manual", Version})`. The JSON goes to stdout on every outcome, including errors; the human message (non-`--json`) is one line: "Compacted watchtower.db: 3.4 GB → 1.0 GB in 41s" style via humanized bytes, or the skip reason. Non-zero exits return `&exitCodeError{…}` so `Execute` prints the message to stderr.

- [ ] **Step 1: Write the failing tests** (`cmd/db_compact_test.go`, temp config + workspace following the existing `cmd/db_test.go` helpers; run the command through `rootCmd.SetArgs` and capture stdout):
  - `TestDBCompact_CheckJSON`: migrated temp DB → stdout decodes to `due:true`, `reason:"migration:134"`; exit 0; `goose_db_version` and `db_maintenance` unchanged.
  - `TestDBCompact_IfDueCompactsThenNotDue`: `--if-due --json` → `compacted:true`, exit 0; second run → `{"compacted":false,"skipped":"not_due"}`, exit 0.
  - `TestDBCompact_DaemonRunningRefuses`: stub `daemonRunningForCompact` → true: exit 3, `skipped:"daemon_running"`, no `db_maintenance` rows; with `--force` → exit 0 compacted.
  - `TestDBCompact_StalePIDFileDoesNotRefuse` (Review Focus 3): real seam, `daemon.pid` containing a pid of a reaped child process → exit 0 compacted.
  - `TestDBCompact_DiskShortExit2`: stub disk → exit 2, `skipped:"disk"`.
  - `TestDBCompact_SchemaPendingExit5`: newest goose row deleted, plain `db compact --json` → exit 5, `skipped:"schema_pending"`; goose rows unchanged.
  - `TestDBCompact_ExitCodeTable`: `compactExitCode` over `{compacted}→0, {not_due}→0, {disk}→2, {daemon_running}→3, {interrupted}→4, {schema_pending}→5, (res, errors.New("x"))→1`.
  - `TestDBCompact_FlagConflictIsExit1`: `--check --force` → exit 1.
  - `TestDBCompact_NoDatabase`: config pointing at a workspace without `watchtower.db`: `--check --json` → `due:false`, exit 0, no file created.
  - In `cmd/db_test.go`: `TestDBMigrate_NeverCompacts`: sparse fixture (reuse the shape of Task 3's helper, local to cmd), `db migrate` → main file size not reduced, no `compacted_at` row.
- [ ] **Step 2:** `go test ./cmd -run 'TestDBCompact_|TestDBMigrate_NeverCompacts'` → FAIL.
- [ ] **Step 3:** implement; the SIGTERM path is `notifyShutdownContext(cmd.Context(), stderrLogf)` passed to `db.Compact` (interrupt behavior itself is pinned in Task 3).
- [ ] **Step 4:** same command → PASS; `make lint-diff` clean.
- [ ] **Step 5:** commit `feat(cli): db compact command (#850)`.

---

### Task 5: `DatabaseCompactionStep` (WatchtowerCore)

**Depends on:** none (contract only — runs in parallel with Lane A)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/DatabaseCompactionStep.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProcessCompactionCLI.swift`, `WatchtowerDesktop/Tests/Core/DatabaseCompactionStepTests.swift`

**Interfaces:**
- Produces:
  ```swift
  package struct CompactionCheck: Decodable, Equatable, Sendable {
      package let due: Bool; package let reason: String
      package let dbBytes, walBytes, freeDiskBytes, needsDiskBytes: Int64
      package let diskOk: Bool            // CodingKeys: snake_case per the spec
  }
  package struct CompactionRunOutput: Decodable, Equatable, Sendable {
      package let compacted: Bool; package let skipped: String?; package let reason: String?
      package let bytesBefore, bytesAfter, durationMs: Int64?
      package let error: String?; package let failures: Int?; package let gaveUp: Bool?
  }
  package struct CompactionExit: Sendable { package let status: Int32; package let stdout: Data; package let stderr: String }
  package protocol CompactionChild: AnyObject, Sendable {
      func terminate(); func kill(); func waitForExit() async -> CompactionExit
  }
  package protocol CompactionCLI: Sendable {
      /// `db compact --check --json`, 30 s timeout; throws on spawn failure,
      /// timeout, non-zero exit or undecodable output.
      func check() async throws -> CompactionCheck
      /// Spawns `db compact --if-due --json` with no timeout.
      func startCompact() throws -> any CompactionChild
  }
  /// Decodes the last non-empty line of stdout.
  package func decodeLastJSONLine<T: Decodable>(_ type: T.Type, from stdout: Data) throws -> T

  @MainActor @Observable
  package final class DatabaseCompactionStep {
      package enum Phase: Equatable { case idle, checking, compacting(dbBytes: Int64), finished }
      package private(set) var phase: Phase
      package private(set) var elapsedSeconds: Int
      package private(set) var notice: String?
      package var isRunning: Bool        // .checking or .compacting
      package var canSkip: Bool          // .compacting && elapsedSeconds >= skipAfterSeconds && !skipRequested
      package init(cli: any CompactionCLI,
                   stopDaemon: @escaping @Sendable () async -> Void,
                   sleep: @escaping @Sendable (Duration) async -> Void,
                   log: @escaping @Sendable (String) -> Void)
      /// Returns when the launch may continue; never throws.
      package func run(resolveDBPath: () throws -> String) async
      package func skip()                // SIGTERM now, SIGKILL after killAfterSkipSeconds ticks
      package func terminateForQuit()    // SIGTERM to a running child; no-op otherwise
      package func dismissNotice()
      package static let skipAfterSeconds = 15
      package static let killAfterSkipSeconds = 10
      package static let subtitle = "This happens once after an update."
      package static func elapsedText(seconds: Int) -> String
      package static func progressLine(dbBytes: Int64, elapsedSeconds: Int) -> String
      package static func diskNotice(needs: Int64, available: Int64) -> String
      package static let gaveUpNotice: String
  }
  /// Production runner: Constants.findCLIPath(), Constants.resolvedEnvironment(),
  /// stdout/stderr drained with ProcessPipes.drain.
  package struct ProcessCompactionCLI: CompactionCLI { package init() }
  ```

`run` flow (spec D5): `resolveDBPath` throws → `.finished`, no CLI call; `check()` throws → log, `.finished`; not due → `.finished`; due && !diskOk → `notice = diskNotice(needs: needsDiskBytes, available: freeDiskBytes)`, `.finished`; else `stopDaemon()`, `startCompact()`, `.compacting(dbBytes:)`, tick `elapsedSeconds` once per `sleep(.seconds(1))` until the child exits; exit 2 → disk notice from the check's numbers; exit 1 with `gaveUp == true` → `notice = gaveUpNotice`; every other exit → log only. Elapsed counts injected sleeps, never wall clock — that is what makes the tests deterministic. `gaveUpNotice` copy: `"Watchtower could not optimize its database after 3 attempts. It will try again after the next update."`

- [ ] **Step 1: Write the failing tests** (`FakeCompactionCLI` records calls in order into a shared log with `stopDaemon`; `FakeChild` exits when the test says, records `terminate`/`kill`; fake `sleep` yields and counts):
  - `testNotDueRunsNothing`: check `due:false` → calls == `["check"]`, no stop, `phase == .finished`, `notice == nil`.
  - `testDiskShortShowsNoticeAndSkips`: `due:true, diskOk:false, needsDiskBytes: 6_800_000_000, freeDiskBytes: 2_000_000_000` → calls `["check"]`; `notice == "Watchtower could not optimize its database: it needs 6.8 GB free, 2 GB available."` (assert against `diskNotice` built with `ByteCountFormatter.string(fromByteCount:countStyle:.file)` for both numbers, plus this literal on an `en_US` formatter).
  - `testDueStopsDaemonThenCompactsInOrder`: calls == `["check", "stopDaemon", "startCompact"]`; phase passes through `.compacting(dbBytes: 3_400_000_000)`; after child exit 0 → `.finished`.
  - `testCheckFailureContinues`: check throws → `.finished`, no stop, one log line containing "compaction check".
  - `testResolveDBPathFailureCallsNoCLI`: resolver throws → calls == `[]`.
  - `testSkipHiddenBefore15Seconds`: after 14 ticks `canSkip == false`; after 15 `canSkip == true`.
  - `testSkipTerminatesThenKillsAfter10Seconds`: child ignores terminate; `skip()` → `terminateCount == 1`, `canSkip == false`; after 9 more ticks `killCount == 0`; after 10 → `killCount == 1`; child then exits → `run` returns.
  - `testSkipChildExitsOnTerminateNoKill`: child exits on terminate → `killCount == 0`.
  - `testGaveUpShowsNoticeOnce`: exit 1 with `{"compacted":false,"error":"disk I/O error","failures":3,"gave_up":true}` → `notice == DatabaseCompactionStep.gaveUpNotice`.
  - `testDaemonRunningExitContinues`: exit 3 → `.finished`, `notice == nil`, a log line.
  - `testTerminateForQuit`: during `.compacting`, `terminateForQuit()` → `terminateCount == 1`.
  - `testElapsedText`: `elapsedText(seconds: 42) == "0:42"`, `65 → "1:05"`, `0 → "0:00"`, `600 → "10:00"`.
  - `testProgressLine`: `progressLine(dbBytes: 3_400_000_000, elapsedSeconds: 42) == "Optimizing database — 3.4 GB, 0:42"`.
  - `testDecodesLastJSONLineAfterPreamble` (Review Focus 5): stdout `"schema format upgraded\n{\"due\":false,…}\n\n"` decodes; stdout with no JSON line throws.
- [ ] **Step 2:** `make test-swift FILTER=DatabaseCompactionStep` → FAIL (does not compile).
- [ ] **Step 3:** implement both files.
- [ ] **Step 4:** `make test-swift FILTER=DatabaseCompactionStep` → PASS; `make lint-diff` clean.
- [ ] **Step 5:** commit `feat(desktop): DatabaseCompactionStep (#850)`.

---

### Task 6: Launch wiring, daemon gate, splash UI

**Depends on:** Task 5 (and Task 4 for a manual end-to-end check; the unit tests use fakes)

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (init seams, `initialize()` launch task, `openDatabaseForOnboarding`, the reinitialize path ~line 979, `ensureDaemonRunning`), `WatchtowerDesktop/Sources/App/AppState+DaemonStart.swift` (gates), `WatchtowerDesktop/Sources/Database/DatabaseManager.swift` (drop `migrateAndOpen` once unused), `WatchtowerDesktop/Sources/App/Navigation.swift` (`SplashView`, notice banner), `WatchtowerDesktop/Sources/Views/TrayMenuView.swift` (Sync Now disabled), `WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift` (start gated), `WatchtowerDesktop/Sources/App/TrayAppDelegate.swift` (quit hook), `WatchtowerDesktop/Tests/AppState+Isolated.swift`
- Create: `WatchtowerDesktop/Tests/DatabaseCompactionLaunchTests.swift`

**Interfaces:**
- Consumes: `DatabaseCompactionStep`, `ProcessCompactionCLI`, `DaemonManager.stopDaemonBounded()`, `DatabaseManager.runCLIMigrations()`, `DatabaseManager.resolveDBPath()`.
- Produces on `AppState`:
  ```swift
  init(..., migrateDatabase: @escaping @Sendable () -> Void = { DatabaseManager.runCLIMigrations() },
       openDatabase: @escaping @Sendable () throws -> DatabaseManager = { try DatabaseManager(path: DatabaseManager.resolveDBPath()) },
       databaseCompaction: DatabaseCompactionStep? = nil, ...)   // nil → production step
  let databaseCompaction: DatabaseCompactionStep
  var databaseCompactionInProgress: Bool { databaseCompaction.isRunning }
  ```

Launch task order: `syncCLIBinaryStore` → `startPolling` → `offPool { migrateDatabase() }` → `await databaseCompaction.run(resolveDBPath: { try DatabaseManager.resolveDBPath() })` → `offPool { openDatabase() }` → rest unchanged. Every other `openDatabase` caller runs `migrateDatabase()` first (behavior unchanged, no compaction). Gates (`guard !databaseCompactionInProgress else { return }`, with a log line): `ensureDaemonRunning`, `bringUpDaemonInBackground`, `startDaemonFromBanner`, the restart wrapper in `AppState+DaemonStart.swift` (~line 114; returns without restarting), Slack settings start; tray "Sync Now" `.disabled(!isRunning || compactionInProgress)` via a new `TrayMenuContent` parameter. Quit: `TrayAppDelegate`'s quit sequence calls `app.databaseCompaction.terminateForQuit()` before `stopDaemon`. Splash: when `phase` is `.compacting`, show `progressLine` and `subtitle` under the progress view, and a `Skip for now` button when `canSkip`. Notice: when `databaseCompaction.notice != nil`, a dismissible banner in the same `safeAreaInset` slot as `DaemonBannerView` (daemon banner wins when both exist), ✕ → `dismissNotice()`. `AppState+Isolated.isolated(...)` passes `migrateDatabase: {}` and a step with a fake CLI reporting not due.

- [ ] **Step 1: Write the failing tests** (`DatabaseCompactionLaunchTests`, using `AppState.isolated` extended with a `databaseCompaction:` parameter and the Task 5 fakes, reachable from `Tests/` via the test-support target or a local copy):
  - `testLaunchOrderMigrateCompactOpen`: shared call log → `["migrate", "check", "stopDaemon", "startCompact", "open"]` for a due DB; `["migrate", "check", "open"]` for not due.
  - `testDaemonStartsAreNoOpsDuringCompaction`: while the fake child is running: `ensureDaemonRunning()`, `bringUpDaemonInBackground(startOnly: false)`, `startDaemonFromBanner()` → `FakeDaemon.startCount == 0`; after the child exits and the launch continues → the launch's own `ensureDaemonRunning` starts it (`startCount == 1`).
  - `testDaemonStartsWorkAgainAfterStep`: after `.finished`, `startDaemonFromBanner()` increments `startCount`.
  - `testQuitDuringCompactionTerminatesChild` (Review Focus 1): drive the quit sequence's compaction hook (extract it as a static/seamed closure if the delegate is not testable) → `terminateCount == 1`.
  - `testOnboardingOpenStillMigrates`: `openDatabaseForOnboarding()` → log `["migrate", "open"]`, no `check`.
  - In `TrayMenuViewTests`: `testSyncNowDisabledDuringCompaction` (follow that file's existing inspection style).
- [ ] **Step 2:** `make test-swift FILTER='DatabaseCompactionLaunch|TrayMenuView|AppStateTests'` → FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** `make test-swift FILTER='DatabaseCompactionLaunch|DatabaseCompactionStep|TrayMenuView|AppStateTests|CLIMigrationsAndOAuthStderr'` → PASS; `make lint-diff` clean.
- [ ] **Step 5 (manual, controller):** `make app-dev` on a copy of a sparse DB (built with Task 3's fixture shape, never the live one) — splash shows the line, Skip appears at 15 s, the next launch shows nothing.
- [ ] **Step 6:** commit `feat(desktop): compact the database at launch (#850)`.

---

### Task 7: Docs and the add-migration rule

**Depends on:** Task 4, Task 6

**Files:**
- Create: `docs/features/db-compact.md` (rules D1–D4 with the constants, exit codes, launch order, the D6 accepted effects, the rowid guard and what to do if it fails, the failure cap)
- Modify: `docs/features/tray-daemon-lifecycle.md` (launch order: migrate → compact → open → daemon), `docs/app-guide.md` (launch line, Skip for now, disk/gave-up notices), `.claude/skills/add-migration/SKILL.md` (a step/gotcha: a migration that frees a lot of space adds its version to `compactAfterMigrations` in `internal/db/compact.go`), `CLAUDE.md` (one Feature Notes bullet linking `docs/features/db-compact.md`), the 00142 migration's doc comment is already in Task 1; also add the same one-line rule to the doc comment above `compactAfterMigrations`.

- [ ] **Step 1:** write/modify the docs; no live numbers, no local paths.
- [ ] **Step 2:** `bash scripts/leak-check.sh` over the branch's commits if runnable locally, else grep the diff for `/Users/` and real ids → none.
- [ ] **Step 3:** commit `docs(db): compaction at launch (#850)`.

---

## Final gate (controller, once)

`bash scripts/dev-health.sh` → `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`; then `local-review` → `debate-review` on the PR into `main`.
