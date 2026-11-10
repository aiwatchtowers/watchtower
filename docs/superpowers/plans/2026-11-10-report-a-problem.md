# Report a Problem — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Help → **Report a Problem…** (and Settings → System → Logs) opens a sheet that shows a privacy-safe diagnostics summary built by a new read-only `watchtower diagnostics` command and opens the GitHub bug form prefilled; a corporate build only saves the report to a file.

**Architecture:** Go is the one source of the diagnostics text: small seams in `internal/sqlcipher`, `internal/db`, `internal/daemon` and `internal/config`, pure pieces in a new `internal/diagnostics` package (text constants, error classes, crash scan, line builders, the budgeted runner), and the cobra command in `cmd/diagnostics.go`. The Desktop runs the command with a 10 s timeout and shows its `text` verbatim; the sheet's state, copy and link building live in WatchtowerCore and are unit-tested, the view only renders them.

**Tech Stack:** Go 1.26 (cobra, viper, the in-repo SQLCipher driver, cgo), SwiftUI + WatchtowerCore + DesignKit.

**Spec:** `docs/superpowers/specs/2026-11-04-report-a-problem-design.md` (owner-approved in ask #1141; decisions 27/28/31 approved in ask #1043). Read with it: `docs/review/review-rules.md` ("Swift / Desktop conventions"), `docs/design/desktop-style-guide.md`, `docs/inventory/files.md` (FILES-01), `docs/inventory/agent-actions.md` (READ-02), `docs/inventory/features.md` (FEAT-01), `.claude/skills/add-desktop-feature`. Mockups: `docs/design/mockups/report-a-problem/`.

## Global Constraints

- The command never writes the main database file, the config, the pid file, logs, `last_sync.json`, `dblock.jsonl` or temp files; only SQLite's `-shm` (and, on a cleanly stopped install, a new empty `-wal`/`-shm` pair) may change (Decision 15).
- Nothing printed may contain a name, domain, email, id, path, raw flavor, raw `ai.provider`, workspace name, error text or log line (DIAG-01).
- Budgets: database deadline **4 s** (one `context.WithTimeout` started before the open), per-statement busy timeout **500 ms**, stop-waiting fallback **4.5 s**, crash scan **2 s** for all three files, hard stop **8 s**, Desktop CLI timeout **10 s**.
- Exit code is always 0 once the command starts; every failure becomes a line part `unknown (<reason>)`.
- `--json` keys, pinned: `text`, `version`, `macos`, `chip`, `provider`, `sources`, `flavor`, `partial`.
- Flavor printed only as `default` (empty or `dev`) or `corp` — the same rule as `HubIdentity.flavor(buildFlavor:)`.
- Times in the text are UTC, `yyyy-MM-dd HH:mmZ`.
- GitHub link: encoded URL ≤ **6 000** characters; field cap **2 000** characters; title = first line ≤ **80** characters.
- Every UI string lives in `ReportProblemCopy` (WatchtowerCore) and every diagnostics line text in `internal/diagnostics/text.go`, each pinned by a test.
- Colours only via `Tone` (`Tone.warning`, `Tone.success`); DesignKit buttons (`.kitPrimary`, `.kitSecondary`, `.kitQuiet`), `.card()`, `SettingsSection`; no row separators, no `Form`/`GroupBox`.
- The app writes the clipboard only when the user presses **Copy Report** or **Copy Link**.
- Inner loop only per task: `go test ./internal/<pkg>` / `go test ./cmd -run <Name>`, `make test-swift FILTER=<Class>`, `make lint-diff` (Go), `make lint-swift` (Swift; lint-diff never checks Swift). The full gate runs once, in Task 16.
- Tests that create files use `t.TempDir()`; tests that hold a SQLite lock close it in `t.Cleanup`; no test starts a real `claude`/`codex`.

## Review Focus

- A second **Retry** (or a re-open of the sheet) while a collection is running must not start a second `watchtower` process — test `testRetryWhileCollectingRunsOnce` in Task 14.
- The CLI may print a stray line before its JSON (a warning on stdout); the Desktop decodes the **last** non-empty stdout line — test `testDecodesLastJSONLine` in Task 13.
- A "What happened?" text of only spaces or newlines keeps Open GitHub Issue disabled — test `testWhitespaceOnlyKeepsOpenDisabled` in Task 14.
- A config path that is a directory (or a symlink loop) prints `Config: unreadable (other)` and exits 0 — case `config_is_directory` in `TestDiagnostics_InputFailures`, Task 8.
- Choosing Help → Report a Problem… while the sheet is already open brings it forward instead of stacking a second sheet — test `testSecondOpenReusesSheet` in Task 15.

---

### Task 1: SQLCipher connector — no checkpoint on close

**Depends on:** none

**Files:**
- Modify: `internal/sqlcipher/wt_connector.go` (field, C helper in the preamble, call in `Connect`)
- Test: `internal/sqlcipher/wt_connector_nockpt_test.go`

**Interfaces:**
- Produces: `sqlcipher.Connector.NoCheckpointOnClose bool`; `sqlcipher.ErrNoCheckpointGuard` (returned by `Connect` when SQLite does not report the setting on); package seam `var confirmNoCkpt = func(out int) bool { return out == 1 }` (test files cannot use cgo, so the test forces a failure through it).

- [ ] **Step 1: Write the failing tests** in `wt_connector_nockpt_test.go`:
  - `TestConnector_NoCheckpointOnClose`: build a WAL database in `t.TempDir()` through a writer `sql.OpenDB(&Connector{Path: "file:"+p, Params: "mode=rwc&_busy_timeout=500"})` with `PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t(x); INSERT … 3 rows`; copy `w.db`, `w.db-wal`, `w.db-shm` into a second dir while the writer is open (left-over WAL); open the copy with `&Connector{Path: "file:"+p2, Params: "mode=rw&_busy_timeout=500&_query_only=1", NoCheckpointOnClose: true}`, `SELECT count(*) FROM t` → 3, `PRAGMA wal_autocheckpoint` → 0, close. Assert the main file's size and sha256 and the `-wal` sha256 are unchanged. Control in the same test: the same copy opened **without** the flag changes the main file (checkpoint) — proves the test can fail.
  - `TestConnector_NoCheckpointGuardRequired`: set `confirmNoCkpt = func(int) bool { return false }` (restore in `t.Cleanup`); `db.Ping()` returns an error wrapping `ErrNoCheckpointGuard`.
- [ ] **Step 2: Run** `go test ./internal/sqlcipher -run 'TestConnector_NoCheckpoint'` — FAIL (unknown field).
- [ ] **Step 3: Implement.** Add `static int wt_no_ckpt_on_close(sqlite3 *db)` to the cgo preamble: `int out = -1; int rv = sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &out); return rv == SQLITE_OK ? out : -1;` (variadic, so a C wrapper is required). In `Connect`, after `driverInstance.open`, when `c.NoCheckpointOnClose`: call it on the `*SQLiteConn`'s `db`; if `!confirmNoCkpt(out)` close the conn and return `fmt.Errorf("%w (sqlite reported %d)", ErrNoCheckpointGuard, out)`; then exec `PRAGMA wal_autocheckpoint = 0`. Every other connector leaves the field false and is unchanged.
- [ ] **Step 4: Run** the same command — PASS; then `go test ./internal/sqlcipher` (the interop and parity tests stay green).
- [ ] **Step 5: Commit** `feat(sqlcipher): opt-in no checkpoint on close (#1527)`.

### Task 2: `db.OpenExistingContext`

**Depends on:** Task 1

**Files:**
- Modify: `internal/db/db.go` (`openExistingDSN`, new `openExistingWith`, new `OpenExistingContext`)
- Test: `internal/db/open_existing_context_test.go`

**Interfaces:**
- Consumes: `sqlcipher.Connector.NoCheckpointOnClose`, `sqlcipher.ErrNoCheckpointGuard`.
- Produces: `func OpenExistingContext(ctx context.Context, dbPath string, busy time.Duration) (*DB, error)` — `OpenExisting`'s DSN (`mode=rw`, `_query_only=1`, busy), connector with `NoCheckpointOnClose: true` wrapped by `lockmetrics.Wrap`, `PingContext(ctx)`, then `lockmetrics.Configure("")`. `func openExistingWith(ctx context.Context, dbPath string, c driver.Connector) (*DB, error)`. `openExistingDSN(ctx, dbPath, dsn)` — `OpenExisting`/`OpenExistingRW` pass `context.Background()`; their behaviour and every caller (`cmd/…`, `internal/db/compact.go`, `fts_rebuild.go`, `internal/hub/…`, `internal/agentlogdb/totals.go`) are unchanged.

- [ ] **Step 1: Write the failing tests:**
  - `TestOpenExistingContext_CancelledContext`: an already-cancelled ctx → error `errors.Is(err, context.Canceled)`, no file created next to a missing path.
  - `TestOpenExistingContext_LeftOverWALMainFileUntouched`: the left-over-WAL fixture from Task 1 (helper in this test file); open, count rows, close; main file and `-wal` hashes unchanged.
  - `TestOpenExistingContext_QueryOnly`: an `INSERT` fails.
  - `TestOpenExistingContext_NoDblockSink`: after the open `lockmetrics.Enabled()` is false.
- [ ] **Step 2: Run** `go test ./internal/db -run TestOpenExistingContext` — FAIL.
- [ ] **Step 3: Implement** the three functions above.
- [ ] **Step 4: Run** `go test ./internal/db -run 'TestOpenExistingContext|TestOpenExisting|TestCompact'` — PASS.
- [ ] **Step 5: Commit** `feat(db): OpenExistingContext with no checkpoint on close (#1527)`.

### Task 3: `daemon.PeekProcess`

**Depends on:** none

**Files:**
- Modify: `internal/daemon/pidfile.go` (`resolveProcess(path string, removeStale bool)`, `PeekState`, `PeekProcess`)
- Test: `internal/daemon/pidfile_peek_test.go`

**Interfaces:**
- Produces: `type PeekState int` with `PeekNone`, `PeekRunning`, `PeekGone`, `PeekReused`, `PeekUnknown`; `func PeekProcess(path string) (pid int, state PeekState, err error)` — never removes a file; `err` is `ReadPID`'s error (empty/unparsable → message starts `parsing pid file`; `errors.Is(err, fs.ErrPermission)` for permission). `FindProcess`, `FindConfirmedProcess` and other callers pass `removeStale = true` and behave as today.

- [ ] **Step 1: Write the failing tests:**
  - `TestPeekProcess_States` (table): no file → `PeekNone`; tagged file with the pid of an exited child process → `PeekGone`; untagged file with mtime 31 days back and a live pid → `PeekGone`; the test's own pid tagged with its real start time → `PeekRunning`; own pid with a start time 1 h off → `PeekReused`; identity seam failing → `PeekUnknown`; empty file → error containing `parsing pid file`; `garbage` → same; mode-000 file → `errors.Is(err, fs.ErrPermission)`. Each case asserts the pid file still exists afterwards (when it existed).
  - `TestPeekProcess_LeavesStalePIDFile`: dead pid → file bytes and mtime unchanged.
  - Keep the existing `FindProcess` tests green (stale files are still removed there).
- [ ] **Step 2: Run** `go test ./internal/daemon -run 'TestPeekProcess|TestFindProcess'` — FAIL.
- [ ] **Step 3: Implement**: add the `removeStale` parameter; map `processGone`/`processReused`/`processConfirmedSame`/`processUnknown` to the `Peek*` states; `pid == 0` with no error → `PeekNone`.
- [ ] **Step 4: Run** `go test ./internal/daemon` — PASS.
- [ ] **Step 5: Commit** `feat(daemon): PeekProcess, a pid probe that never removes the file (#1527)`.

### Task 4: Config — typed invalid value, read-only migration check

**Depends on:** none

**Files:**
- Modify: `internal/config/ai_routing.go` (`InvalidValueError`), `internal/config/feature_migrate.go` (`FeatureMigrationPending`, used by `MigrateFeatureGates`)
- Test: `internal/config/ai_routing_test.go`, `internal/config/feature_migrate_test.go`

**Interfaces:**
- Produces: `type InvalidValueError struct{ Msg string }` with `Error() string { return e.Msg }`; every error `AIConfig.Validate` returns is `*InvalidValueError` with the **same** message as today. `func FeatureMigrationPending(configPath string) (pending, legacy bool, err error)` — reads with a fresh viper, writes nothing; `pending = !v.IsSet("features.migrated")`, `legacy = pending && v.IsSet("digest.enabled") && !v.GetBool("digest.enabled")`; a missing file → `(false, false, nil)`.

- [ ] **Step 1: Write the failing tests:**
  - `TestAIConfigValidate_InvalidValueError` (table over every rejection: unknown preferred, unknown bucket, unknown fallback, fallback = preferred, fallback outside a pair, enabled without pair): `errors.As(err, &*InvalidValueError)` and `err.Error()` equals the current message literal (e.g. `unknown AI provider "zz"`).
  - `TestFeatureMigrationPending`: marker set → `(false,false)`; no marker + `digest.enabled: false` → `(true,true)`; no marker + digest true → `(true,false)`; no marker + digest absent → `(true,false)`; each case asserts the file's bytes and mtime unchanged.
  - Existing `MigrateFeatureGates` tests and `TestApplyLegacyDigestOff_MatchesOnDiskMigration` stay green.
- [ ] **Step 2: Run** `go test ./internal/config -run 'TestAIConfigValidate_InvalidValueError|TestFeatureMigrationPending'` — FAIL.
- [ ] **Step 3: Implement**; `MigrateFeatureGates` calls `FeatureMigrationPending` first and keeps its write unchanged.
- [ ] **Step 4: Run** `go test ./internal/config` — PASS.
- [ ] **Step 5: Commit** `feat(config): InvalidValueError and FeatureMigrationPending (#1527)`.

### Task 5: Diagnostics — error classes

**Depends on:** none

**Files:**
- Create: `internal/diagnostics/errorclass.go`
- Test: `internal/diagnostics/errorclass_test.go`

**Interfaces:**
- Produces: `func ErrorClass(msg string) string` returning one of `cancelled`, `timeout`, `rate_limit`, `quota`, `auth`, `not_found`, `network`, `parse`, `other`, checked in that order on the lower-cased message with the spec's markers; HTTP codes only in a status form `(status|http|status code)[ :=]*NNN` or `NNN <reason phrase>`.

- [ ] **Step 1: Write `TestErrorClass`** (table): one message per class from the spec's marker list (e.g. `"context canceled"` → `cancelled`, `"Post …: context deadline exceeded"` → `timeout`, `"HTTP 429 Too Many Requests"` → `rate_limit`, `"usage limit reached"` → `quota`, `"invalid_auth"` → `auth`, `"status 404"` → `not_found`, `"dial tcp: connection refused"` → `network`, `"invalid character 'x'"` → `parse`, `"boom"` → `other`); id-like `"channel C401X failed"` → `other`; order case `"timed out after status 401"` → `timeout`.
- [ ] **Step 2: Run** `go test ./internal/diagnostics -run TestErrorClass` — FAIL.
- [ ] **Step 3: Implement** with precompiled regexps for the status forms.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(diagnostics): stored-error classes (#1527)`.

### Task 6: Diagnostics — crash scan

**Depends on:** none

**Files:**
- Create: `internal/diagnostics/crash.go`
- Test: `internal/diagnostics/crash_test.go`

**Interfaces:**
- Produces: `type CrashScan struct { Count int; Time time.Time; TimeKnown bool; Place string; Stopped bool; ScannedMB int; NoLogs bool }` (`Place` is `""` for "location unknown"); `func ScanCrashes(files []string, deadline time.Time, now func() time.Time, loc *time.Location) CrashScan` — `files` in the order `watchtower.log`, `watchtower.log.1`, `daemon.log` (newest first for ties); missing/unreadable files skipped; all three skipped → `NoLogs`.

- [ ] **Step 1: Write the failing tests** (fixtures written to `t.TempDir()`):
  - `TestDiagnostics_CrashRuntimeHeaders`: `panic: x` + blank + `goroutine 7 [running]:` + `watchtower/internal/sync.(*Syncer).run(...)` → Count 1, Place `watchtower/internal/sync.(*Syncer).run`; `fatal error: concurrent map writes` + `goroutine 1 [running]:` also counts.
  - `TestDiagnostics_IgnoresLoggedPanicText`: `2026/11/04 09:00:00 recovered panic: x` → Count 0; `panic: x` with no `goroutine` header within 5 lines → Count 0.
  - `TestDiagnostics_CrashTimeAndPlace`, `TestDiagnostics_CrashTimeUnknownWithPlace` (no preceding timestamped line → `TimeKnown` false), `TestDiagnostics_CrashLocationUnknown` (frames only `runtime.`/`main.`… no `watchtower/`), `TestDiagnostics_CrashTimeAndLocationUnknown`, `TestDiagnostics_NoCrash`.
  - `TestDiagnostics_CrashTimeLocalToUTC`: `loc` fixed at +03:00, preceding line `2026/11/04 12:12:00` → `Time` = `2026-11-04 09:12Z`; a DST-overlap case in `Europe/Berlin` follows `time.ParseInLocation`.
  - `TestDiagnostics_CrashOrderAcrossFiles`: crashes in `.1` (later time) and `watchtower.log` (earlier time) → newest by time; equal/unknown times → `watchtower.log` wins over `.1` over `daemon.log`.
  - `TestDiagnostics_PanicDeeperThan256KB`: a crash at the start of a 5 MB file is found.
  - `TestDiagnostics_ScanBudget`: `now` seam advancing 1 s per read → `Stopped` true, `ScannedMB` set.
- [ ] **Step 2: Run** `go test ./internal/diagnostics -run 'Crash|Panic|ScanBudget'` — FAIL.
- [ ] **Step 3: Implement** with a `bufio.Scanner` (1 MiB max token) per file, a 5-line look-ahead window for the `goroutine N [` header, and the deadline checked between lines.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(diagnostics): crash scan over the logs (#1527)`.

### Task 7: Diagnostics — text model, report, runner

**Depends on:** none

**Files:**
- Create: `internal/diagnostics/text.go`, `internal/diagnostics/report.go`, `internal/diagnostics/runner.go`
- Test: `internal/diagnostics/text_test.go`, `internal/diagnostics/runner_test.go`

**Interfaces:**
- Produces:
  - `text.go`: constants for every fixed text in the spec's template and tables (`UnknownNoConfig = "unknown (no config)"`, `UnknownNoWorkspace`, `UnknownNoHome = "unknown (no home directory)"`, `UnknownNoDatabase`, `UnknownDatabaseBusy = "unknown (database busy)"`, `UnknownTimedOut = "unknown (timed out)"`, `UnknownInternal = "unknown (internal error)"`, the four `database unreadable: …` texts, `DatabaseNoCkptGuard = "unknown (database not opened: checkpoint guard unavailable)"`, the Daemon/Workspace/Config/AI/Crash variants, `PartialPrefix = "Partial report: "`, reasons `ReasonDatabaseBusy = "database busy"`, `ReasonLogScan = "log scan stopped"`, `ReasonTimedOut = "timed out at 8 s"`) and the format helpers for lines with values.
  - `report.go`: `type Report struct { Lines []string; Version, MacOS, Chip, Provider, Flavor string; Sources []string; Reasons []string }`; `func (r Report) Text() string` (lines joined by `\n`, plus `Partial report: <reasons comma-joined>` when `len(Reasons) > 0`); `func (r Report) JSON() ([]byte, error)` with exactly the eight pinned keys, `partial = len(Reasons) > 0`, `sources` never null.
  - `runner.go`: `type Budgets struct{ DB, DBFallback, LogScan, HardStop, Busy time.Duration }` and `var DefaultBudgets = Budgets{4 * time.Second, 4500 * time.Millisecond, 2 * time.Second, 8 * time.Second, 500 * time.Millisecond}`; `type Part func(ctx context.Context) (text string, reason string)` (reason `""` or one of the `Reason*`); `func SafeLine(p Part) Part` (recovers → `UnknownInternal`); `func Run(ctx context.Context, b Budgets, stages []Stage) Report` where `type Stage struct{ Name string; Deadline time.Duration; Parts []Slot }` and `Slot` names a line position + part; the runner builds lines in a worker goroutine, stops waiting at `HardStop` (unfinished slots → `UnknownTimedOut`, reason `ReasonTimedOut`), and collects reasons once each in the order database busy, log scan, timed out.
- [ ] **Step 1: Write the failing tests:**
  - `TestDiagnosticsText_Pinned`: a golden file `internal/diagnostics/testdata/text.golden` lists every constant `name = value`; the test regenerates and compares (`-update` flag rewrites).
  - `TestDiagnostics_LinePanicIsContained`: a panicking part → its slot `unknown (internal error)`, other slots printed.
  - `TestDiagnostics_HardStop`: `HardStop: 50ms`, a part blocking on a channel → slot `unknown (timed out)`, `Text()` ends `Partial report: timed out at 8 s`, returns within 200 ms.
  - `TestReport_JSONKeys`: unmarshal into `map[string]any` → exactly the eight keys; `partial` false with no reasons; `sources` is `[]`.
  - `TestReport_PartialReasonsOrderAndOnce`: reasons added busy, busy, logscan → `Partial report: database busy, log scan stopped`.
- [ ] **Step 2: Run** `go test ./internal/diagnostics -run 'Text_Pinned|LinePanic|HardStop|TestReport_'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(diagnostics): text model, report and budgeted runner (#1527)`.

### Task 8: Lines — config, workspace, AI, features

**Depends on:** Task 4, Task 7

**Files:**
- Create: `internal/diagnostics/lines_config.go`
- Test: `internal/diagnostics/lines_config_test.go`

**Interfaces:**
- Consumes: `config.InvalidValueError`, `config.FeatureMigrationPending`, `config.ApplyLegacyDigestOff`, `config.DataRoot`, `config.WorkspaceDirsWithDatabase`, `config.ValidWorkspaceRe`, `features.All`, Task 7's text constants.
- Produces: `type Env struct { ConfigPath, WorkspaceFlag string; Getenv func(string) string; DataRoot func() (string, error) }`; `type Resolved struct { Cfg *config.Config; ConfigLine string; ConfigState ConfigState; Root string; Workspace string; WorkspaceLine string /* "" when resolved */; WorkspaceReason string /* text for dependent lines */ }`; `func Resolve(env Env) Resolved` (precedence: config path → load → data root → workspace; never calls `WorkspaceDir`/`DBPath`); `func AILine(env Env, r Resolved) (text, jsonProvider string)`; `func FeaturesLine(r Resolved, env Env) string`. `ConfigState` = `ConfigOK`, `ConfigNone`, `ConfigInvalid`, `ConfigUnreadable`, `ConfigNoHome`.
- [ ] **Step 1: Write the failing tests** as `TestDiagnostics_InputFailures`-style tables in this file (the cmd-level test in Task 11 repeats the ones marked e2e):
  - `TestDiagnostics_NoConfig`, `TestDiagnostics_BrokenConfig` (YAML parse error → `Config: unreadable (parse)`), `TestDiagnostics_UnreadableConfig` (mode 000 → `unreadable (permission)`), case `config_is_directory` → `unreadable (other)`, invalid `ai.provider` → `unreadable (invalid value)`.
  - Workspace cases with exact lines: `workspace_not_chosen` (two dirs with `watchtower.db` → `Workspace: not chosen (2 found)`, no names), `workspace_none_yet`, `workspace_lookup_failed`, `workspace_flag_wins`, `workspace_flag_invalid` (`../x` → `unknown (invalid name)`), `workspace_flag_not_found`, `workspace_config_invalid_name`, `workspace_config_not_found`, `no_home_dir` (`ConfigPath ""` → `Config: unknown (no home directory)`, no Workspace line, every dependent reason `unknown (no home directory)`), `no_home_dir_config_path_set` (`DataRoot` error → `Config: ok`, `Workspace: unknown (no home directory)`).
  - `TestDiagnostics_AILine` cases with exact text + JSON provider: `provider_absent_default` → `AI: Claude Code (default, not chosen)`, `Claude Code`; `provider_empty_string` → same; `provider_claude_set` → `AI: Claude Code`; `provider_codex`; `provider_ollama` → JSON `Ollama (or another local server)`; `provider_env_only` (`WATCHTOWER_AI_PROVIDER=codex`) → `AI: Codex (from environment)`; `provider_env_overrides_file`; `provider_unknown_value` → `AI: unknown (not a known provider)`, JSON `""`, raw value absent; `reserve_automatic`, `reserve_off`, `reserve_none`; `fallback_unknown`, `fallback_same_as_preferred`, `fallback_not_a_pair`, `fallback_enabled_without_pair` → `· reserve invalid`; `bucket_unknown` → `· provider settings invalid`; `config_missing` → `AI: not set up (no config)`, JSON `Not set up yet`; `config_parse_error`, `config_permission` → `AI: unknown (no config)`, JSON `""`; `no_home_dir` → `AI: unknown (no home directory)`, JSON `""`.
  - `TestDiagnostics_FeaturesLine` (enabled ids comma-joined in registry order) and `TestDiagnostics_FeaturesLegacyNotMigrated` (`digest.enabled: false`, no marker → the nine gated features absent and suffix `(not yet migrated)`; config bytes unchanged).
- [ ] **Step 2: Run** `go test ./internal/diagnostics -run 'Config|Workspace|AILine|Features|no_home'` — FAIL.
- [ ] **Step 3: Implement.** The raw read for an invalid AI section uses a fresh viper with `SetEnvPrefix("WATCHTOWER")`, `AutomaticEnv()`, the `.`→`_` replacer, then maps every value through `KnownAIProvider` before it is used.
- [ ] **Step 4: Run** `go test ./internal/diagnostics` — PASS.
- [ ] **Step 5: Commit** `feat(diagnostics): config, workspace, AI and features lines (#1527)`.

### Task 9: Lines — database parts

**Depends on:** Task 2, Task 5, Task 7

**Files:**
- Create: `internal/diagnostics/lines_db.go`, `internal/diagnostics/sources.go`
- Test: `internal/diagnostics/lines_db_test.go`

**Interfaces:**
- Consumes: `db.OpenExistingContext`, `ErrorClass`, Task 7's runner and texts.
- Produces: `type DBParts struct { Sources, QuickConnections, PipelineRuns, Schema string; Kinds []string /* form labels */; Reasons []string }`; `func ReadDB(ctx context.Context, path string, open func(context.Context, string) (*db.DB, error)) DBParts` (production passes `func(ctx, p) { return db.OpenExistingContext(ctx, p, 500*time.Millisecond) }`) (one 4 s deadline is the caller's ctx; stop-waiting at `DBFallback` inside); `var SourceTables = []SourceTable{…}` (the spec's mapping, one entry per kind: table, filter, status map, unit, form label or `""` for no checkbox); `func OpenErrorText(err error) string` mapping SQLite codes to the `database unreadable: …` / checkpoint-guard texts.
- [ ] **Step 1: Write the failing tests** on a migrated test DB (`db.OpenTestDB` copied to a file) and fakes:
  - `TestDiagnostics_SourcesLine`: rows across Slack (ok, revoked, removed, enabled=0), Google (gmail+calendar), Jira, Confluence (`needs_consent`), Linear, Email `imap`/`outlook`, CalDAV, external_connections → exact `Sources:` text per the spec mapping (`removed` not counted; Outlook as `Outlook <n>`; `<n> spaces` for Confluence) and `Kinds` = form labels only (Outlook → `Email over IMAP`; CalDAV and Quick Connections absent).
  - `TestDiagnostics_SourcesMissingTable`: drop `linear_accounts` → `Linear unknown`, others printed; an unknown status value → `<k> unknown state`.
  - `TestDiagnostics_AccountTablesMapped`: every `%_accounts` table in `sqlite_master` has a `SourceTables` entry.
  - Cases `quick_connections_count`, `quick_connections_missing_table`.
  - `TestDiagnostics_RecentErrors`: 25 error rows → 20 newest, `HH:mmZ`, phase, class from `ErrorClass`; no rows → `none`; `error_msg` text never appears.
  - `TestDiagnostics_DatabaseLine`: `schema <max goose version>`; no goose table → `schema unknown`.
  - Open-error cases `db_missing`, `db_not_a_database` (random bytes), `db_corrupt` (valid header, damaged page), `db_permission` (mode 000), `db_no_ckpt_guard` (open fake returns `sqlcipher.ErrNoCheckpointGuard`), `db_other` → exact texts.
  - `TestDiagnostics_DeadlineMidway`: fake open whose queries sleep 1.5 s; `DB: 4s` → parts finished before the deadline kept, the rest `unknown (database busy)`, reason busy, total < 5 s.
  - `busy_single_statement`: one query returns `SQLITE_BUSY` → that part busy, reason busy.
- [ ] **Step 2: Run** `go test ./internal/diagnostics -run 'Sources|AccountTables|quick_|RecentErrors|DatabaseLine|db_|Deadline|busy_'` — FAIL.
- [ ] **Step 3: Implement** with the command's own `QueryContext` aggregates (`SELECT status, enabled, count(*) … GROUP BY status, enabled`; `provider` split for `email_accounts`; `gmail_enabled`/`calendar_enabled` for Google).
- [ ] **Step 4: Run** `go test ./internal/diagnostics` — PASS.
- [ ] **Step 5: Commit** `feat(diagnostics): database parts with one deadline (#1527)`.

### Task 10: Lines — version, machine, daemon, logs, crash, policy, iPhone

**Depends on:** Task 3, Task 6, Task 7

**Files:**
- Create: `internal/diagnostics/lines_local.go`
- Test: `internal/diagnostics/lines_local_test.go`

**Interfaces:**
- Consumes: `daemon.PeekProcess`, `ScanCrashes`, `policy.Policy`.
- Produces: `type Build struct{ Version, Commit, Flavor, AppVersion string }`; `func VersionLine(b Build) (text, flavor string)`; `func MachineLine(sysctl func(string) (string, error)) (text, macos, chip string)` (chip mapping: brand `Apple M<n>[ Pro|Max|Ultra]` → `Apple M<n>` for n 1–5, else `Other`); `func DaemonLine(pidPath, lastSyncPath string, now time.Time, peek func(string) (int, daemon.PeekState, error)) string`; `func SyncRow(lastSyncPath string) (row string, ok bool)`; `func LogsLine(dir string) string`; `func CrashLine(c CrashScan) (text, reason string)`; `func PolicyPart(p policy.Policy) string`; `func IPhonePart(flag string) string` (`""` when not given).
- [ ] **Step 1: Write the failing tests:**
  - `TestDiagnostics_VersionLine`: flavor `""`/`dev` → `default`, `acme-corp` → `corp` (raw value absent); no app version → no `· app` part.
  - `TestDiagnostics_SysctlFailure`: error → `macOS unknown`, chip `Other`; `Apple M3 Max` → `Apple M3`; `Apple M7` → `Other`.
  - `TestDiagnostics_DaemonLine` cases `no_pid_file`, `stale_dead_pid`, `reused_pid`, `old_untagged`, `running_confirmed`, `identity_unknown`, `empty_file`, `garbage_file`, `permission_denied`, `last_sync_missing` (`no cycle yet`), `last_sync_corrupt` (`last cycle unknown`) with the spec's exact texts; a fake `peek` for states, real files for the read errors.
  - Cases `sync_row_missing`, `sync_row_corrupt` (`  sync result unknown`).
  - `TestDiagnostics_LogMissing`, `TestDiagnostics_LogUnreadable`.
  - `CrashLine` cases: none → `Crash: none in the logs`; one with time and place; time unknown → `last time unknown, in <place>`; no place → `in location unknown`; `NoLogs` → `Crash: unknown (no logs)`; `budget_logscan_with_crash` / `budget_logscan_none_found` (`Crash: none in the first <N> MB of the logs (scan stopped)`) with reason `log scan stopped`.
  - `TestDiagnostics_PolicyLine` via `policytest.Set`: unmanaged → `no`, managed → `yes`, managed with a defect → `yes (with errors)`.
  - `TestDiagnostics_IPhoneFlag`: `on`/`off`/absent.
- [ ] **Step 2: Run** `go test ./internal/diagnostics -run 'Version|Sysctl|Daemon|sync_row|Log|Crash|Policy|IPhone|budget_logscan'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/diagnostics` — PASS.
- [ ] **Step 5: Commit** `feat(diagnostics): local lines (#1527)`.

### Task 11: `watchtower diagnostics` command

**Depends on:** Task 8, Task 9, Task 10

**Files:**
- Create: `cmd/diagnostics.go`
- Modify: `cmd/root.go` (`shouldSweepTemp(role string) bool`, `var startTempSweep = func() { go sweepStaleTemp() }`), `cmd/audit_cli_test.go` (`cliNoContentCommands["diagnostics"] = true // kinds, counts, states and error classes only (DIAG-01)`)
- Test: `cmd/diagnostics_test.go`

**Interfaces:**
- Consumes: everything in `internal/diagnostics`; `cmd.Version`, `Commit`, `BuildFlavor`; `flagConfig`, `flagWorkspace`.
- Produces: `watchtower diagnostics [--json] [--app-version <v>] [--iphone on|off]`; plain output = `Report.Text()`, `--json` = `Report.JSON()` as the last stdout line; own no-op `PersistentPreRunE`; exit 0; stages: local (config, workspace, AI, features, version, machine, policy, iPhone, daemon, logs, sync row), database (4 s), crash scan (2 s), hard stop 8 s. Line order exactly as the spec's template.
- [ ] **Step 1: Write the failing tests** (seed a full fake install under `t.TempDir()` with `HOME` and `WATCHTOWER_CONFIG_PATH` set via `t.Setenv`):
  - `TestDiagnostics_WritesNothing`: three situations (writer running, stopped clean, left-over WAL); seeds config with `db.schema_format` below current and no `features.migrated`, a pending migration, WAL frames, a stale pid file, `last_sync.json`, logs, a stale temp file (mtime −20 min) in a temp `TMPDIR`; `startTempSweep` swapped for a synchronous call. After `diagnostics`: config, pid file, `last_sync.json`, logs, temp file byte-identical with the same mtime; data dir listing unchanged except `-wal`/`-shm`; goose version and per-table row hashes unchanged; main DB size + sha256 unchanged in all three. Control: `version` through the same seam removes the temp file.
  - `TestDiagnostics_LeftOverWALMainFileUntouched`: main file and `-wal` hashes unchanged.
  - `TestDiagnostics_BusyDatabaseFinishesInTime`: another connection holds `PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE` (released in `t.Cleanup`) → exit 0, < 7.5 s, Sources/pipeline runs/schema `unknown (database busy)`, size/policy/iPhone printed, last line `Partial report: database busy`, JSON `partial: true`.
  - `TestDiagnostics_BusyKeepsFileParts`, `busy_and_logscan` (reasons in order), `budget_db_before_open`.
  - `TestDiagnostics_NoDatabase`; `no_home_dir` golden: `HOME=""`, no `WATCHTOWER_CONFIG_PATH` → full text equals `testdata/no_home_dir.golden`, exit 0, no fatal.
  - `TestDIAG01_NoNamesOrText`: `logcanary.Marker` canaries in workspace name (`active_workspace` and `--workspace`), `ai.provider` (file and `WATCHTOWER_AI_PROVIDER`, unknown value), account names/team domains/emails/labels, channel/space/project names, Quick Connection and automation names, `pipeline_runs.error_msg`, account status/error text, `last_sync.json` error, a panic message in `watchtower.log`, `BuildFlavor`; run plain and `--json` across the normal, invalid-config and busy cases → output contains no marker, no `/Users/` and no `\w+:[A-Z0-9]{6,}` shape.
  - `TestDiagnostics_FormOptions`: parse `.github/ISSUE_TEMPLATE/bug_report.yml`; every `chip`/`provider` value the mapping emits is an option; every checkbox label of `sources` has a kind and every form-mapped kind is a label; skip list `Calendar (CalDAV/ICS)`, `Quick Connections`.
  - `TestDiagnostics_InputFailures` (e2e table over the binary path): one case per Inputs row and budget not already covered in `internal/diagnostics` — at least `config_is_directory`, `workspace_not_chosen`, `db_not_a_database`, `budget_hard_stop` (hard stop seam 50 ms), asserting the exact line.
  - `TestCLIAudit_EveryCommandIsDecided` passes with the new entry.
- [ ] **Step 2: Run** `go test ./cmd -run 'TestDiagnostics|TestDIAG01|TestCLIAudit'` — FAIL.
- [ ] **Step 3: Implement** the command, the sweep seam and the audit entry.
- [ ] **Step 4: Run** the same — PASS; then `make lint-diff`.
- [ ] **Step 5: Commit** `feat(cmd): watchtower diagnostics (#1527)`.

### Task 12: Docs, inventory, issue form, guide

**Depends on:** Task 11

**Files:**
- Create: `docs/inventory/diagnostics.md` (DIAG-01, Enforced, guard `cmd/diagnostics_test.go::TestDIAG01_NoNamesOrText` + `TestDiagnosticsText_Pinned`, locked since the merge date, approval ask #1026), `docs/features/report-a-problem.md` (contracts, dual paths, `--json` keys, budgets, v1 limits — from the spec)
- Modify: `docs/inventory/README.md` (row: Diagnostics → `diagnostics.md` → `cmd/diagnostics.go`, `internal/diagnostics/`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/ReportProblem/`), `docs/inventory/agent-actions.md` (changelog line: `diagnostics` decided as a no-content CLI command, READ-02 unchanged), `CLAUDE.md` (feature index line), `docs/daemon-pipeline.md` (data-paths table: diagnostics as a read-only reader of `watchtower.log`/`.1`/`daemon.log`, `daemon.pid`, `last_sync.json` and the database; panics land in `watchtower.log`), `.github/ISSUE_TEMPLATE/bug_report.yml` (`version` and `logs` descriptions mention **Help → Report a Problem…** and `watchtower diagnostics`; ids and options unchanged), `docs/guide/troubleshooting/README.md` (section "Report a problem": the menu item, what is included and what is never included, Discussions for questions, `watchtower diagnostics` from the terminal, the corporate build saves a file)
- Test: `go test ./docs/guide` (8 KB section cap), `go test ./cmd -run TestDiagnostics_FormOptions`

- [ ] **Step 1:** Write the files above (follow `docs/guide/WRITING.md` for the guide page).
- [ ] **Step 2: Run** `go test ./docs/guide ./internal/learn` and `go test ./cmd -run TestDiagnostics_FormOptions` — PASS.
- [ ] **Step 3: Commit** `docs: Report a Problem — inventory DIAG-01, feature note, guide (#1527)`.

### Task 13: WatchtowerCore — copy, CLI answer, link builder

**Depends on:** none (the JSON keys are pinned by the spec)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ReportProblem/ReportProblemCopy.swift`, `DiagnosticsAnswer.swift`, `ReportProblemLink.swift`
- Test: `WatchtowerDesktop/Tests/Core/ReportProblemCopyTests.swift`, `DiagnosticsAnswerTests.swift`, `ReportProblemLinkTests.swift`

**Interfaces:**
- Produces:
  - `package enum ReportProblemCopy` — one `static let` per string in the spec's "UI strings" table, plus `static func failed(_ reason: FailureReason) -> String`, `enum FailureReason { case timedOut, missing, exit(Int32), unreadable }`, `static func saveFailed(_ reason: String) -> String`, `static let reportCopied`, `linkCopied`.
  - `package struct DiagnosticsAnswer: Decodable, Equatable { text, version, macos, chip, provider, flavor: String; sources: [String]; partial: Bool }`; `static func decode(stdout: Data) throws -> DiagnosticsAnswer` (last non-empty line).
  - `package enum ReportProblemLink { static let maxURLLength = 6_000; static let maxTextLength = 2_000; static func make(userText: String, answer: DiagnosticsAnswer?, appVersion: String, macOS: String, repository: URL = ReleaseLinks.repository) -> (url: URL, shortened: Bool) }` — query `template=bug_report.yml`, `title`, `version`, `macos`, `chip`, `provider`, `actual`, `logs`; three-step shortening by encoded length; `answer == nil` → only `version` (app) and `macos`.
- [ ] **Step 1: Write the failing tests:**
  - `ReportProblemCopyTests.testStringsArePinned`: every string equals the spec literal (one assertion per key, incl. the four failure reasons formatted).
  - `DiagnosticsAnswerTests.testDecodesPinnedKeys`, `testDecodesLastJSONLine` (stdout `warning: x\n{…}\n`), `testMissingKeyFails`.
  - `ReportProblemLinkTests`: `testShortTextYieldsFullLink`; `testASCIIAtCapFits`, `testCyrillicAtCapFits`, `testCJKAtCapFits` (2 000 characters each → `url.absoluteString.count <= 6_000`); `testStep3NeverSplitsCharacterOrEscape` (decode the `actual` value back; it is a prefix of the input followed by `… (full text in the pasted report)`); `testOverBudgetReplacesLogs` (`logs` = `Paste the report from Watchtower here.`, `shortened` true); `testFailedStateLink` (nil answer → no `chip`, `provider`, `logs`); `testTitleIsFirstLineCapped80`; `testLinkKeysMatchForm` (reads `.github/ISSUE_TEMPLATE/bug_report.yml` via `#filePath`; every query key except `template`/`title` is a form id).
- [ ] **Step 2: Run** `make test-swift FILTER='ReportProblemCopyTests|DiagnosticsAnswerTests|ReportProblemLinkTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): Report a Problem copy, answer and link (#1527)`.

### Task 14: WatchtowerCore — `ReportProblemModel`

**Depends on:** Task 13

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ReportProblem/ReportProblemModel.swift`
- Test: `WatchtowerDesktop/Tests/Core/ReportProblemModelTests.swift`

**Interfaces:**
- Consumes: Task 13's types; `CLIRunnerProtocol.run(args:timeout:)`.
- Produces: `@MainActor @Observable package final class ReportProblemModel` with
  - `init(runner: any CLIRunnerProtocol, appVersion: String, macOS: String, iPhoneOn: Bool, isCorp: Bool, openURL: @escaping (URL) -> Bool, writePasteboard: @escaping (String) -> Void, writeFile: @escaping (String, URL) throws -> Void)`;
  - `enum Phase { case collecting, ready(DiagnosticsAnswer), failed(ReportProblemCopy.FailureReason) }`, `enum Notice { case none, opened, tooLong, browserFailed, saveFailed(String), copied(CopiedKind) }`;
  - `var text: String` (capped at 2 000), `phase`, `notice`, `canOpen: Bool` (non-corp, not collecting, trimmed text non-empty), `canSave: Bool` (not collecting), `afterOpen: Bool` (Cancel shows as Done), `report: String` (user text + diagnostics or the partial lines), `diagnosticsText: String`;
  - `func start()`, `func retry()`, `func openIssue()`, `func copyReport()`, `func copyLink()`, `func save(to url: URL)`, `func cancel()`.
  - CLI args: `["diagnostics", "--json", "--app-version", appVersion, "--iphone", iPhoneOn ? "on" : "off"]`, timeout 10 s.
- [ ] **Step 1: Write the failing tests** (fake runner, fake opener/pasteboard/writer):
  - `testDiagnosticsArguments`; `testMissingCLI` (launch error → `.failed(.missing)`); `testTimeoutShowsRetry` (`nonZeroExit(-1)` → `.timedOut`); `testNonZeroExit` (exit 3 → `.exit(3)`); `testUndecodableJSON` (`.unreadable`); `testBusyDatabaseLinesShown` (answer with `partial: true` → `.ready`); `testRetryWhileCollectingRunsOnce` (two `retry()` while the runner is suspended → one run).
  - `testOpenNeedsTextInEveryState` (collecting/ready/failed × empty/text) and `testWhitespaceOnlyKeepsOpenDisabled`.
  - `testSheetStaysOpenAfterOpen` (opener true → `.opened`, `afterOpen`, text kept); `testBrowserFailureOffersCopyLink` (opener false → `.browserFailed`, pasteboard untouched until `copyLink()`); `testClipboardWrittenOnlyByCopyButtons` (start, open success, open failure, save → zero pasteboard writes; `copyReport()` then `copyLink()` → two writes with the report then the link, notices `Report copied.` / `Link copied.`); too-long link → `.tooLong`.
  - `testSaveFailureShowsReason` (writer throws → `.saveFailed(localizedDescription)`); `testCorpBuildOffersSaveOnly` (`canOpen` false always, `openIssue()` does nothing); `testCancelWhileCollectingTerminates` (the runner's task is cancelled; nothing written); `testReportCarriesOnlyCLITextAndUserText` (`report` == user text + `\n\n` + answer `text`, nothing else).
- [ ] **Step 2: Run** `make test-swift FILTER=ReportProblemModelTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): ReportProblemModel (#1527)`.

### Task 15: Sheet, entry points, shots

**Depends on:** Task 14

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/ReportProblem/ReportProblemSheet.swift`, `WatchtowerDesktop/Sources/App/AppState+ReportProblem.swift`
- Modify: `WatchtowerDesktop/Sources/App/WorkbenchCommands.swift` (`HelpCommands`: `Report a Problem…` after `Watchtower User Guide`), `WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift` (Logs section: the button beside **Open Logs**), the main window's sheet host, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+ReportProblem.swift` (render `ReportProblemSheet` over fixture models; delete `ReportProblemMockCopy`)
- Test: `WatchtowerDesktop/Tests/ReportProblemPresentationTests.swift`

**Interfaces:**
- Consumes: `ReportProblemModel`, `ReportProblemCopy`, `AppState.bringMainWindowForward(windows:activate:)`, `HubIdentity.bundleFlavor()`, `CLIBinaryStore`/the app's `CLIRunner`.
- Produces: `AppState.reportProblem()` (always fronts the main window, then presents; a second call while shown brings the same sheet forward), `AppState.reportProblemModel: ReportProblemModel?` (nil when closed); `ReportProblemSheet(model:)` rendering every state of the mockups: collecting, empty, filled, busy, failed, opened, tooLong, browserFailed, saveFailed, corp, narrow (buttons stack via `ViewThatFits`), and the Settings entry.
- [ ] **Step 1: Write the failing tests:** `testMenuFrontsMainWindow` (no window → opener called, then the model is set), `testSettingsEntryFrontsVisibleMainWindow` (visible main window behind Settings → `activate` and `makeKeyAndOrderFront` before the model is set; injected windows/activate), `testSecondOpenReusesSheet`, `testCorpFlavorBuildsCorpModel`.
- [ ] **Step 2: Run** `make test-swift FILTER=ReportProblemPresentationTests` — FAIL.
- [ ] **Step 3: Implement** the sheet with DesignKit only (`.kitPrimary` Open GitHub Issue — or Save Diagnostics… in corp —, `.kitSecondary`, `.kitQuiet`, `.card()`, `Tone.warning`/`Tone.success`, `.textFieldStyle(.kit)` where a field is used, `TextEditor` in a `.card()`), every string from `ReportProblemCopy` (corp: corp intro and corp placeholder, no public note), **Save Diagnostics…** through `NSSavePanel` with the default name `watchtower-diagnostics-<yyyy-MM-dd>.txt` calling `model.save(to:)`, Discussions link to `ReleaseLinks.repository/discussions` (hidden in corp); wire the menu, Settings button and AppState.
- [ ] **Step 4: Run** the presentation tests — PASS; `make lint-swift`.
- [ ] **Step 5: Compare with the mockups.** Run `make desktop-shots DESKTOP_SHOTS=build/report-problem-shots` (or `cd WatchtowerDesktop && DESKTOP_SHOTS_DIR=… swift test --filter DesignShotsTests/testReportProblemShotsRender`); open each `report-problem-*` PNG next to the committed one in `docs/design/mockups/report-a-problem/` (light and dark): same text, same buttons and their enabled state, no row separators, nothing clipped at 360 pt. Copy the new PNGs over the committed ones only where the difference is intended, and say which in the commit message.
- [ ] **Step 6: Commit** `feat(desktop): Report a Problem sheet, Help menu and Settings entry (#1527)`.

### Task 16: Phase gate (controller)

**Depends on:** Task 1 – Task 15

- [ ] **Step 1:** `make test > build/gate-go.log 2>&1; echo "exit=$?"` — exit 0.
- [ ] **Step 2:** `make test-swift > build/gate-swift.log 2>&1; echo "exit=$?"` — exit 0 (includes the Kit).
- [ ] **Step 3:** `make lint-all > build/gate-lint.log 2>&1; echo "exit=$?"` — exit 0.
- [ ] **Step 4:** `go test -race ./internal/diagnostics ./internal/daemon -run 'TestPeekProcess|TestDiagnostics|HardStop'` — PASS.
- [ ] **Step 5:** Fix any failure in the owning task's files, re-run only the failing step, commit `chore: Report a Problem gate fixes (#1527)` if anything changed.
