# Agent analytics in `agentlog.db` — technical spec

Board #849 (group #527). Business spec: `2026-10-18-agentlog-db-business.md` (the owner reviews that one). Owner decision: ask #348. Background: `docs/features/agent-analytics.md`, inventory `docs/inventory/agent-analytics.md`. This spec covers decisions and contracts only.

## Why

The analytics import shared `watchtower.db`'s single write lock with every other writer and starved them (`db lockstats`: `cli:agents enable` held the lock 47 min in 24 h, p50 1 s, max 31 s per `ApplyAgentLogBatch`; 34 Desktop `BEGIN IMMEDIATE` failures, automation installs failing). Part of the hold was a bad plan (the replay check walked `idx_agent_log_events_kind`; fixed in PR #410, which this feature carries forward). The rest is structural: a bulk import must not share a lock with interactive writers.

## Goals

- G1. No analytics row in `watchtower.db`; analytics live in `<workspace>/agentlog.db`. The emptied `agent_log_*` tables are dropped in a later release (D4).
- G2. The import never takes `watchtower.db`'s write lock. The only `watchtower.db` access from analytics code is reads (workbenches, worktree ledger, terminal sessions, targets) and the one-time sliced row delete after the move.
- G3. Existing rows survive the upgrade (AGENTLOG-03), including rows whose transcript is gone.
- G4. `agents enable` returns at once; the daemon is the only routine importer; the report exposes import progress.
- G5. Report output, numbers, hints, timeline unchanged (pinned keys only gain `import`).

## Non-goals

