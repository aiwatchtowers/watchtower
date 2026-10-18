# Agent analytics in `agentlog.db` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the agent analytics tables out of `watchtower.db` into `<workspace>/agentlog.db`, import in the background through the daemon only, keep every existing row.

**Architecture:** A new package `internal/agentlogdb` owns the sidecar file (opener, goose Provider migrations, every `agent_log_*` query, the one-time move). `internal/agentlog` (scan) and `internal/agentreport` (report) take two handles: `*db.DB` for `watchtower.db` reads, `*agentlogdb.DB` for analytics. `agents enable` only flips the switch; the daemon imports and records progress.

**Tech Stack:** Go 1.26, `modernc.org/sqlite`, goose v3.27.1 Provider API; SwiftUI (WatchtowerCore models + Analytics pane).

**Spec:** `docs/superpowers/specs/2026-10-18-agentlog-db-design.md` (technical, read it whole) and `2026-10-18-agentlog-db-business.md` (owner-approved, ask #350 — covers the FEAT-03/PROJ-02 amendments and moving the analytics assertion out of `TestProj02_DeleteProjectLeavesNoRows`).

## Global Constraints

- File: `filepath.Join(filepath.Dir(cfg.DBPath()), "agentlog.db")`, mode 0600 for db/`-wal`/`-shm`.
- Connection: one connection, WAL, `synchronous=NORMAL`, `foreign_keys=1`, `busy_timeout=5000`, `_txlock=immediate`; **not** through the lock-metrics driver.
- Migrations: `internal/agentlogdb/migrations/*.sql` via `goose.NewProvider` only — never the global goose state; flock `agentlog.db.migrate.lock`, 2-minute wait.
- Analytics code never opens a write transaction on `watchtower.db`, except the move's sliced row delete (5,000 rows per transaction).
- Move flock: `agentlog.db.move.lock`; marker `agent_log_meta.moved_from_main` (RFC 3339 UTC); copy chunks 5,000 rows, `INSERT OR IGNORE`.
- The `agent_log_*` tables stay (empty) in `watchtower.db` this release; `00116`/`00125` are not edited.
- `agentAnalyticsBudget` stays `30 * time.Second` until the owner picks a value from Task 1's measurement.
- `agents report` / `agents stats` never run the move and never write `watchtower.db`.
- New pinned overview key `import`: `{"state": "not_started"|"loading"|"done", "files_stored": N, "updated_at": "..."}`.
- UI string: `Loading history — N files so far` (English, en dash).
- Guard tests keep their names; repo docs/comments in English.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`); the full gate runs once at the end (controller).

## Review Focus

1. **Upgrade on a live install while the Desktop polls the report** — the report must answer (possibly with fewer sessions) and never start a copy; covered in Task 3 (`TestAgentsReport_BeforeMoveNeitherCopiesNorWrites`).
2. **Daemon killed mid-copy, then restarted** — no duplicates, counts equal; Task 3 (`TestMoveFromMain_InterruptedMidCopyResumes`).
3. **Scan started before the move finished** (CLI `agents scan` racing the daemon's upgrade step) — must refuse, not reparse from 0; Task 3 (`TestScan_RefusesBeforeMove`).
4. **A workbench deleted and recreated on the same folder after the move** — adoption without FK SET NULL; Task 2 (`TestAgentLog_SurvivesWorkbenchDeleteAndIsAdopted`).
5. **Sibling folder `/x/proj-tools` next to `/x/proj`** — progress must reach `done`; Task 4 (`TestScan_ImportDoneWithSiblingFolderFiles`).

---

### Task 1: Measure the full import with the #410 fix

Not a code change. Gives the owner the number for the budget decision (business spec decision 1).

**Files:** none committed. Results go into a board comment on #849 and an ask.

- [ ] **Step 1:** Build the binary from `fix/agentlog-replay-check-plan` (PR #410) in its worktree: `go build -o <scratch>/wt-410 .`.
- [ ] **Step 2:** Create a temp workspace whose `watchtower.db` is fresh: a temp config (`--config`) pointing at a temp data dir, `workspace init`-equivalent via `db.Open`, then insert one workbench row with `folder_path` = the repo's main checkout (`/Users/user/PhpstormProjects/watchtower`). Do not touch the live data dir.
- [ ] **Step 3:** `/usr/bin/time -l <scratch>/wt-410 --config <tmp> agents enable --workbench 1 --json > <scratch>/measure.json 2> <scratch>/measure.time; echo "exit=$?"`. Reads `~/.claude/projects` read-only (AGENTLOG-05).
- [ ] **Step 4:** Record: wall time, user+sys CPU, max RSS, files scanned, events written, and `db lockstats` from the temp dir (p50/max hold per batch). Expected: no batch hold above 1 s.
- [ ] **Step 5:** Post one comment on #849 with the numbers and the derived "cycles to finish at 30 s per 15-min cycle"; file an ask (kind question) with budget options derived from the number. Delete the temp dir.

### Task 2: `internal/agentlogdb` — opener, schema, queries; scan and report on two handles

**Files:**
- Modify: `internal/db/db.go` — export a sidecar opener (no copy of the DSN/pragma code).
- Create: `internal/agentlogdb/db.go`, `internal/agentlogdb/migrations/00001_init.sql`, `internal/agentlogdb/agent_log.go`, `internal/agentlogdb/agent_report.go` (moved code), tests `internal/agentlogdb/*_test.go` (moved from `internal/db/agent_log_test.go`, the agent parts of `internal/db/agent_report_test.go` if present).
- Delete from `internal/db`: everything in `agent_log.go` except `SetWorkbenchAgentAnalytics`, `WorkbenchAgentAnalytics`, `AgentAnalyticsWorkbenchIDs` (move those three to `internal/db/workbench_agent_analytics.go`); `AgentReportSessions`, `AgentReportEvents` and their types from `agent_report.go` (keep `AgentReportTargets` + `AgentReportTarget`).
- Modify: `internal/agentlog/scan.go`, `internal/agentreport/build.go`, `internal/daemon/agent_analytics.go`, `internal/daemon/daemon.go` (holds the second handle), `cmd/agents.go`, `cmd/sync.go` (open/close the second handle next to `db.Open` at :526), and their tests.

**Interfaces:**
- Produces (`internal/db`): `func OpenSidecar(path string, migrations fs.FS) (*sql.DB, error)` — same DSN/pragmas/one-connection pool as `Open` minus the lock-metrics driver, goose Provider over `migrations`, flock `<path>.migrate.lock` (2 min), `tightenDBFilePerms`. Name may differ; it must be the single place the DSN is built.
- Produces (`internal/agentlogdb`): `type DB struct{ *sql.DB }`; `func Open(path string) (*DB, error)`; `func PathFor(mainDBPath string) string`; the moved methods with unchanged names and signatures on `*agentlogdb.DB` (`GetAgentLogFile`, `AgentLogFilesUnder`, `MarkAgentLogFileMissing`, `ApplyAgentLogBatch`, `AdoptAgentLogSessions`, `AgentLogSessionFolder`, `RepriceAgentLogEvents`, `AgentLogStats`, `AgentReportSessions`, `AgentReportEvents`) and the moved types (`AgentLogFile`, `AgentLogSession`, `AgentLogEvent`, `AgentLogBatch`, `AgentToolResult`, `AgentLogStats`…, `AgentReportSession`, `AgentReportEvent`). Change only: `AdoptAgentLogSessions(projectID int64, folder string, liveIDs []int64) (int64, error)`.
- Produces: `agentlog.Scan(ctx, main *db.DB, al *agentlogdb.DB, id int64, o Options) (*Result, error)`; `agentreport.BuildOverview(main *db.DB, al *agentlogdb.DB, workbenchID int64, since, now time.Time)`, `BuildSession(main *db.DB, al *agentlogdb.DB, workbenchID int64, sessionUUID string, now time.Time)`.
- Consumes: PR #410's commit (cherry-pick if not merged; rebase if merged).

- [ ] **Step 1: Move the tests first** into `internal/agentlogdb` against `agentlogdb.Open(t.TempDir()+"/agentlog.db")`; keep every name (`TestApplyAgentLogBatch_*`, `TestAgentLog_SurvivesWorkbenchDeleteAndIsAdopted`, `TestApplyAgentLogBatch_ReplayCheckSeeksKey` from #410, …). Rewrite `TestAgentLog_SurvivesWorkbenchDeleteAndIsAdopted` for D3: seed a session with `project_id = 7`, then `AdoptAgentLogSessions(9, folder, []int64{9})` adopts it (7 is no longer live); a session of another folder stays; a session whose `project_id` is in `liveIDs` and differs is not moved.
- [ ] **Step 2: Add** `TestOpen_SchemaAndPerms` (tables `agent_log_files/sessions/events/meta/import`, view `agent_log_session_totals`, indexes `idx_agent_log_events_session`, `idx_agent_log_events_kind`, `idx_agent_log_sessions_project`, no FK to `projects`/`terminal_sessions` in `pragma_foreign_key_list('agent_log_sessions')`, file mode 0600) and `TestOpen_DoesNotTouchGlobalGoose` (open a `watchtower.db` with `db.Open`, then `agentlogdb.Open`, then `db.Open` again on a second temp main db: both migrate fully).
- [ ] **Step 3: Run** `go test ./internal/agentlogdb` → FAIL (package missing).
- [ ] **Step 4: Implement** the opener, `00001_init.sql` (final 00116 + 00125 shape per spec D2, plus `agent_log_meta`, `agent_log_import(project_id INTEGER PRIMARY KEY, complete INTEGER NOT NULL, files_stored INTEGER NOT NULL, updated_at TEXT NOT NULL)`), move the code, apply the #410 replay query.
- [ ] **Step 5: `terminal_session_id` in Go** (spec D3): `scan.go` resolves it per slice with a `watchtower.db` read — add `func (db *DB) ClaudeTerminalSessionIDs(uuids []string) (map[string]int64, error)` in `internal/db` (read-only, no transaction) — and fills `AgentLogSession.TerminalSessionID *int64`; the upsert binds the value instead of the subselect. Test `TestScan_TerminalSessionIDResolvedFromMain` (match → id; none → NULL).
- [ ] **Step 6: Rewire** scan, report, daemon, cmd. Add `TestScan_NoWriteTxOnMain`: run a full scan with `main` opened via `db.OpenExisting` + `SetReadOnly()`; it must succeed (any write to `watchtower.db` fails under `query_only`).
- [ ] **Step 6b: Open failure** (spec "Error handling"): the daemon logs an `agentlog.db` open error and runs with a nil analytics handle; `phaseAgentAnalytics` then skips without a `pipeline_runs` row. Test `TestPhaseAgentAnalytics_NilAgentlogSkips`. `agents report` returns the open error (no fallback to `watchtower.db`).
- [ ] **Step 7: Run** `go test ./internal/agentlogdb ./internal/agentlog ./internal/agentreport ./internal/daemon ./internal/db` and `go test ./cmd -run 'Agents'` → PASS; `make lint-diff` → 0 issues.
- [ ] **Step 8: Commit** `agentlog: analytics tables in agentlog.db behind internal/agentlogdb (#849)`.

At the end of this task nothing reads or writes `agent_log_*` in `watchtower.db`; old rows there are invisible until Task 3.

### Task 3: The one-time move and the scan gate

**Depends on:** Task 2.

**Files:**
- Create: `internal/agentlogdb/move.go`, `internal/agentlogdb/move_test.go`.
- Modify: `cmd/sync.go` (`runSyncDaemon`: call the move before `daemon.New`, log failures, never block the daemon), `cmd/agents.go` (`enable` and `scan` call it; `report`/`stats` do not), `internal/agentlog/scan.go` (gate), tests in `cmd/agents_test.go`, `internal/agentlog/scan_test.go`.

**Interfaces:**
- Produces: `func MoveFromMain(ctx context.Context, main *db.DB, al *DB, lockPath string) error` (lockPath = `<agentlog.db>.move.lock`); `func (d *DB) Moved() (bool, error)`; `var ErrNotMoved = errors.New("agent analytics: rows not moved from watchtower.db yet")`.
- Consumes (`internal/db`): `func (db *DB) HasTable(name string) (bool, error)` if none exists (add it).
- `agentlog.Scan` returns `agentlogdb.ErrNotMoved` when `!Moved()`; the daemon phase logs it once per cycle and skips.

- [ ] **Step 1: Tests** in `move_test.go`, seeding `watchtower.db` through raw SQL inserts into the still-existing 00116 tables:
  - `TestMoveFromMain_CopiesAllRows` — files, sessions, events (one session whose `source_path` file does not exist); equal counts and equal `agent_log_session_totals` rows; main tables exist and are empty; marker set.
  - `TestMoveFromMain_InterruptedMidCopyResumes` — inject a failure after the first chunk (test seam on chunk size = 2 and a hook), run again: counts equal, no duplicates.
  - `TestMoveFromMain_InterruptedBeforeDeleteResumes` — marker set, main rows still present: second run deletes them, copies nothing (counts in agentlog unchanged).
  - `TestMoveFromMain_FreshInstall` — empty main tables: marker set, nothing copied.
  - `TestMoveFromMain_TwoMoversOneCopy` — two goroutines, each with its own `db.Open`/`agentlogdb.Open` handles on the same paths: both return nil; counts equal; no duplicates.
  - `TestMoveFromMain_DeleteSlicesShortTx` — with 12,000 seeded events, the main-DB deletes run in ≥3 transactions (count via a seam or the lock-metrics sink in a temp dir).
- [ ] **Step 2: Tests** elsewhere: `TestScan_RefusesBeforeMove` (Scan returns `ErrNotMoved`, writes nothing, no `agent_log_files` row); `TestAgentsReport_BeforeMoveNeitherCopiesNorWrites` (cmd test: seeded main rows stay, agentlog has no marker, report JSON is valid with empty arrays); `TestSyncDaemon_MovesBeforeDaemonStarts` (the move runs before `daemon.New`; follow `cmd/automations_daemon_test.go:53-112`'s ordering test).
- [ ] **Step 3: Run** → FAIL. **Step 4: Implement** per spec D4 (copy reads in `BeginTx(ReadOnly)`, writes in 5,000-row transactions, marker with the last chunk; main deletes in 5,000-row transactions: events, sessions, files). **Step 5: Run** `go test ./internal/agentlogdb ./internal/agentlog ./internal/daemon` and `go test ./cmd -run 'Agents|SyncDaemon'` → PASS. **Step 6: Commit** `agentlog: move existing rows into agentlog.db once (#849)`.

### Task 4: Instant enable, daemon import, progress

**Depends on:** Task 3.

**Files:** `cmd/agents.go`, `internal/agentlog/scan.go`, `internal/agentlogdb/agent_log.go` (progress upsert/read), `internal/agentreport/build.go` + its `Overview` type, `internal/daemon/agent_analytics.go` (comment at :13-14 no longer true — fix it), tests incl. `cmd/agents_test.go` pinned keys, `internal/agentreport` fixtures.

**Interfaces:**
- Produces: `func (d *DB) SetImportProgress(projectID int64, complete bool, filesStored int, now time.Time) error`; `func (d *DB) ImportProgress(projectID int64) (*ImportProgress, error)` (nil when no row); `type ImportProgress struct{ Complete bool; FilesStored int; UpdatedAt string }`.
- Produces: `agentreport.Overview.Import ImportState` with JSON `import` = `{"state","files_stored","updated_at"}`; states `not_started` / `loading` / `done` per spec D6.
- `agents enable --json` prints `{"workbench_id": N, "enabled": true, "import": {…}}` and runs `runSyncNow(cfg)` ignoring its "no daemon" error.

- [ ] **Step 1: Tests:**
  - `TestAgentsEnable_ReturnsWithoutScanning` — after enable, `agent_log_files` is empty and the JSON has exactly `workbench_id`, `enabled`, `import`.
  - `TestAgentsEnable_NoDaemonStillSucceeds`.
  - `TestScan_ImportProgressLoadingThenDone` — `Budget` tiny → row `complete=0`; unbounded → `complete=1`, `files_stored` > 0.
  - `TestScan_ImportDoneWithFailingFile` — one unreadable owned transcript (chmod 000): `complete=1` after an unbounded scan, `FailedFiles=1`.
  - `TestScan_ImportDoneWithSiblingFolderFiles` — transcripts under `slug(/x/proj-tools)` next to workbench `/x/proj`: `complete=1`.
  - `TestBuildOverview_ImportState` — table test: no row → `not_started`; `complete=0` → `loading`; `complete=1` → `done`.
  - Amend `TestAgentsReportJSON_PinnedKeys` to include `import`; regenerate `TestDesktopReportFixtures` fixtures (`go test ./internal/agentreport -run TestDesktopReportFixtures -update`).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `go test ./internal/agentlog ./internal/agentlogdb ./internal/agentreport ./internal/daemon` and `go test ./cmd -run 'Agents'` → PASS. **Step 5: Commit** `agentlog: Turn On returns at once; the daemon imports and reports progress (#849)`.

### Task 5: Desktop loading line

**Depends on:** Task 4 (fixtures).

**Files:** `WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentReport.swift`, `WatchtowerDesktop/Sources/Views/Workbench/Analytics/AgentAnalyticsFormat.swift`, `AgentAnalyticsOverviewView.swift` (or `AgentAnalyticsPaneView.swift`, wherever the overview header lives), tests in `WatchtowerDesktop/Tests/Core`.

**Interfaces:** `struct AgentImportState: Decodable, Equatable { let state: String; let filesStored: Int; let updatedAt: String? }` on the overview model (`files_stored` / `updated_at` via the existing key-decoding convention); `static func importLine(_ s: AgentImportState) -> String?` in `AgentAnalyticsFormat` — `nil` for `done`, else `"Loading history — \(n) files so far"` (`n` formatted with the existing number formatter; `not_started` shows `0`).

- [ ] **Step 1: Tests** (`make test-swift FILTER='AgentReport|AgentAnalyticsFormat'`): the regenerated fixtures decode with `import`; `importLine` for `done` → nil, `loading` 2125 → `"Loading history — 2,125 files so far"`, `not_started` → `"Loading history — 0 files so far"`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement**; show the line above the overview while non-nil. **Step 4: Run** → PASS; `make lint-diff`. **Step 5: Commit** `Analytics pane: show history loading progress (#849)`.

### Task 6: Schema, guards, inventory, docs

**Depends on:** Task 3 (runs parallel to Tasks 4–5 only in its own worktree).

**Files:** `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), `internal/db/testdata/schema_v73.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`, `internal/db/workbenches_test.go` (`TestProj02_DeleteProjectLeavesNoRows`), `internal/db/schema_drift.go` (only if needed), `docs/inventory/agent-analytics.md`, `docs/inventory/workbench.md` (PROJ-02 exception text, guard description at :223), `docs/inventory/features.md:118` (FEAT-03), `docs/features/agent-analytics.md`, `CLAUDE.md` (feature line).

- [ ] **Step 1:** Remove the `agent_log_*` tables, indexes and view from `schema.sql` (keep `projects.agent_analytics`), drop them from `TestAllTablesExist`, regenerate: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- [ ] **Step 2:** Add `TestCheckSchemaDrift_ToleratesLeftoverAgentLogTables` — a db migrated through 00125 (tables present, empty) reports no drift and recreates nothing; and a db where the tables were dropped by hand reports no drift either.
- [ ] **Step 3:** `TestProj02_DeleteProjectLeavesNoRows`: remove the analytics seeding (`:247-248`) and the "analytics session survives…/events survive" assertions (`:319-324`) — owner-approved, ask #350. The name and every other assertion stay.
- [ ] **Step 4:** Inventory and docs per spec "Inventory and docs" (AGENTLOG-03 robustness note on the move; module line; changelog entry dated 2026-10-18 citing #849 and ask #350; PROJ-02 and FEAT-03 texts per the business spec; feature note sections; the v1 limit "deleting `agentlog.db` loses rows of deleted transcripts"; follow-up "drop the emptied `agent_log_*` tables from `watchtower.db` in a later release").
- [ ] **Step 5: Run** `go test ./internal/db` → PASS; `make test-swift FILTER=TestDatabase` builds. **Step 6: Commit** `agentlog: schema, guards and docs for agentlog.db (#849)`.

### After all tasks (controller)

- [ ] Full gate: `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`.
- [ ] Owner check on the live install (ask, kind check): upgrade → `agentlog.db` appears, Analytics shows the same sessions as before, `watchtower.db` analytics tables empty, `db lockstats` over the next hours has no analytics site.
- [ ] Follow-up target: drop the emptied `agent_log_*` tables from `watchtower.db` in a later release.