Shrinking `watchtower.db` (#850). Codex ingest. Pacing between batches (the import no longer contends with interactive writers; revisit only if `agentlog.db` gets a second interactive writer). An index on `terminal_sessions(claude_session_id)` (the lookup moves out of any write transaction; the table is small).

## Decisions

### D1. The file and how it is opened

- Path: `filepath.Join(filepath.Dir(cfg.DBPath()), "agentlog.db")`, mode 0600 for the db, `-wal`, `-shm` (same as `tightenDBFilePerms`).
- Same connection discipline as `watchtower.db`: one connection, WAL, `synchronous=NORMAL`, `foreign_keys=1`, `busy_timeout=5000`, `_txlock=immediate`. **Not** routed through the lock-metrics driver (spec call): `dblock.jsonl` events carry no database field, so `agentlog.db` holds would be indistinguishable from `watchtower.db` ones in `db lockstats`. `db lockstats` stays the `watchtower.db` view; after this feature it must show no analytics site.
- Migrations: their own embedded set `internal/agentlogdb/migrations/*.sql`, run with goose's **Provider** API (`goose.NewProvider`, v3.27.1) so they never touch the global goose state that `watchtower.db` uses. Version table name `goose_db_version` inside `agentlog.db` (separate file, no clash). A `.migrate.lock` flock next to the file, same pattern and 2-minute wait as `setupSchema`.
- New package `internal/agentlogdb` owns the open, the schema and every query on these tables (moved from `internal/db/agent_log.go` and the `agent_log_*` parts of `internal/db/agent_report.go`). `internal/db` keeps the `watchtower.db` reads analytics needs (`AgentReportTargets`, `GetWorkbench`, `ListWorkbenches`, `WorkbenchSessionWorktrees`, the `projects.agent_analytics` accessors). Factor the shared pool/DSN/pragma helpers in `internal/db` into an exported opener the new package calls; no copy-paste of the DSN.

### D2. Schema of `agentlog.db` (migration `00001_init.sql`)

The final shape of today's tables (00116 + 00125: `spawned_agent_id`, `background`, the rebuilt `agent_log_session_totals` view), with these changes only:

- `agent_log_sessions.project_id INTEGER` — no `REFERENCES projects` (cross-file). `terminal_session_id INTEGER` — no `REFERENCES terminal_sessions`.
- Kept: `agent_log_events.session_uuid REFERENCES agent_log_sessions(session_uuid) ON DELETE CASCADE`, all indexes, the unique `key`.
- New table `agent_log_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)`; key `moved_from_main` = RFC 3339 UTC time of the completed move.
- New table `agent_log_import(project_id INTEGER PRIMARY KEY, complete INTEGER NOT NULL, files_stored INTEGER NOT NULL, updated_at TEXT NOT NULL)` — D6.

`projects.agent_analytics` stays in `watchtower.db` (it is a workbench setting).

### D3. Cross-file rules replacing the foreign keys

- `projects.id` is `INTEGER PRIMARY KEY AUTOINCREMENT` (00081): ids are never reused, so a deleted workbench's id simply stops being queried. No delete hook writes into `agentlog.db`.
- Adoption (`AdoptAgentLogSessions`, start of every scan): `UPDATE agent_log_sessions SET project_id = :wb WHERE folder_path = :folder COLLATE NOCASE AND (project_id IS NULL OR project_id NOT IN (:live ids))`, with the live workbench ids read from `watchtower.db` just before. This replaces "SET NULL then adopt where NULL"; the PROJ-02 behavior (rows outlive the workbench, a workbench later created on the same folder adopts them) is unchanged.
- `terminal_session_id`: resolved in Go. Before each slice's transaction the scanner reads `SELECT id FROM terminal_sessions WHERE claude_session_id = ? AND kind = 'claude' LIMIT 1` from `watchtower.db` for the slice's sessions and passes the value in `AgentLogSession`. The upsert keeps `COALESCE(stored, excluded)`. No code reads this column today; a stale id after a terminal session delete is accepted and documented.
- Reports keep filtering `project_id = ?`.

### D4. The one-time move (`agentlogdb.MoveFromMain`)

Idempotent; safe to interrupt at any point.

0. Take an exclusive flock on `agentlog.db.move.lock` (same `fsutil.LockFile` pattern, 2-minute wait); a second mover waits, then finds the marker and does only step 4.
1. Open `agentlog.db` (migrated). If `agent_log_meta.moved_from_main` is set → go to step 4.
2. If `watchtower.db` has no `agent_log_files` table → set the marker, done.
3. Copy `agent_log_files`, then `agent_log_sessions`, then `agent_log_events` (by `id`) with **reads** from `watchtower.db` (`BeginTx ReadOnly`) and writes into `agentlog.db` in transactions of 5,000 rows, `INSERT OR IGNORE` (an interrupted copy resumes by re-copying; keys are unique). Then set the marker in the same transaction as the last chunk.
4. If `watchtower.db`'s `agent_log_*` tables still hold rows: delete them in id slices of 5,000 rows, one short write transaction each (events, then sessions, then files). This is the only analytics write to `watchtower.db`. **The tables themselves stay, empty, in this release (spec call):** an older binary on the same data directory (a rollback, a stale CLI copy, a dev build from an older branch on the live install) still declares them in its `schema.sql`; with the tables dropped it would log a drift error on every open and its `agents` commands would fail with "no such table". Dropping them is a follow-up target for a later release.

Callers: the daemon, as a one-time upgrade step before `daemon.New` (the `runAutomationsUpgradeStep` pattern: every workspace with a database, fail closed, retry next start, logged), and the writing `agents` subcommands — `enable` and `scan` (so a CLI-only user moves too). `agents report` and `agents stats` never run the move (the Desktop calls `report` every 60 s; a report must not start a copy or write `watchtower.db`); before the move they answer from `agentlog.db` as it is. `phaseAgentAnalytics` and the `agents` commands refuse to scan until the marker is set (a scan into an empty `agent_log_files` would reparse every transcript from 0).

Fresh installs: 00116 still creates empty tables in `watchtower.db` (migration history is not edited); the move finds no rows and only sets the marker.

### D5. Turn On and the importer

- `agents enable` sets the column, runs the move if needed, nudges the daemon to start a sync cycle (reuse the mechanism behind `sync --now`; if the daemon is not running, nothing — it imports when it starts), and returns. `--json` prints `{"workbench_id": N, "enabled": true, "import": {…}}` (D6). The Desktop ignores enable's stdout today (`AgentAnalyticsCenter.enable`); it keeps reloading the overview afterwards.
- `phaseAgentAnalytics` is the routine importer. Budget per cycle: `agentAnalyticsBudget = 30s` today, split across enabled workbenches; with the daemon's default 15-min poll that is about 2 min of import per hour. **Plan task 1 measures** the full import's work on an owner-sized history with the #410 fix (parse + store time, one workbench, no budget) before the budget is chosen; the owner picks the budget from that number (business spec decision 1).
- `agents scan` stays as a manual, synchronous command (it now contends only with the daemon on `agentlog.db`; the offset CAS keeps it correct).
- FEAT-03 exception text changes accordingly (inventory amendment, owner-approved through the business spec).

### D6. Import progress

A file total is not knowable cheaply: `CandidateDirs` also lists sibling folders' transcripts (`<slug>-…`) and nested workbenches' files this workbench does not own, and ownership is decided per file only when the scan reaches it. So progress is "complete or not" plus a running count (spec call):

- Each scan of a workbench upserts, in its own short transaction at its end (also after a budget stop), `agent_log_import(project_id, complete, files_stored, updated_at)`: `complete = 1` when the scan finished its listing without a budget stop (`Result.Incomplete == false`), else 0; `files_stored` = the number of transcripts stored for the workbench (builder's choice how to count). A file that keeps failing (`FailedFiles`) does not keep `complete` at 0; it is retried every scan as today.
- `agents report --json` (overview) gains a pinned key `import`: `{"state": "not_started"|"loading"|"done", "files_stored": N, "updated_at": "..."}`. `not_started`: enabled, no row yet; `loading`: row with `complete = 0`; `done`: `complete = 1`. `TestAgentsReportJSON_PinnedKeys` is amended.
- Desktop: the Analytics pane shows "Loading history — N files so far" above the overview while `state != "done"`; the overview poll (60 s) refreshes it. Strings in English. Swift decodes the new key in `AgentReport.swift`; the Go fixture writer (`TestDesktopReportFixtures`) regenerates the JSON fixtures.

### D7. What moves out of `internal/db`

- `schema.sql`: remove the `agent_log_*` tables, indexes and view (keep `projects.agent_analytics`); the emptied tables stay in existing databases (D4), and drift checking must tolerate those extra objects. The AI prompt then no longer advertises analytics tables (acceptable: they are not in the database the prompt queries).
- `TestAllTablesExist`, the schema golden and the generated Swift test schema (`TestDesktopTestSchema`) are regenerated without them.
- `goMigrationTouches` keeps 125 (history). Verify `CheckSchemaDrift` neither recreates the dropped tables nor reports them; if it replays 00116/00125 for missing objects, exclude those objects explicitly and test it.
- `TestProj02_DeleteProjectLeavesNoRows` drops its analytics seeding and the "survives with project_id NULL" assertion (analytics rows are no longer written to `watchtower.db`); the survival-and-adoption guarantee moves to `TestAgentLog_SurvivesWorkbenchDeleteAndIsAdopted` in the new package (name kept). **Requires the owner's explicit approval** (an assertion leaves a PROJ-02 guard; asked with the business-spec review). Inventory PROJ-02 text is amended to say the analytics rows live in `agentlog.db`.

## Error handling

- `agentlog.db` cannot be opened or migrated: the daemon logs it and skips `phaseAgentAnalytics` for the cycle; `agents report` fails with the open error (the Desktop shows it as the pane's error line, existing behavior). Never fall back to `watchtower.db`.
- The move fails: logged; marker unset; retried next start; scans refuse until it succeeds (`agents report` still answers from whatever `agentlog.db` holds, with `import.state = "not_started"` if nothing).
- `agentlog.db` deleted by the owner: it is recreated empty; the next scans reimport what transcripts still exist. Rows of deleted transcripts are lost — stated in the feature note, not prevented.

## Tests that must exist

- Move: rows from a seeded `watchtower.db` (files, sessions, events incl. a session whose transcript is missing) appear in `agentlog.db` with equal counts and equal `agent_log_session_totals`; `watchtower.db`'s `agent_log_*` tables are empty afterwards and still exist.
- Two movers at once on one data dir: one copies, the other waits on the flock and then copies nothing; counts equal, no duplicates.
- `agents report` before the move neither copies nor writes `watchtower.db`.
- Move interrupted after the copy and before the row delete (simulate): the second run deletes without recopying and without duplicates. Interrupted mid-copy: second run completes, counts equal.
- Move on a fresh install (empty tables): marker set, nothing copied.
- Scan refuses before the marker; succeeds after.
- During a scan, `watchtower.db` sees no write transaction from analytics code (assert through the lock-metrics sink or a write-refusing handle: open `watchtower.db` read-only for the scan in the test).
- Adoption: workbench deleted then recreated on the same folder → rows adopted; rows of another folder untouched; a row whose project_id is a live workbench of the same folder is not stolen by another live workbench (two workbenches on one folder: longest-folder rule unchanged).
- `terminal_session_id` resolved from `watchtower.db` when a matching terminal session exists; NULL otherwise.
- `agents enable` returns without scanning (no `agent_log_files` rows written by it); `--json` shape.
- `import` progress: not_started → loading (budget stop mid-history) → done; a permanently failing file does not keep it at loading; files of a sibling folder (`/x/proj-tools` next to `/x/proj`) do not keep it at loading; pinned keys test amended.
- Carried from PR #410: `TestApplyAgentLogBatch_ReplayCheckSeeksKey` (plan seeks the unique key index), in the new package. The branch rebases on main once #410 merges; if it has not merged when implementation starts, cherry-pick its commit.
- All existing AGENTLOG-01..07 guard tests keep passing under their names, moved to the new package where they test the DB layer.
- Desktop: the pane shows the loading line for `loading`/`not_started` and hides it for `done` (WatchtowerCore test on the view model/formatter).

## Inventory and docs

- `docs/inventory/agent-analytics.md`: module line (new package, `agentlog.db`), AGENTLOG-03 robustness note (the move), changelog entry.
- `docs/inventory/workbench.md` PROJ-02 exception text; `docs/inventory/features.md` FEAT-03 exception text — both per the business spec, owner-approved there.
- `docs/features/agent-analytics.md`: tables section (file, opener, move), running-it section (enable, progress), v1 limits (deleting `agentlog.db` loses rows of deleted transcripts). `CLAUDE.md` feature line.
