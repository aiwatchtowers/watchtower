# Agent Analytics — Ingest Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse Claude Code session transcripts of a workbench folder into three SQLite tables (files, sessions, events) with correct token/cost accounting, behind `watchtower agents enable|disable|scan|stats` and an incremental daemon phase.

**Architecture:** A new pure package `internal/agentlog` (pricing, discovery, Claude JSONL parser, scanner) writes through a small DB layer in `internal/db/agent_log.go`. The CLI (`cmd/agents.go`) and the daemon phase (`phaseAgentAnalytics`) both call `agentlog.Scan`. No hooks, no Desktop code, no text stored.

**Tech Stack:** Go 1.26, `database/sql` + `modernc.org/sqlite`, goose migrations, cobra, testify.

**Spec:** `docs/superpowers/specs/2026-10-15-agent-analytics-core-design.md` (approved, ask #155). Board: #297 under #296.

## Global Constraints

- Store no transcript text: no prompt, reply, tool input/output, file content, or command argument beyond the documented `target` (AGENTLOG-01).
- One API call counts once: key `<message.id>:<requestId>` (`<message.id>:<session-uuid>` without `requestId`), later record wins on token columns; replay ownership = the session with the earliest `started_at`, tie → smaller uuid (AGENTLOG-02).
- Rows are never deleted: not on file removal, parser bump, or workbench delete (AGENTLOG-03, PROJ-02 exception ask #153).
- Only candidate directories are opened: `slug(F)` / `slug(F)+"-"` prefixes for the folder and its worktree roots; symlinks skipped via `Lstat` (AGENTLOG-04).
- Never write under `~/.claude` (AGENTLOG-05). `~/.claude` only — no `CLAUDE_CONFIG_DIR` (same rule as `defaultTerminalClaudeDir`, cmd/terminal.go:46).
- Prices: exact model id + explicit aliases, never prefix match; unknown model/speed → `cost_usd = 0`, `cost_estimated = 1`.
- Transactions: parse before opening the write tx (`BEGIN IMMEDIATE`, CLAUDE.md "Database & Migrations").
- Migration `00116_agent_analytics.sql`; mirror into `internal/db/schema.sql`, `TestAllTablesExist`, goldens (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`).
- Tests use synthetic JSONL only — no real ids, paths, names (public repo hygiene). Inner loop per task: `go test ./internal/<pkg>` + `make lint-diff`; no full suite per task.
- Docs and code comments in English.

## Review Focus

1. **A transcript line written half-way when the scan runs** — the partial line must not be consumed; the next scan reads it whole (Task 3 test `TestParseClaude_PartialLastLineNotConsumed`, Task 6 test `TestScan_PartialLineCompletedLater`).
2. **The same session reached through two workbenches (nested folders)** — counted once, in the longest folder; enabling the inner one later still reads the file from the start (Task 6 `TestScan_NestedWorkbenchesLongestWins`).
3. **Claude Code rewrites or truncates a transcript** (size below the stored offset) — reparse from 0 without duplicates (Task 6 `TestScan_ShrunkFileReparsedWithoutDuplicates`).
4. **CLI scan and daemon scan at the same time** — totals unchanged (Task 6 `TestScan_ConcurrentWritersCountOnce`).
5. **A transcript with an unknown model or fast speed without a known multiplier** — cost flagged estimated, never silently priced (Task 2 `TestCost_UnknownModelIsEstimated`, `TestCost_FastWithoutMultiplierIsEstimated`).

## File Structure

| File | Responsibility |
|------|----------------|
| `internal/db/migrations/00116_agent_analytics.sql` | tables, view, `projects.agent_analytics` |
| `internal/db/agent_log.go` | row types, `ApplyAgentLogBatch`, files, toggle, adopt, reprice, stats |
| `internal/agentlog/pricing.go` | versioned price table, `Cost` |
| `internal/agentlog/claude.go` | Claude JSONL → `ParseResult` (records, api calls, turns, compaction, errors, pr links) |
| `internal/agentlog/claude_tools.go` | tool_use/tool_result pairing, outcomes, targets, skills, lines |
| `internal/agentlog/discover.go` | slug, candidate dirs, worktree roots, file listing, home matching |
| `internal/agentlog/scan.go` | per-workbench incremental scan, ownership, CAS, missing files, reprice |
| `cmd/agents.go` | `agents enable|disable|scan|stats` |
| `internal/daemon/agent_analytics.go` | `phaseAgentAnalytics` |
| `docs/inventory/agent-analytics.md`, `docs/inventory/workbench.md`, `docs/inventory/features.md`, `docs/features/agent-analytics.md`, `CLAUDE.md` | contracts and notes |

Task dependencies (parallel lanes allowed where `none`): T1 none · T2 none · T3 T1 · T4 T3 · T5 none · T6 T1 T2 T4 T5 · T7 T6 · T8 T6 · T9 T7 T8.

---

### Task 1: Migration and DB layer

**Files:**
- Create: `internal/db/migrations/00116_agent_analytics.sql`
- Create: `internal/db/agent_log.go`
- Modify: `internal/db/schema.sql` (append the same DDL), `internal/db/db_test.go` (`TestAllTablesExist` list), goldens + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` via `-update`
- Modify: `internal/db/workbenches_test.go` (`TestProj02_DeleteProjectLeavesNoRows` — add the analytics assertion)
- Test: `internal/db/agent_log_test.go`

**Interfaces:**
- Produces (used by T3–T8):

```go
type AgentLogFile struct {
	Path, Agent   string
	Size          int64
	MTime         string
	ReadOffset    int64
	ParserVersion int
	MissingAt     string // "" = present
}
type AgentLogSession struct {
	SessionUUID, Agent, FolderPath, HomeCWD, SourcePath, GitBranch, Model, StartedAt, EndedAt string
	ProjectID       *int64
	ReportedCostUSD *float64
}
type AgentLogEvent struct {
	SessionUUID, Key, Kind, TS, UUID, ParentUUID, PromptID, AgentID string
	IsSidechain                                                     bool
	Name, Target, Trigger, Outcome, ErrorClass, Skill              string
	InputTokens, OutputTokens, CacheReadTokens, CacheWrite5mTokens, CacheWrite1hTokens int64
	Speed, ServiceTier string
	CostUSD            float64
	PriceVersion       int
	CostEstimated      bool
	LinesAdded, LinesRemoved int
	SrcPath   string
	SrcOffset int64
	MessageID     string // api_call only, not stored
	SubagentReplayCheck bool // skip when the session already has this message.id under another key
}
type AgentToolResult struct {
	ToolUseID, TS, Outcome, ErrorClass string
	LinesAdded, LinesRemoved           int
}
type AgentLogBatch struct {
	File          AgentLogFile // Path, Agent, Size, MTime, ParserVersion; ReadOffset = the new offset
	ExpectOffset  int64        // compare-and-set: the offset the caller read from; -1 = file row must not exist
	Sessions      []AgentLogSession
	Events        []AgentLogEvent
	ToolResults   []AgentToolResult
}
func (db *DB) GetAgentLogFile(path string) (*AgentLogFile, error) // nil, nil when absent
func (db *DB) AgentLogFilesUnder(dirs []string) ([]AgentLogFile, error)
func (db *DB) MarkAgentLogFileMissing(path, at string) error
func (db *DB) ApplyAgentLogBatch(b AgentLogBatch) (applied bool, err error)
func (db *DB) SetWorkbenchAgentAnalytics(id int64, on bool) error
func (db *DB) WorkbenchAgentAnalytics(id int64) (bool, error)
func (db *DB) AgentAnalyticsWorkbenchIDs() ([]int64, error)
func (db *DB) AdoptAgentLogSessions(projectID int64, folder string) (int64, error)
func (db *DB) AgentLogSessionFolder(sessionUUID string) (folder string, ok bool, err error)
func (db *DB) RepriceAgentLogEvents(version int, price func(model, speed string, in, out, cacheRead, cw5m, cw1h int64) (float64, bool)) (int, error)
func (db *DB) AgentLogStats(projectID int64) (*AgentLogStats, error)
```

- [ ] **Step 1: Write the migration**

```sql
-- +goose Up
ALTER TABLE projects ADD COLUMN agent_analytics INTEGER NOT NULL DEFAULT 0
  CHECK (agent_analytics IN (0, 1));

CREATE TABLE agent_log_files (
  path           TEXT PRIMARY KEY,
  agent          TEXT NOT NULL CHECK (agent IN ('claude')),
  size           INTEGER NOT NULL DEFAULT 0,
  mtime          TEXT NOT NULL DEFAULT '',
  read_offset    INTEGER NOT NULL DEFAULT 0,
  parser_version INTEGER NOT NULL DEFAULT 0,
  missing_at     TEXT,
  scanned_at     TEXT NOT NULL DEFAULT ''
);

CREATE TABLE agent_log_sessions (
  session_uuid        TEXT PRIMARY KEY,
  agent               TEXT NOT NULL CHECK (agent IN ('claude')),
  project_id          INTEGER REFERENCES projects(id) ON DELETE SET NULL,
  folder_path         TEXT NOT NULL,
  home_cwd            TEXT NOT NULL,
  terminal_session_id INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
  source_path         TEXT NOT NULL,
  git_branch          TEXT NOT NULL DEFAULT '',
  model               TEXT NOT NULL DEFAULT '',
  started_at          TEXT NOT NULL,
  ended_at            TEXT NOT NULL,
  reported_cost_usd   REAL
);
CREATE INDEX idx_agent_log_sessions_project ON agent_log_sessions(project_id, started_at);

CREATE TABLE agent_log_events (
  id             INTEGER PRIMARY KEY,
  session_uuid   TEXT NOT NULL REFERENCES agent_log_sessions(session_uuid) ON DELETE CASCADE,
  key            TEXT NOT NULL UNIQUE,
  kind           TEXT NOT NULL CHECK (kind IN
                   ('api_call','owner_turn','tool','skill','compaction','api_error','pr_link')),
  ts             TEXT NOT NULL,
  uuid           TEXT NOT NULL DEFAULT '',
  parent_uuid    TEXT NOT NULL DEFAULT '',
  prompt_id      TEXT NOT NULL DEFAULT '',
  agent_id       TEXT NOT NULL DEFAULT '',
  is_sidechain   INTEGER NOT NULL DEFAULT 0,
  name           TEXT NOT NULL DEFAULT '',
  target         TEXT NOT NULL DEFAULT '',
  trigger        TEXT NOT NULL DEFAULT '',
  outcome        TEXT NOT NULL DEFAULT '' CHECK (outcome IN
                   ('','ok','error','denied','interrupted','pending')),
  error_class    TEXT NOT NULL DEFAULT '',
  duration_ms    INTEGER,
  skill          TEXT NOT NULL DEFAULT '',
  input_tokens          INTEGER NOT NULL DEFAULT 0,
  output_tokens         INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
  cache_write_5m_tokens INTEGER NOT NULL DEFAULT 0,
  cache_write_1h_tokens INTEGER NOT NULL DEFAULT 0,
  speed          TEXT NOT NULL DEFAULT '',
  service_tier   TEXT NOT NULL DEFAULT '',
  cost_usd       REAL NOT NULL DEFAULT 0,
  price_version  INTEGER NOT NULL DEFAULT 0,
  cost_estimated INTEGER NOT NULL DEFAULT 0,
  lines_added    INTEGER NOT NULL DEFAULT 0,
  lines_removed  INTEGER NOT NULL DEFAULT 0,
  src_path       TEXT NOT NULL,
  src_offset     INTEGER NOT NULL
);
CREATE INDEX idx_agent_log_events_session ON agent_log_events(session_uuid, ts);
CREATE INDEX idx_agent_log_events_kind ON agent_log_events(kind, name);

CREATE VIEW agent_log_session_totals AS
SELECT session_uuid,
  SUM(CASE WHEN kind = 'api_call' THEN 1 ELSE 0 END)   AS api_calls,
  SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
  SUM(cache_read_tokens) AS cache_read_tokens,
  SUM(cache_write_5m_tokens) AS cache_write_5m_tokens,
  SUM(cache_write_1h_tokens) AS cache_write_1h_tokens,
  SUM(cost_usd) AS cost_usd,
  SUM(cost_estimated) AS cost_estimated_calls,
  SUM(CASE WHEN kind = 'owner_turn' THEN 1 ELSE 0 END) AS owner_turns,
  SUM(CASE WHEN kind = 'tool' THEN 1 ELSE 0 END)       AS tool_calls,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'error' THEN 1 ELSE 0 END)       AS tool_errors,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'denied' THEN 1 ELSE 0 END)      AS tool_denials,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'interrupted' THEN 1 ELSE 0 END) AS tool_interrupts,
  SUM(CASE WHEN kind = 'skill' THEN 1 ELSE 0 END)      AS skill_activations,
  SUM(CASE WHEN kind = 'compaction' THEN 1 ELSE 0 END) AS compactions,
  SUM(lines_added) AS lines_added, SUM(lines_removed) AS lines_removed
FROM agent_log_events GROUP BY session_uuid;

-- +goose Down
DROP VIEW agent_log_session_totals;
DROP TABLE agent_log_events;
DROP TABLE agent_log_sessions;
DROP TABLE agent_log_files;
ALTER TABLE projects DROP COLUMN agent_analytics;
```

Append the same DDL (without goose markers, `CREATE TABLE`/`VIEW` and the `projects` column added to its `CREATE TABLE projects` block) to `internal/db/schema.sql`; add `agent_log_files`, `agent_log_sessions`, `agent_log_events` to `expectedTables` in `TestAllTablesExist`; run `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.

- [ ] **Step 2: Write failing tests** in `internal/db/agent_log_test.go`

```go
package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func agentSession(uuid, started string, pid int64) AgentLogSession {
	return AgentLogSession{SessionUUID: uuid, Agent: "claude", ProjectID: &pid, FolderPath: "/w",
		HomeCWD: "/w", SourcePath: "/x/" + uuid + ".jsonl", StartedAt: started, EndedAt: started}
}

func apiCall(session, key string, out int64) AgentLogEvent {
	return AgentLogEvent{SessionUUID: session, Key: key, Kind: "api_call", TS: "2026-10-01T10:00:00Z",
		Name: "claude-opus-5-5", InputTokens: 10, OutputTokens: out, SrcPath: "/x/a.jsonl"}
}

func TestApplyAgentLogBatch_APICallCountsOnceLaterWins(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	b := AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 100}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)},
		Events:   []AgentLogEvent{apiCall("s1", "m1:r1", 5), apiCall("s1", "m1:r1", 40)}}
	ok, err := d.ApplyAgentLogBatch(b)
	require.NoError(t, err)
	require.True(t, ok)
	var n, out int64
	require.NoError(t, d.QueryRow(`SELECT COUNT(*), SUM(output_tokens) FROM agent_log_events`).Scan(&n, &out))
	assert.Equal(t, int64(1), n)
	assert.Equal(t, int64(40), out)
}

func TestApplyAgentLogBatch_CompareAndSetOffset(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	b := AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 100}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)}}
	ok, err := d.ApplyAgentLogBatch(b)
	require.NoError(t, err)
	require.True(t, ok)
	ok, err = d.ApplyAgentLogBatch(b) // stale: the row now exists at 100
	require.NoError(t, err)
	assert.False(t, ok)
	b.ExpectOffset, b.File.ReadOffset = 100, 250
	ok, err = d.ApplyAgentLogBatch(b)
	require.NoError(t, err)
	assert.True(t, ok)
	f, err := d.GetAgentLogFile("/x/a.jsonl")
	require.NoError(t, err)
	assert.Equal(t, int64(250), f.ReadOffset)
}

func TestApplyAgentLogBatch_ReplayOwnedByEarliestSession(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	// The fork (later session) is scanned first, then the original.
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/fork.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("fork", "2026-10-02T00:00:00Z", pid)},
		Events:   []AgentLogEvent{apiCall("fork", "m1:r1", 7)}})
	require.NoError(t, err)
	_, err = d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/orig.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("orig", "2026-10-01T00:00:00Z", pid)},
		Events:   []AgentLogEvent{apiCall("orig", "m1:r1", 7)}})
	require.NoError(t, err)
	var owner string
	require.NoError(t, d.QueryRow(`SELECT session_uuid FROM agent_log_events WHERE key='m1:r1'`).Scan(&owner))
	assert.Equal(t, "orig", owner)
}

func TestApplyAgentLogBatch_SubagentReplaySkipped(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/p.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("p", "2026-10-01T00:00:00Z", pid)},
		Events:   []AgentLogEvent{func() AgentLogEvent { e := apiCall("p", "m1:r1", 7); e.MessageID = "m1"; return e }()}})
	require.NoError(t, err)
	replay := apiCall("p", "m1:r2", 7)
	replay.MessageID, replay.SubagentReplayCheck = "m1", true
	_, err = d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/p/subagents/agent-a.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Events: []AgentLogEvent{replay}})
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE kind='api_call'`).Scan(&n))
	assert.Equal(t, 1, n)
}

func TestApplyAgentLogBatch_ToolResultPairsLater(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	use := AgentLogEvent{SessionUUID: "s1", Key: "tool:t1", Kind: "tool", TS: "2026-10-01T10:00:00Z", Name: "Bash", Target: "go test", Outcome: "pending", SrcPath: "/x/a.jsonl"}
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 10}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)}, Events: []AgentLogEvent{use}})
	require.NoError(t, err)
	_, err = d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 20}, ExpectOffset: 10,
		ToolResults: []AgentToolResult{{ToolUseID: "t1", TS: "2026-10-01T10:00:02Z", Outcome: "error", ErrorClass: "exit_code"}}})
	require.NoError(t, err)
	var outcome, class string
	var dur int64
	require.NoError(t, d.QueryRow(`SELECT outcome, error_class, duration_ms FROM agent_log_events WHERE key='tool:t1'`).Scan(&outcome, &class, &dur))
	assert.Equal(t, "error", outcome)
	assert.Equal(t, "exit_code", class)
	assert.Equal(t, int64(2000), dur)
}

func TestAgentLog_SurvivesWorkbenchDeleteAndIsAdopted(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T00:00:00Z", pid)}, Events: []AgentLogEvent{apiCall("s1", "m1:r1", 3)}})
	require.NoError(t, err)
	require.NoError(t, d.DeleteWorkbench(pid))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_log_sessions WHERE project_id IS NULL`).Scan(&n))
	assert.Equal(t, 1, n)
	pid2 := newTestWorkbench(t, d)
	adopted, err := d.AdoptAgentLogSessions(pid2, "/w")
	require.NoError(t, err)
	assert.Equal(t, int64(1), adopted)
}
```

Check `DeleteWorkbench`'s exact name/signature in `internal/db/workbenches.go` and the `newTestWorkbench` helper before running; adapt the call, not the assertion.

- [ ] **Step 3: Run tests to verify they fail**

Run: `go test ./internal/db -run 'TestApplyAgentLogBatch|TestAgentLog_' -v`
Expected: FAIL — `undefined: AgentLogBatch`.

- [ ] **Step 4: Implement `internal/db/agent_log.go`**

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// (types from the Interfaces block above go here, with doc comments)

const agentLogFileCols = `path, agent, size, mtime, read_offset, parser_version, COALESCE(missing_at, '')`

func scanAgentLogFile(row interface{ Scan(...any) error }) (*AgentLogFile, error) {
	var f AgentLogFile
	if err := row.Scan(&f.Path, &f.Agent, &f.Size, &f.MTime, &f.ReadOffset, &f.ParserVersion, &f.MissingAt); err != nil {
		return nil, err
	}
	return &f, nil
}

// GetAgentLogFile returns the stored scan state of path, or nil when the file
// was never scanned.
func (db *DB) GetAgentLogFile(path string) (*AgentLogFile, error) {
	f, err := scanAgentLogFile(db.QueryRow(`SELECT `+agentLogFileCols+` FROM agent_log_files WHERE path = ?`, path))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting agent log file: %w", err)
	}
	return f, nil
}

// AgentLogFilesUnder lists stored files whose path lies under one of dirs.
func (db *DB) AgentLogFilesUnder(dirs []string) ([]AgentLogFile, error) {
	var out []AgentLogFile
	for _, dir := range dirs {
		prefix := strings.TrimSuffix(dir, "/") + "/"
		rows, err := db.Query(`SELECT `+agentLogFileCols+` FROM agent_log_files WHERE path >= ? AND path < ?`, prefix, prefix+"￿")
		if err != nil {
			return nil, fmt.Errorf("listing agent log files: %w", err)
		}
		for rows.Next() {
			f, err := scanAgentLogFile(rows)
			if err != nil {
				rows.Close()
				return nil, err
			}
			out = append(out, *f)
		}
		if err := rows.Close(); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// MarkAgentLogFileMissing records that path is gone; its rows stay (AGENTLOG-03).
func (db *DB) MarkAgentLogFileMissing(path, at string) error {
	_, err := db.Exec(`UPDATE agent_log_files SET missing_at = ? WHERE path = ? AND missing_at IS NULL`, at, path)
	return err
}

// ApplyAgentLogBatch writes one parsed slice of a transcript in a single
// transaction and advances the file's offset with a compare-and-set. It
// returns applied=false (nothing written) when another writer moved the
// offset first.
func (db *DB) ApplyAgentLogBatch(b AgentLogBatch) (bool, error) {
	applied := false
	err := db.WithTx(func(tx *sql.Tx) error {
		var res sql.Result
		var err error
		if b.ExpectOffset < 0 {
			res, err = tx.Exec(`INSERT INTO agent_log_files (path, agent, size, mtime, read_offset, parser_version, scanned_at)
				VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now')) ON CONFLICT(path) DO NOTHING`,
				b.File.Path, b.File.Agent, b.File.Size, b.File.MTime, b.File.ReadOffset, b.File.ParserVersion)
		} else {
			res, err = tx.Exec(`UPDATE agent_log_files SET size = ?, mtime = ?, read_offset = ?, parser_version = ?,
				missing_at = NULL, scanned_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE path = ? AND read_offset = ?`,
				b.File.Size, b.File.MTime, b.File.ReadOffset, b.File.ParserVersion, b.File.Path, b.ExpectOffset)
		}
		if err != nil {
			return fmt.Errorf("advancing agent log file: %w", err)
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return errCASLost
		}
		for _, s := range b.Sessions {
			if err := upsertAgentLogSession(tx, s); err != nil {
				return err
			}
		}
		for _, e := range b.Events {
			if err := upsertAgentLogEvent(tx, e); err != nil {
				return err
			}
		}
		for _, r := range b.ToolResults {
			if _, err := tx.Exec(`UPDATE agent_log_events SET outcome = ?, error_class = ?,
				lines_added = ?, lines_removed = ?,
				duration_ms = CAST(ROUND((julianday(?) - julianday(ts)) * 86400000) AS INTEGER)
				WHERE key = ?`, r.Outcome, r.ErrorClass, r.LinesAdded, r.LinesRemoved, r.TS, "tool:"+r.ToolUseID); err != nil {
				return fmt.Errorf("pairing tool result: %w", err)
			}
		}
		applied = true
		return nil
	})
	if errors.Is(err, errCASLost) {
		return false, nil
	}
	return applied, err
}

var errCASLost = errors.New("agent log offset moved by another writer")

func upsertAgentLogSession(tx *sql.Tx, s AgentLogSession) error {
	_, err := tx.Exec(`INSERT INTO agent_log_sessions (session_uuid, agent, project_id, folder_path, home_cwd,
		terminal_session_id, source_path, git_branch, model, started_at, ended_at, reported_cost_usd)
		VALUES (?, ?, ?, ?, ?, (SELECT id FROM terminal_sessions WHERE claude_session_id = ? AND kind = 'claude' LIMIT 1),
		        ?, ?, ?, ?, ?, ?)
		ON CONFLICT(session_uuid) DO UPDATE SET
		  model = CASE WHEN excluded.model <> '' AND excluded.ended_at >= agent_log_sessions.ended_at
		               THEN excluded.model ELSE agent_log_sessions.model END,
		  started_at = MIN(agent_log_sessions.started_at, excluded.started_at),
		  ended_at = MAX(agent_log_sessions.ended_at, excluded.ended_at),
		  git_branch = CASE WHEN agent_log_sessions.git_branch = '' THEN excluded.git_branch ELSE agent_log_sessions.git_branch END,
		  project_id = COALESCE(agent_log_sessions.project_id, excluded.project_id),
		  terminal_session_id = COALESCE(agent_log_sessions.terminal_session_id, excluded.terminal_session_id),
		  reported_cost_usd = COALESCE(excluded.reported_cost_usd, agent_log_sessions.reported_cost_usd)`,
		s.SessionUUID, s.Agent, s.ProjectID, s.FolderPath, s.HomeCWD, s.SessionUUID,
		s.SourcePath, s.GitBranch, s.Model, s.StartedAt, s.EndedAt, s.ReportedCostUSD)
	if err != nil {
		return fmt.Errorf("upserting agent log session: %w", err)
	}
	return nil
}

func upsertAgentLogEvent(tx *sql.Tx, e AgentLogEvent) error {
	if e.SubagentReplayCheck && e.MessageID != "" {
		var n int
		prefix := e.MessageID + ":"
		if err := tx.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE session_uuid = ? AND kind = 'api_call'
			AND key >= ? AND key < ? AND key <> ?`, e.SessionUUID, prefix, prefix+"￿", e.Key).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			return nil
		}
	}
	// Ownership: the earliest session (tie → smaller uuid) keeps a replayed key.
	_, err := tx.Exec(`INSERT INTO agent_log_events (session_uuid, key, kind, ts, uuid, parent_uuid, prompt_id, agent_id,
		is_sidechain, name, target, trigger, outcome, error_class, skill, input_tokens, output_tokens, cache_read_tokens,
		cache_write_5m_tokens, cache_write_1h_tokens, speed, service_tier, cost_usd, price_version, cost_estimated,
		lines_added, lines_removed, src_path, src_offset)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(key) DO UPDATE SET
		  session_uuid = CASE WHEN (SELECT started_at FROM agent_log_sessions WHERE session_uuid = excluded.session_uuid)
		                           < (SELECT started_at FROM agent_log_sessions WHERE session_uuid = agent_log_events.session_uuid)
		                      OR ((SELECT started_at FROM agent_log_sessions WHERE session_uuid = excluded.session_uuid)
		                           = (SELECT started_at FROM agent_log_sessions WHERE session_uuid = agent_log_events.session_uuid)
		                          AND excluded.session_uuid < agent_log_events.session_uuid)
		                 THEN excluded.session_uuid ELSE agent_log_events.session_uuid END,
		  input_tokens = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.input_tokens ELSE agent_log_events.input_tokens END,
		  cache_read_tokens = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.cache_read_tokens ELSE agent_log_events.cache_read_tokens END,
		  cache_write_5m_tokens = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.cache_write_5m_tokens ELSE agent_log_events.cache_write_5m_tokens END,
		  cache_write_1h_tokens = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.cache_write_1h_tokens ELSE agent_log_events.cache_write_1h_tokens END,
		  cost_usd = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.cost_usd ELSE agent_log_events.cost_usd END,
		  output_tokens = MAX(agent_log_events.output_tokens, excluded.output_tokens),
		  outcome = CASE WHEN agent_log_events.outcome IN ('', 'pending') THEN excluded.outcome ELSE agent_log_events.outcome END`,
		e.SessionUUID, e.Key, e.Kind, e.TS, e.UUID, e.ParentUUID, e.PromptID, e.AgentID, e.IsSidechain,
		e.Name, e.Target, e.Trigger, e.Outcome, e.ErrorClass, e.Skill, e.InputTokens, e.OutputTokens, e.CacheReadTokens,
		e.CacheWrite5mTokens, e.CacheWrite1hTokens, e.Speed, e.ServiceTier, e.CostUSD, e.PriceVersion, e.CostEstimated,
		e.LinesAdded, e.LinesRemoved, e.SrcPath, e.SrcOffset)
	if err != nil {
		return fmt.Errorf("upserting agent log event: %w", err)
	}
	return nil
}

// SetWorkbenchAgentAnalytics turns analytics on or off for a workbench.
func (db *DB) SetWorkbenchAgentAnalytics(id int64, on bool) error {
	res, err := db.Exec(`UPDATE projects SET agent_analytics = ? WHERE id = ?`, on, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound)
	}
	return nil
}

func (db *DB) WorkbenchAgentAnalytics(id int64) (bool, error) {
	var on bool
	err := db.QueryRow(`SELECT agent_analytics FROM projects WHERE id = ?`, id).Scan(&on)
	if errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound)
	}
	return on, err
}

func (db *DB) AgentAnalyticsWorkbenchIDs() ([]int64, error) {
	rows, err := db.Query(`SELECT id FROM projects WHERE agent_analytics = 1 ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// AdoptAgentLogSessions links orphaned sessions (their workbench was
// deleted, PROJ-02 exception) to a workbench bound to the same folder.
func (db *DB) AdoptAgentLogSessions(projectID int64, folder string) (int64, error) {
	res, err := db.Exec(`UPDATE agent_log_sessions SET project_id = ? WHERE project_id IS NULL AND folder_path = ? COLLATE NOCASE`, projectID, folder)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// AgentLogSessionFolder returns the folder a stored session was matched to.
func (db *DB) AgentLogSessionFolder(sessionUUID string) (string, bool, error) {
	var folder string
	err := db.QueryRow(`SELECT folder_path FROM agent_log_sessions WHERE session_uuid = ?`, sessionUUID).Scan(&folder)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return folder, err == nil, err
}

// RepriceAgentLogEvents recomputes cost for api_call rows priced with an
// older table version, from their stored tokens.
func (db *DB) RepriceAgentLogEvents(version int, price func(model, speed string, in, out, cacheRead, cw5m, cw1h int64) (float64, bool)) (int, error) {
	type row struct {
		id                         int64
		model, speed               string
		in, out, cr, cw5, cw1h     int64
	}
	rows, err := db.Query(`SELECT id, name, speed, input_tokens, output_tokens, cache_read_tokens, cache_write_5m_tokens,
		cache_write_1h_tokens FROM agent_log_events WHERE kind = 'api_call' AND price_version < ?`, version)
	if err != nil {
		return 0, err
	}
	var todo []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.id, &r.model, &r.speed, &r.in, &r.out, &r.cr, &r.cw5, &r.cw1h); err != nil {
			rows.Close()
			return 0, err
		}
		todo = append(todo, r)
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}
	err = db.WithTx(func(tx *sql.Tx) error {
		for _, r := range todo {
			usd, known := price(r.model, r.speed, r.in, r.out, r.cr, r.cw5, r.cw1h)
			if _, err := tx.Exec(`UPDATE agent_log_events SET cost_usd = ?, cost_estimated = ?, price_version = ? WHERE id = ?`,
				usd, !known, version, r.id); err != nil {
				return err
			}
		}
		return nil
	})
	return len(todo), err
}
```

`AgentLogStats` (pinned shape used by T7):

```go
type AgentLogStats struct {
	Sessions           int               `json:"sessions"`
	Tokens             AgentLogTokens    `json:"tokens"`
	CostUSD            float64           `json:"cost_usd"`
	CostEstimatedCalls int               `json:"cost_estimated_calls"`
	ReportedCostUSD    float64           `json:"reported_cost_usd"`
	OwnerTurns         int               `json:"owner_turns"`
	Tools              []AgentLogCount   `json:"tools"`
	Outcomes           map[string]int    `json:"outcomes"`
	Skills             []AgentLogSkill   `json:"skills"`
	PerSession         []AgentLogSessionStat `json:"per_session"`
}
type AgentLogTokens struct {
	Input        int64 `json:"input"`
	Output       int64 `json:"output"`
	CacheRead    int64 `json:"cache_read"`
	CacheWrite5m int64 `json:"cache_write_5m"`
	CacheWrite1h int64 `json:"cache_write_1h"`
}
type AgentLogCount struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}
type AgentLogSkill struct {
	Name      string `json:"name"`
	Proactive int    `json:"proactive"`
	Slash     int    `json:"slash"`
	Read      int    `json:"read"`
}
type AgentLogSessionStat struct {
	SessionUUID     string   `json:"session_uuid"`
	StartedAt       string   `json:"started_at"`
	EndedAt         string   `json:"ended_at"`
	Model           string   `json:"model"`
	APICalls        int      `json:"api_calls"`
	CostUSD         float64  `json:"cost_usd"`
	ReportedCostUSD *float64 `json:"reported_cost_usd"`
	ToolErrors      int      `json:"tool_errors"`
}
```

Implement `AgentLogStats(projectID)` with four queries joined on `agent_log_sessions.project_id = ?`: totals from `agent_log_session_totals` (SUM over sessions), `SUM(reported_cost_usd)`, tools `GROUP BY name ORDER BY COUNT(*) DESC LIMIT 20` where `kind='tool'`, outcomes `GROUP BY outcome` where `kind='tool'`, skills grouped by `name` with `SUM(trigger='proactive')` etc., per-session rows from the view ordered by `started_at DESC LIMIT 50`. Non-nil empty slices/map so JSON prints `[]`/`{}`.

- [ ] **Step 5: Extend the PROJ-02 guard.** In `TestProj02_DeleteProjectLeavesNoRows`, before the delete, apply one batch for `pid` (session + one event); after the delete assert the session row still exists with `project_id IS NULL` and its event count is 1 — comment: `// PROJ-02 exception (ask #153): agent analytics outlive the workbench.` Add an assertion, relax none.

- [ ] **Step 6: Run tests**

Run: `go test ./internal/db -run 'TestApplyAgentLogBatch|TestAgentLog_|TestProj02|TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema' -v`
Expected: PASS. Then `make lint-diff`.

- [ ] **Step 7: Commit**

```bash
git add internal/db WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift
git commit -m "feat(agentlog): migration 00116 and DB layer for agent analytics"
```

---

### Task 2: Price table

**Files:**
- Create: `internal/agentlog/pricing.go`
- Test: `internal/agentlog/pricing_test.go`

**Interfaces:**
- Produces: `const PriceVersion = 1`; `func Cost(model, speed string, in, out, cacheRead, cw5m, cw1h int64) (usd float64, known bool)` — signature matches `db.RepriceAgentLogEvents`'s `price` argument.

- [ ] **Step 1: Write failing tests**

```go
package agentlog

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestCost_Opus55WithCacheTiers(t *testing.T) {
	// 1M input @4, 1M output @20, 1M cache read @0.20, 1M 5m write @5 (1.25x), 1M 1h write @8 (2x)
	usd, known := Cost("claude-opus-5-5", "standard", 1e6, 1e6, 1e6, 1e6, 1e6)
	assert.True(t, known)
	assert.InDelta(t, 4+20+0.20+5+8, usd, 1e-9)
}

func TestCost_Fable51CacheReadIsNotTenthOfInput(t *testing.T) {
	usd, _ := Cost("claude-fable-5-1", "", 0, 0, 1e6, 0, 0)
	assert.InDelta(t, 0.25, usd, 1e-9)
}

func TestCost_FastModeMultiplier(t *testing.T) {
	usd, known := Cost("claude-opus-5-5", "fast", 1e6, 1e6, 0, 0, 0)
	assert.True(t, known)
	assert.InDelta(t, 8+40, usd, 1e-9)
}

func TestCost_FastWithoutMultiplierIsEstimated(t *testing.T) {
	_, known := Cost("claude-opus-4-8", "fast", 1, 1, 0, 0, 0)
	assert.False(t, known)
}

func TestCost_UnknownModelIsEstimated(t *testing.T) {
	usd, known := Cost("claude-opus-9", "standard", 1e6, 0, 0, 0, 0)
	assert.False(t, known)
	assert.Zero(t, usd)
	_, known = Cost("claude-opus-5-5-preview", "", 1, 0, 0, 0, 0) // no prefix match
	assert.False(t, known)
}

func TestCost_AliasAndLongInputTier(t *testing.T) {
	_, known := Cost("claude-haiku-4-5-20251001", "", 1, 0, 0, 0, 0)
	assert.True(t, known)
	// Haiku 5.5 above 100K input: $0.50 / $2.50
	usd, _ := Cost("claude-haiku-5-5", "", 200_000, 1e6, 0, 0, 0)
	assert.InDelta(t, 0.2*0.50+2.50, usd, 1e-9)
}
```

- [ ] **Step 2: Run** `go test ./internal/agentlog -run TestCost -v` → FAIL (`undefined: Cost`).

- [ ] **Step 3: Implement**

```go
// Package agentlog turns coding-agent session transcripts into the
// normalized analytics rows of agent_log_* (spec
// docs/superpowers/specs/2026-10-15-agent-analytics-core-design.md).
package agentlog

// PriceVersion is stamped on every priced row; bump it with any change to
// prices so the next scan reprices stored rows (no reparse).
const PriceVersion = 1

type price struct {
	input, output, cacheRead float64 // $ per million tokens
	longOver                 int64   // input tokens (incl. cache) above which the long tier applies; 0 = none
	longInput, longOutput    float64
	fast                     float64 // fast-speed multiplier; 0 = unknown
}

// Anthropic first-party rates, checked against the pricing page on
// 2026-10-15. Cache writes: 5m = 1.25x input, 1h = 2x input.
var prices = map[string]price{
	"claude-fable-5-1":  {input: 10, output: 50, cacheRead: 0.25},
	"claude-fable-5":    {input: 10, output: 50, cacheRead: 1.00},
	"claude-opus-5-5":   {input: 4, output: 20, cacheRead: 0.20, fast: 2},
	"claude-opus-5":     {input: 5, output: 25, cacheRead: 0.50, fast: 2},
	"claude-opus-4-8":   {input: 5, output: 25, cacheRead: 0.50},
	"claude-opus-4-7":   {input: 5, output: 25, cacheRead: 0.50},
	"claude-opus-4-6":   {input: 5, output: 25, cacheRead: 0.50},
	"claude-sonnet-5-5": {input: 2, output: 10, cacheRead: 0.20},
	"claude-sonnet-5":   {input: 2, output: 10, cacheRead: 0.20},
	"claude-sonnet-4-6": {input: 3, output: 15, cacheRead: 0.30},
	"claude-haiku-5-5":  {input: 0.10, output: 0.50, cacheRead: 0.01, longOver: 100_000, longInput: 0.50, longOutput: 2.50},
	"claude-haiku-4-5":  {input: 1, output: 5, cacheRead: 0.10},
}

var aliases = map[string]string{
	"claude-haiku-4-5-20251001": "claude-haiku-4-5",
}

// Cost prices one API call. known=false (cost 0) when the model, or its fast
// multiplier, is not in the table — never guessed.
func Cost(model, speed string, in, out, cacheRead, cw5m, cw1h int64) (float64, bool) {
	if a, ok := aliases[model]; ok {
		model = a
	}
	p, ok := prices[model]
	if !ok {
		return 0, false
	}
	inRate, outRate, readRate := p.input, p.output, p.cacheRead
	if p.longOver > 0 && in+cacheRead+cw5m+cw1h > p.longOver {
		scale := p.longInput / p.input
		inRate, outRate, readRate = p.longInput, p.longOutput, p.cacheRead*scale
	}
	usd := (float64(in)*inRate + float64(out)*outRate + float64(cacheRead)*readRate +
		float64(cw5m)*inRate*1.25 + float64(cw1h)*inRate*2) / 1e6
	if speed == "fast" {
		if p.fast == 0 {
			return 0, false
		}
		usd *= p.fast
	}
	return usd, true
}
```

Before committing, re-check every row against the current Anthropic pricing page (the `claude-api` skill's model table, `shared/live-sources.md` Pricing row); fix numbers in both the table and the tests if the page differs, and keep the "checked on" date honest.

- [ ] **Step 4: Run** `go test ./internal/agentlog -run TestCost -v` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `git add internal/agentlog/pricing*.go && git commit -m "feat(agentlog): versioned price table"`

---

### Task 3: Claude parser — records, API calls, turns

**Files:**
- Create: `internal/agentlog/claude.go`
- Test: `internal/agentlog/claude_test.go`

**Interfaces:**
- Consumes: `db.AgentLogEvent`, `db.AgentLogSession`, `db.AgentToolResult` (T1); `Cost`, `PriceVersion` (T2).
- Produces:

```go
const ParserVersion = 1
const maxLineBytes = 8 << 20
type ParseOptions struct {
	Path     string // transcript path, stored as src_path
	Folder   string // workbench folder for relative targets
	Subagent bool   // file is <sid>/subagents/agent-*.jsonl
	AgentID  string // subagent id from the file name ("" for main files)
}
type ParseResult struct {
	Sessions    map[string]*db.AgentLogSession // by session uuid; HomeCWD = first cwd seen
	Events      []db.AgentLogEvent
	ToolResults []db.AgentToolResult
	Unknown     map[string]int // record type → count
	LongLines   int
	Consumed    int64 // bytes of complete lines read
}
func ParseClaude(r io.Reader, startOffset int64, o ParseOptions) (*ParseResult, error)
```

- [ ] **Step 1: Write failing tests** (helpers build synthetic lines)

```go
package agentlog

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func line(t *testing.T, m map[string]any) string {
	t.Helper()
	b, err := json.Marshal(m)
	require.NoError(t, err)
	return string(b) + "\n"
}

func assistant(sid, uuid, msgID, req string, out int64, content ...map[string]any) map[string]any {
	if content == nil {
		content = []map[string]any{{"type": "text", "text": "SENTINEL-REPLY"}}
	}
	return map[string]any{"type": "assistant", "sessionId": sid, "uuid": uuid, "parentUuid": "p-" + uuid,
		"timestamp": "2026-10-01T10:00:00.000Z", "cwd": "/w/app", "gitBranch": "main", "requestId": req,
		"message": map[string]any{"id": msgID, "model": "claude-opus-5-5", "role": "assistant", "content": content,
			"usage": map[string]any{"input_tokens": 10, "output_tokens": out, "cache_read_input_tokens": 100,
				"cache_creation_input_tokens": 50, "speed": "standard", "service_tier": "standard",
				"cache_creation": map[string]any{"ephemeral_5m_input_tokens": 20, "ephemeral_1h_input_tokens": 30}}}}
}

func parse(t *testing.T, s string, o ParseOptions) *ParseResult {
	t.Helper()
	if o.Path == "" {
		o.Path = "/h/.claude/projects/-w/s1.jsonl"
	}
	if o.Folder == "" {
		o.Folder = "/w"
	}
	r, err := ParseClaude(strings.NewReader(s), 0, o)
	require.NoError(t, err)
	return r
}

func TestParseClaude_StreamingChunksFoldIntoOneCall(t *testing.T) {
	s := line(t, assistant("s1", "u1", "m1", "r1", 5)) + line(t, assistant("s1", "u2", "m1", "r1", 42))
	r := parse(t, s, ParseOptions{})
	var calls []string
	for _, e := range r.Events {
		if e.Kind == "api_call" {
			calls = append(calls, e.Key)
			assert.Equal(t, int64(42), e.OutputTokens)
			assert.Equal(t, int64(20), e.CacheWrite5mTokens)
			assert.Equal(t, int64(30), e.CacheWrite1hTokens)
			assert.Equal(t, PriceVersion, e.PriceVersion)
			assert.False(t, e.CostEstimated)
		}
	}
	assert.Equal(t, []string{"m1:r1"}, calls)
}

func TestParseClaude_SessionMetaHomeIsFirstCWD(t *testing.T) {
	a := assistant("s1", "u1", "m1", "r1", 5)
	b := assistant("s1", "u2", "m2", "r2", 5)
	b["cwd"], b["timestamp"] = "/elsewhere", "2026-10-01T11:00:00.000Z"
	r := parse(t, line(t, a)+line(t, b), ParseOptions{})
	s := r.Sessions["s1"]
	require.NotNil(t, s)
	assert.Equal(t, "/w/app", s.HomeCWD)
	assert.Equal(t, "main", s.GitBranch)
	assert.Equal(t, "2026-10-01T10:00:00.000Z", s.StartedAt)
	assert.Equal(t, "2026-10-01T11:00:00.000Z", s.EndedAt)
}

func TestParseClaude_PartialLastLineNotConsumed(t *testing.T) {
	full := line(t, assistant("s1", "u1", "m1", "r1", 5))
	half := `{"type":"assistant","sessionId":"s1"`
	r := parse(t, full+half, ParseOptions{})
	assert.Equal(t, int64(len(full)), r.Consumed)
	assert.Len(t, r.Events, 1)
}

func TestParseClaude_UnknownTypesCountedSyntheticSkipped(t *testing.T) {
	syn := assistant("s1", "u9", "m9", "r9", 5)
	syn["message"].(map[string]any)["model"] = "<synthetic>"
	s := line(t, map[string]any{"type": "brand-new-record", "sessionId": "s1"}) + line(t, syn) + "not json\n"
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, 1, r.Unknown["brand-new-record"])
	assert.Equal(t, 1, r.Unknown["<invalid>"])
	assert.Empty(t, r.Events)
}

func TestParseClaude_OwnerTurnCompactionAPIErrorPRLinkCost(t *testing.T) {
	s := line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "timestamp": "2026-10-01T09:59:00Z", "cwd": "/w",
		"promptId": "pr1", "message": map[string]any{"role": "user", "content": "SENTINEL-PROMPT"}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o2", "isMeta": true, "timestamp": "2026-10-01T09:59:01Z",
			"message": map[string]any{"role": "user", "content": "meta"}}) +
		line(t, map[string]any{"type": "system", "subtype": "compact_boundary", "sessionId": "s1", "uuid": "c1", "timestamp": "2026-10-01T10:01:00Z"}) +
		line(t, map[string]any{"type": "assistant", "isApiErrorMessage": true, "sessionId": "s1", "uuid": "e1", "timestamp": "2026-10-01T10:02:00Z",
			"message": map[string]any{"model": "<synthetic>", "content": []any{}}}) +
		line(t, map[string]any{"type": "pr-link", "sessionId": "s1", "prUrl": "https://example.com/acme/app/pull/7", "prNumber": 7, "timestamp": "2026-10-01T10:03:00Z"}) +
		line(t, map[string]any{"type": "cost-state", "sessionId": "s1", "totalCostUSD": 1.5})
	r := parse(t, s, ParseOptions{})
	kinds := map[string]int{}
	for _, e := range r.Events {
		kinds[e.Kind]++
		if e.Kind == "owner_turn" {
			assert.Equal(t, "pr1", e.PromptID)
		}
		if e.Kind == "pr_link" {
			assert.Equal(t, "https://example.com/acme/app/pull/7", e.Target)
		}
	}
	assert.Equal(t, map[string]int{"owner_turn": 1, "compaction": 1, "api_error": 1, "pr_link": 1}, kinds)
	require.NotNil(t, r.Sessions["s1"].ReportedCostUSD)
	assert.InDelta(t, 1.5, *r.Sessions["s1"].ReportedCostUSD, 1e-9)
}

func TestParseClaude_StoresNoText(t *testing.T) {
	s := line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "timestamp": "2026-10-01T09:59:00Z", "cwd": "/w",
		"message": map[string]any{"role": "user", "content": "SENTINEL-PROMPT"}}) + line(t, assistant("s1", "u1", "m1", "r1", 5))
	r := parse(t, s, ParseOptions{})
	b, err := json.Marshal(r)
	require.NoError(t, err)
	assert.NotContains(t, string(b), "SENTINEL")
}
```

- [ ] **Step 2: Run** `go test ./internal/agentlog -run TestParseClaude -v` → FAIL.

- [ ] **Step 3: Implement `claude.go`**

```go
package agentlog

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"watchtower/internal/db"
)

// ParserVersion is stamped on agent_log_files; bump it when parsing changes
// so present files are reparsed from 0 (idempotent keys, AGENTLOG-03).
const ParserVersion = 1

const maxLineBytes = 8 << 20

// claudeRecord is the subset of a Claude Code transcript line the core
// reads. Every field is optional; unknown fields are ignored.
type claudeRecord struct {
	Type              string          `json:"type"`
	Subtype           string          `json:"subtype"`
	SessionID         string          `json:"sessionId"`
	UUID              string          `json:"uuid"`
	ParentUUID        string          `json:"parentUuid"`
	PromptID          string          `json:"promptId"`
	Timestamp         string          `json:"timestamp"`
	CWD               string          `json:"cwd"`
	GitBranch         string          `json:"gitBranch"`
	RequestID         string          `json:"requestId"`
	IsMeta            bool            `json:"isMeta"`
	IsSidechain       bool            `json:"isSidechain"`
	IsAPIError        bool            `json:"isApiErrorMessage"`
	IsCompactSummary  bool            `json:"isCompactSummary"`
	AttributionSkill  string          `json:"attributionSkill"`
	ToolDenialKind    string          `json:"toolDenialKind"`
	ToolUseResult     json.RawMessage `json:"toolUseResult"`
	PRURL             string          `json:"prUrl"`
	TotalCostUSD      *float64        `json:"totalCostUSD"`
	Attachment        json.RawMessage `json:"attachment"`
	Message           claudeMessage   `json:"message"`
}

type claudeMessage struct {
	ID      string          `json:"id"`
	Model   string          `json:"model"`
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
	Usage   *claudeUsage    `json:"usage"`
}

type claudeUsage struct {
	Input         int64  `json:"input_tokens"`
	Output        int64  `json:"output_tokens"`
	CacheRead     int64  `json:"cache_read_input_tokens"`
	CacheCreation int64  `json:"cache_creation_input_tokens"`
	Speed         string `json:"speed"`
	ServiceTier   string `json:"service_tier"`
	CacheBreakdown *struct {
		FiveMin int64 `json:"ephemeral_5m_input_tokens"`
		OneHour int64 `json:"ephemeral_1h_input_tokens"`
	} `json:"cache_creation"`
}

type ParseOptions struct {
	Path     string
	Folder   string
	Subagent bool
	AgentID  string
}

type ParseResult struct {
	Sessions    map[string]*db.AgentLogSession
	Events      []db.AgentLogEvent
	ToolResults []db.AgentToolResult
	Unknown     map[string]int
	LongLines   int
	Consumed    int64
}

// knownTypes are record types the core reads or deliberately ignores; any
// other type is counted in Unknown so format drift shows in `agents scan`.
var knownTypes = map[string]bool{
	"assistant": true, "user": true, "system": true, "attachment": true, "pr-link": true, "cost-state": true,
	"summary": true, "queue-operation": true, "last-prompt": true, "mode": true, "permission-mode": true,
	"ai-title": true, "file-history-snapshot": true, "file-history-delta": true, "api-request": true,
	"api-request-blob": true, "api-request-shape": true, "atis-latch": true, "bridge-session": true,
	"frame-link": true, "relocated": true, "worktree-state": true,
}

// ParseClaude reads complete lines from r (positioned at startOffset) and
// returns the rows they produce. A final line without '\n' is left for the
// next scan; a bad line never fails the file.
func ParseClaude(r io.Reader, startOffset int64, o ParseOptions) (*ParseResult, error) {
	p := &claudeParser{o: o, res: &ParseResult{Sessions: map[string]*db.AgentLogSession{}, Unknown: map[string]int{}},
		callIdx: map[string]int{}, toolIdx: map[string]int{}}
	br := bufio.NewReaderSize(r, 64<<10)
	off := startOffset
	for {
		raw, n, complete, err := nextLine(br, maxLineBytes)
		if !complete {
			break // EOF mid-line, or plain EOF: the rest waits for the next scan
		}
		lineOff := off
		off += n
		p.res.Consumed += n
		if raw == nil {
			p.res.LongLines++
		} else {
			p.handle(raw, lineOff)
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("reading %s: %w", o.Path, err)
		}
	}
	return p.res, nil
}

// nextLine returns one '\n'-terminated line without the newline, the bytes
// consumed, and complete=false when the input ended before a newline. A line
// longer than limit comes back as nil (consumed and complete).
func nextLine(br *bufio.Reader, limit int) ([]byte, int64, bool, error) {
	var buf []byte
	var n int64
	tooLong := false
	for {
		chunk, err := br.ReadSlice('\n')
		n += int64(len(chunk))
		if !tooLong {
			buf = append(buf, chunk...)
			if len(buf) > limit {
				tooLong, buf = true, nil
			}
		}
		if err == nil {
			if tooLong {
				return nil, n, true, nil
			}
			return buf[:len(buf)-1], n, true, nil
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return nil, n, false, err // EOF without newline: not consumed
	}
}

type claudeParser struct {
	o       ParseOptions
	res     *ParseResult
	callIdx map[string]int // api_call key → index in res.Events
	toolIdx map[string]int // tool_use_id → index in res.Events
	skills  map[string]bool // names from the latest skill_listing attachment
}

func (p *claudeParser) handle(raw []byte, off int64) {
	var rec claudeRecord
	if err := json.Unmarshal(raw, &rec); err != nil {
		p.res.Unknown["<invalid>"]++
		return
	}
	if !knownTypes[rec.Type] {
		p.res.Unknown[rec.Type]++
		return
	}
	if rec.SessionID != "" {
		p.touchSession(rec)
	}
	switch rec.Type {
	case "assistant":
		p.assistant(rec, off)
	case "user":
		p.user(rec, off)
	case "system":
		if rec.Subtype == "compact_boundary" {
			p.add(rec, off, db.AgentLogEvent{Key: "compaction:" + rec.UUID, Kind: "compaction"})
		}
	case "pr-link":
		if rec.PRURL != "" {
			p.add(rec, off, db.AgentLogEvent{Key: "pr_link:" + rec.SessionID + ":" + rec.PRURL, Kind: "pr_link", Target: rec.PRURL})
		}
	case "cost-state":
		if s := p.res.Sessions[rec.SessionID]; s != nil && rec.TotalCostUSD != nil {
			v := *rec.TotalCostUSD
			s.ReportedCostUSD = &v
		}
	case "attachment":
		p.attachment(rec)
	}
}

func (p *claudeParser) touchSession(rec claudeRecord) {
	s := p.res.Sessions[rec.SessionID]
	if s == nil {
		s = &db.AgentLogSession{SessionUUID: rec.SessionID, Agent: "claude", SourcePath: p.o.Path,
			StartedAt: rec.Timestamp, EndedAt: rec.Timestamp}
		p.res.Sessions[rec.SessionID] = s
	}
	if s.HomeCWD == "" && rec.CWD != "" {
		s.HomeCWD = rec.CWD
	}
	if s.GitBranch == "" && rec.GitBranch != "" {
		s.GitBranch = rec.GitBranch
	}
	if rec.Timestamp != "" {
		if s.StartedAt == "" || rec.Timestamp < s.StartedAt {
			s.StartedAt = rec.Timestamp
		}
		if rec.Timestamp > s.EndedAt {
			s.EndedAt = rec.Timestamp
		}
	}
}

// add fills the common columns of e from rec and appends it.
func (p *claudeParser) add(rec claudeRecord, off int64, e db.AgentLogEvent) int {
	e.SessionUUID, e.TS, e.UUID, e.ParentUUID, e.PromptID = rec.SessionID, rec.Timestamp, rec.UUID, rec.ParentUUID, rec.PromptID
	e.AgentID, e.IsSidechain = p.o.AgentID, rec.IsSidechain || p.o.Subagent
	e.SrcPath, e.SrcOffset = p.o.Path, off
	p.res.Events = append(p.res.Events, e)
	return len(p.res.Events) - 1
}

func (p *claudeParser) assistant(rec claudeRecord, off int64) {
	if rec.IsAPIError {
		p.add(rec, off, db.AgentLogEvent{Key: "api_error:" + rec.UUID, Kind: "api_error"})
		return
	}
	m := rec.Message
	if m.Usage != nil && m.Model != "<synthetic>" && m.ID != "" {
		p.apiCall(rec, off)
	}
	p.toolUses(rec, off) // Task 4
}

func (p *claudeParser) apiCall(rec claudeRecord, off int64) {
	m, u := rec.Message, rec.Message.Usage
	key := m.ID + ":" + rec.RequestID
	if rec.RequestID == "" {
		key = m.ID + ":" + rec.SessionID
	}
	cw5, cw1h := u.CacheCreation, int64(0)
	if u.CacheBreakdown != nil && u.CacheBreakdown.FiveMin+u.CacheBreakdown.OneHour > 0 {
		cw5, cw1h = u.CacheBreakdown.FiveMin, u.CacheBreakdown.OneHour
	}
	usd, known := Cost(m.Model, u.Speed, u.Input, u.Output, u.CacheRead, cw5, cw1h)
	e := db.AgentLogEvent{Key: key, Kind: "api_call", Name: m.Model, Skill: rec.AttributionSkill,
		InputTokens: u.Input, OutputTokens: u.Output, CacheReadTokens: u.CacheRead,
		CacheWrite5mTokens: cw5, CacheWrite1hTokens: cw1h, Speed: u.Speed, ServiceTier: u.ServiceTier,
		CostUSD: usd, CostEstimated: !known, PriceVersion: PriceVersion,
		MessageID: m.ID, SubagentReplayCheck: p.o.Subagent}
	if i, ok := p.callIdx[key]; ok {
		if u.Output >= p.res.Events[i].OutputTokens {
			e.SessionUUID, e.TS, e.UUID, e.ParentUUID, e.PromptID = rec.SessionID, p.res.Events[i].TS, p.res.Events[i].UUID, p.res.Events[i].ParentUUID, p.res.Events[i].PromptID
			e.AgentID, e.IsSidechain, e.SrcPath, e.SrcOffset = p.res.Events[i].AgentID, p.res.Events[i].IsSidechain, p.res.Events[i].SrcPath, p.res.Events[i].SrcOffset
			p.res.Events[i] = e
		}
		return
	}
	if s := p.res.Sessions[rec.SessionID]; s != nil {
		s.Model = m.Model
	}
	p.callIdx[key] = p.add(rec, off, e)
}

func (p *claudeParser) user(rec claudeRecord, off int64) {
	if rec.IsMeta || rec.IsCompactSummary || rec.Message.Role != "user" {
		return
	}
	var text string
	if json.Unmarshal(rec.Message.Content, &text) == nil {
		if strings.HasPrefix(text, "<local-command") || strings.HasPrefix(text, "[Request interrupted by user") {
			return
		}
		p.add(rec, off, db.AgentLogEvent{Key: "owner_turn:" + rec.UUID, Kind: "owner_turn"})
		p.slashSkill(rec, off, text) // Task 4
		return
	}
	var blocks []struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	hasResult := false
	for _, b := range blocks {
		if b.Type == "tool_result" {
			hasResult = true
		}
	}
	if hasResult {
		p.toolResults(rec) // Task 4
		return
	}
	p.add(rec, off, db.AgentLogEvent{Key: "owner_turn:" + rec.UUID, Kind: "owner_turn"})
}

func (p *claudeParser) attachment(rec claudeRecord) {
	var a struct {
		Type  string   `json:"type"`
		Names []string `json:"names"`
	}
	if json.Unmarshal(rec.Attachment, &a) == nil && a.Type == "skill_listing" && len(a.Names) > 0 {
		p.skills = map[string]bool{}
		for _, n := range a.Names {
			p.skills[n] = true
		}
	}
}
```

For this task add stubs in `claude_tools.go` so it compiles: `func (p *claudeParser) toolUses(claudeRecord, int64) {}`, `func (p *claudeParser) toolResults(claudeRecord) {}`, `func (p *claudeParser) slashSkill(claudeRecord, int64, string) {}` — Task 4 replaces them.

- [ ] **Step 4: Run** `go test ./internal/agentlog -run TestParseClaude -v` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `git add internal/agentlog && git commit -m "feat(agentlog): Claude transcript parser for calls, turns and markers"`

---

### Task 4: Claude parser — tools, outcomes, targets, skills

**Files:**
- Modify: `internal/agentlog/claude_tools.go` (replace the stubs)
- Test: `internal/agentlog/claude_tools_test.go`

**Interfaces:**
- Consumes: `claudeParser`, `claudeRecord`, `add` (T3).
- Produces: `func toolTarget(name string, input json.RawMessage, folder string) string`; `func errorClass(content string) string`.

- [ ] **Step 1: Write failing tests**

```go
package agentlog

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
)

func toolUse(id, name string, input map[string]any) map[string]any {
	return map[string]any{"type": "tool_use", "id": id, "name": name, "input": input}
}

func toolResultLine(t *testing.T, sid, uuid, id, content string, isErr bool, extra map[string]any) string {
	m := map[string]any{"type": "user", "sessionId": sid, "uuid": uuid, "timestamp": "2026-10-01T10:00:03.000Z",
		"message": map[string]any{"role": "user", "content": []map[string]any{{"type": "tool_result", "tool_use_id": id, "content": content, "is_error": isErr}}}}
	for k, v := range extra {
		m[k] = v
	}
	return line(t, m)
}

func TestParseClaude_ToolPairingOutcomesAndTargets(t *testing.T) {
	s := line(t, assistant("s1", "u1", "m1", "r1", 5,
		toolUse("t1", "Bash", map[string]any{"command": "FOO=1 git commit -m SENTINEL-MSG && echo done"}),
		toolUse("t2", "Edit", map[string]any{"file_path": "/w/app/main.go", "old_string": "SENTINEL-OLD"}),
		toolUse("t3", "Read", map[string]any{"file_path": "/etc/hosts"}),
		toolUse("t4", "Bash", map[string]any{"command": "rm -rf build"}),
		toolUse("t5", "Bash", map[string]any{"command": "sleep 100"}))) +
		toolResultLine(t, "s1", "r1", "t1", "Command failed with exit code 1", true, nil) +
		toolResultLine(t, "s1", "r2", "t2", "ok", false, map[string]any{"toolUseResult": map[string]any{
			"structuredPatch": []map[string]any{{"lines": []string{"+a", "+b", "-c", " d"}}}}}) +
		toolResultLine(t, "s1", "r3", "t4", "The user doesn't want to proceed with this tool use.", true, nil) +
		toolResultLine(t, "s1", "r4", "t5", "[Request interrupted by user]", true, map[string]any{"toolUseResult": map[string]any{"interrupted": true}})
	r := parse(t, s, ParseOptions{})
	targets := map[string]string{}
	for _, e := range r.Events {
		if e.Kind == "tool" {
			targets[e.Key] = e.Target
			assert.Equal(t, "pending", e.Outcome)
		}
	}
	assert.Equal(t, map[string]string{"tool:t1": "git commit", "tool:t2": "app/main.go", "tool:t3": "<outside>",
		"tool:t4": "rm", "tool:t5": "sleep"}, targets)
	got := map[string]string{}
	for _, tr := range r.ToolResults {
		got[tr.ToolUseID] = tr.Outcome + "/" + tr.ErrorClass
		if tr.ToolUseID == "t2" {
			assert.Equal(t, 2, tr.LinesAdded)
			assert.Equal(t, 1, tr.LinesRemoved)
		}
	}
	assert.Equal(t, map[string]string{"t1": "error/exit_code", "t2": "ok/", "t4": "denied/", "t5": "interrupted/"}, got)
	b, _ := json.Marshal(r)
	assert.NotContains(t, string(b), "SENTINEL")
}

func TestParseClaude_DenialKindMarksDenied(t *testing.T) {
	s := line(t, assistant("s1", "u1", "m1", "r1", 5, toolUse("t1", "Bash", map[string]any{"command": "make deploy"}))) +
		toolResultLine(t, "s1", "r1", "t1", "denied", true, map[string]any{"toolDenialKind": "automode-unavailable"})
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, "denied", r.ToolResults[0].Outcome)
}

func TestParseClaude_SkillActivations(t *testing.T) {
	s := line(t, map[string]any{"type": "attachment", "sessionId": "s1", "attachment": map[string]any{"type": "skill_listing", "names": []string{"brainstorming", "review"}}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "timestamp": "2026-10-01T09:00:00Z",
			"message": map[string]any{"role": "user", "content": "<command-name>/review</command-name><command-args>SENTINEL</command-args>"}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o2", "timestamp": "2026-10-01T09:00:01Z",
			"message": map[string]any{"role": "user", "content": "<command-name>/clear</command-name>"}}) +
		line(t, assistant("s1", "u1", "m1", "r1", 5,
			toolUse("t1", "Skill", map[string]any{"skill": "superpowers:brainstorming", "args": "SENTINEL"}),
			toolUse("t2", "Read", map[string]any{"file_path": "/h/.claude/skills/pdf/SKILL.md"})))
	r := parse(t, s, ParseOptions{})
	var got []string
	for _, e := range r.Events {
		if e.Kind == "skill" {
			got = append(got, e.Name+"/"+e.Trigger)
		}
	}
	assert.ElementsMatch(t, []string{"review/slash", "superpowers:brainstorming/proactive", "pdf/read"}, got)
}

func TestErrorClass(t *testing.T) {
	assert.Equal(t, "exit_code", errorClass("Exit code 2"))
	assert.Equal(t, "not_found", errorClass("File does not exist."))
	assert.Equal(t, "timeout", errorClass("Command timed out after 2m"))
	assert.Equal(t, "other", errorClass("boom"))
}
```

- [ ] **Step 2: Run** `go test ./internal/agentlog -run 'TestParseClaude_Tool|TestParseClaude_Denial|TestParseClaude_Skill|TestErrorClass' -v` → FAIL.

- [ ] **Step 3: Implement `claude_tools.go`**

```go
package agentlog

import (
	"encoding/json"
	"path/filepath"
	"regexp"
	"strings"

	"watchtower/internal/db"
)

// subcommandPrograms keep their first argument in the target ("git commit")
// so #298 can find commits and PRs; nothing past it is ever stored.
var subcommandPrograms = map[string]bool{"git": true, "gh": true, "go": true, "make": true, "npm": true, "swift": true}

var fileTools = map[string]bool{"Read": true, "Edit": true, "Write": true, "MultiEdit": true, "NotebookEdit": true}

func (p *claudeParser) toolUses(rec claudeRecord, off int64) {
	var blocks []struct {
		Type  string          `json:"type"`
		ID    string          `json:"id"`
		Name  string          `json:"name"`
		Input json.RawMessage `json:"input"`
	}
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	for _, b := range blocks {
		if b.Type != "tool_use" || b.ID == "" {
			continue
		}
		if _, seen := p.toolIdx[b.ID]; seen {
			continue
		}
		p.toolIdx[b.ID] = p.add(rec, off, db.AgentLogEvent{Key: "tool:" + b.ID, Kind: "tool", Name: b.Name,
			Target: toolTarget(b.Name, b.Input, p.o.Folder), Outcome: "pending", Skill: rec.AttributionSkill})
		switch {
		case b.Name == "Skill":
			var in struct {
				Skill string `json:"skill"`
			}
			if json.Unmarshal(b.Input, &in) == nil && in.Skill != "" {
				p.add(rec, off, db.AgentLogEvent{Key: "skill:" + b.ID, Kind: "skill", Name: in.Skill, Trigger: "proactive"})
			}
		case b.Name == "Read":
			var in struct {
				FilePath string `json:"file_path"`
			}
			if json.Unmarshal(b.Input, &in) == nil && filepath.Base(in.FilePath) == "SKILL.md" {
				p.add(rec, off, db.AgentLogEvent{Key: "skill:" + b.ID, Kind: "skill",
					Name: filepath.Base(filepath.Dir(in.FilePath)), Trigger: "read"})
			}
		}
	}
}

var commandNameRe = regexp.MustCompile(`<command-name>/?([^<\s]+)</command-name>`)

func (p *claudeParser) slashSkill(rec claudeRecord, off int64, text string) {
	m := commandNameRe.FindStringSubmatch(text)
	if m == nil || !p.skills[m[1]] {
		return
	}
	p.add(rec, off, db.AgentLogEvent{Key: "skill:" + rec.UUID + ":0", Kind: "skill", Name: m[1], Trigger: "slash"})
}

func (p *claudeParser) toolResults(rec claudeRecord) {
	var blocks []struct {
		Type      string          `json:"type"`
		ToolUseID string          `json:"tool_use_id"`
		Content   json.RawMessage `json:"content"`
		IsError   bool            `json:"is_error"`
	}
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	var tur struct {
		Interrupted     bool `json:"interrupted"`
		StructuredPatch []struct {
			Lines []string `json:"lines"`
		} `json:"structuredPatch"`
	}
	_ = json.Unmarshal(rec.ToolUseResult, &tur) // a string toolUseResult is fine: zero value
	for _, b := range blocks {
		if b.Type != "tool_result" || b.ToolUseID == "" {
			continue
		}
		text := resultText(b.Content)
		r := db.AgentToolResult{ToolUseID: b.ToolUseID, TS: rec.Timestamp, Outcome: "ok"}
		switch {
		case tur.Interrupted || strings.HasPrefix(text, "[Request interrupted by user"):
			r.Outcome = "interrupted"
		case rec.ToolDenialKind != "" || strings.Contains(text, "doesn't want to proceed with this tool use"):
			r.Outcome = "denied"
		case b.IsError:
			r.Outcome, r.ErrorClass = "error", errorClass(text)
		}
		for _, h := range tur.StructuredPatch {
			for _, l := range h.Lines {
				switch {
				case strings.HasPrefix(l, "+"):
					r.LinesAdded++
				case strings.HasPrefix(l, "-"):
					r.LinesRemoved++
				}
			}
		}
		p.res.ToolResults = append(p.res.ToolResults, r)
	}
}

// resultText reads a tool_result content (a string or a list of text
// blocks) for classification only; it is never stored.
func resultText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []struct {
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil && len(blocks) > 0 {
		return blocks[0].Text
	}
	return ""
}

func errorClass(text string) string {
	t := strings.ToLower(text)
	switch {
	case strings.Contains(t, "exit code"):
		return "exit_code"
	case strings.Contains(t, "does not exist") || strings.Contains(t, "no such file") || strings.Contains(t, "not found"):
		return "not_found"
	case strings.Contains(t, "timed out") || strings.Contains(t, "timeout"):
		return "timeout"
	default:
		return "other"
	}
}

// toolTarget is the content-free description of what a tool touched
// (AGENTLOG-01): a folder-relative path, or a shell program (+ subcommand).
func toolTarget(name string, input json.RawMessage, folder string) string {
	var in struct {
		FilePath     string `json:"file_path"`
		NotebookPath string `json:"notebook_path"`
		Command      string `json:"command"`
	}
	if json.Unmarshal(input, &in) != nil {
		return ""
	}
	switch {
	case fileTools[name]:
		path := in.FilePath
		if path == "" {
			path = in.NotebookPath
		}
		return relativeTarget(path, folder)
	case name == "Bash":
		return shellTarget(in.Command)
	}
	return ""
}

func relativeTarget(path, folder string) string {
	if path == "" {
		return ""
	}
	rel, err := filepath.Rel(folder, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return "<outside>"
	}
	return rel
}

func shellTarget(cmd string) string {
	if i := strings.IndexAny(cmd, "&|;\n"); i >= 0 {
		cmd = cmd[:i]
	}
	fields := strings.Fields(cmd)
	for len(fields) > 0 && strings.Contains(fields[0], "=") {
		fields = fields[1:]
	}
	if len(fields) == 0 {
		return ""
	}
	prog := filepath.Base(fields[0])
	if subcommandPrograms[prog] && len(fields) > 1 && !strings.HasPrefix(fields[1], "-") {
		return prog + " " + fields[1]
	}
	return prog
}
```

- [ ] **Step 4: Run** `go test ./internal/agentlog -v` → PASS (T3 tests too); `make lint-diff`.
- [ ] **Step 5: Commit** `git add internal/agentlog && git commit -m "feat(agentlog): tool outcomes, content-free targets and skill activations"`

---

### Task 5: Discovery

**Files:**
- Create: `internal/agentlog/discover.go`
- Test: `internal/agentlog/discover_test.go`

**Interfaces:**
- Produces:

```go
func Slug(path string) string
type TranscriptFile struct {
	Path, SessionUUID, AgentID string // AgentID "" for main files
	Subagent                   bool
	Size                       int64
	MTime                      string
}
func CandidateDirs(projectsDir string, roots []string) ([]string, error)
func ListTranscripts(dirs []string) ([]TranscriptFile, error) // main files first, then subagent files
func WorktreeRoots(folder string) []string                    // `git worktree list --porcelain` roots, folder excluded; nil on error
func OwnerFolder(home string, workbenchFolders []string, thisFolder string, thisRoots []string) string // "" = not ours
```

- [ ] **Step 1: Write failing tests**

```go
package agentlog

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSlug(t *testing.T) {
	assert.Equal(t, "-Users-a-my-app--claude-worktrees-x", Slug("/Users/a/my app/.claude/worktrees/x"))
}

func TestCandidateDirs_PrefixOnlyAndNoSymlinks(t *testing.T) {
	proj := t.TempDir()
	for _, d := range []string{"-w-app", "-w-app-sub", "-w-app--claude-worktrees-x", "-w-apple", "-other"} {
		require.NoError(t, os.Mkdir(filepath.Join(proj, d), 0o755))
	}
	require.NoError(t, os.Symlink(filepath.Join(proj, "-other"), filepath.Join(proj, "-w-app-link")))
	got, err := CandidateDirs(proj, []string{"/w/app"})
	require.NoError(t, err)
	var names []string
	for _, g := range got {
		names = append(names, filepath.Base(g))
	}
	// "-w-apple" is a different folder: only exact or "<slug>-" prefixes match.
	assert.ElementsMatch(t, []string{"-w-app", "-w-app-sub", "-w-app--claude-worktrees-x"}, names)
}

func TestListTranscripts_MainBeforeSubagents(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "-w")
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "s1", "subagents"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "s1", "subagents", "agent-a1.jsonl"), []byte("x\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "s1.jsonl"), []byte("x\n"), 0o600))
	files, err := ListTranscripts([]string{dir})
	require.NoError(t, err)
	require.Len(t, files, 2)
	assert.False(t, files[0].Subagent)
	assert.Equal(t, "s1", files[0].SessionUUID)
	assert.True(t, files[1].Subagent)
	assert.Equal(t, "s1", files[1].SessionUUID)
	assert.Equal(t, "a1", files[1].AgentID)
}

func TestOwnerFolder_LongestWorkbenchWins(t *testing.T) {
	all := []string{"/w", "/w/inner"}
	assert.Equal(t, "", OwnerFolder("/w/inner/x", all, "/w", nil))          // inner owns it
	assert.Equal(t, "/w/inner", OwnerFolder("/w/inner/x", all, "/w/inner", nil))
	assert.Equal(t, "/w", OwnerFolder("/w/other", all, "/w", nil))
	assert.Equal(t, "/w", OwnerFolder("/wt/feature", all, "/w", []string{"/wt/feature"})) // worktree outside
	assert.Equal(t, "", OwnerFolder("/elsewhere", all, "/w", nil))
	assert.Equal(t, "/w", OwnerFolder("/W/Sub", all, "/w", nil)) // APFS: case-insensitive
}
```

- [ ] **Step 2: Run** `go test ./internal/agentlog -run 'TestSlug|TestCandidateDirs|TestListTranscripts|TestOwnerFolder' -v` → FAIL.

- [ ] **Step 3: Implement**

```go
package agentlog

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Slug is Claude Code's project directory name for a cwd: every
// non-alphanumeric byte becomes '-'.
func Slug(path string) string {
	b := []byte(path)
	for i, c := range b {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			b[i] = '-'
		}
	}
	return string(b)
}

// CandidateDirs lists the directories under projectsDir whose name is the
// slug of one of roots or starts with it plus '-' (subfolders, nested
// worktrees). Symlinked entries are skipped (AGENTLOG-04).
func CandidateDirs(projectsDir string, roots []string) ([]string, error) {
	entries, err := os.ReadDir(projectsDir)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if e.Type()&os.ModeSymlink != 0 || !e.IsDir() {
			continue
		}
		for _, r := range roots {
			s := Slug(r)
			if strings.EqualFold(e.Name(), s) || strings.HasPrefix(strings.ToLower(e.Name()), strings.ToLower(s)+"-") {
				out = append(out, filepath.Join(projectsDir, e.Name()))
				break
			}
		}
	}
	return out, nil
}

// ListTranscripts returns the transcripts in dirs: <uuid>.jsonl main files
// first, then <uuid>/subagents/agent-*.jsonl, so a parent session is always
// stored before its subagents' replay check runs.
func ListTranscripts(dirs []string) ([]TranscriptFile, error) {
	var mains, subs []TranscriptFile
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.Type()&os.ModeSymlink != 0 {
				continue
			}
			name := e.Name()
			if !e.IsDir() && strings.HasSuffix(name, ".jsonl") {
				if f, ok := statTranscript(filepath.Join(dir, name)); ok {
					f.SessionUUID = strings.TrimSuffix(name, ".jsonl")
					mains = append(mains, f)
				}
				continue
			}
			if e.IsDir() {
				subDir := filepath.Join(dir, name, "subagents")
				subEntries, err := os.ReadDir(subDir)
				if err != nil {
					continue
				}
				for _, se := range subEntries {
					sn := se.Name()
					if se.Type()&os.ModeSymlink != 0 || se.IsDir() || !strings.HasPrefix(sn, "agent-") || !strings.HasSuffix(sn, ".jsonl") {
						continue
					}
					if f, ok := statTranscript(filepath.Join(subDir, sn)); ok {
						f.SessionUUID, f.Subagent = name, true
						f.AgentID = strings.TrimSuffix(strings.TrimPrefix(sn, "agent-"), ".jsonl")
						subs = append(subs, f)
					}
				}
			}
		}
	}
	sort.Slice(mains, func(i, j int) bool { return mains[i].Path < mains[j].Path })
	sort.Slice(subs, func(i, j int) bool { return subs[i].Path < subs[j].Path })
	return append(mains, subs...), nil
}

func statTranscript(path string) (TranscriptFile, bool) {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return TranscriptFile{}, false
	}
	return TranscriptFile{Path: path, Size: fi.Size(), MTime: fi.ModTime().UTC().Format(time.RFC3339Nano)}, true
}

// WorktreeRoots lists the folder's git worktrees other than the folder
// itself; nil when the folder is not a repository.
func WorktreeRoots(folder string) []string {
	out, err := exec.Command("git", "-C", folder, "worktree", "list", "--porcelain").Output()
	if err != nil {
		return nil
	}
	var roots []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		if p, ok := strings.CutPrefix(sc.Text(), "worktree "); ok && !strings.EqualFold(filepath.Clean(p), filepath.Clean(folder)) {
			roots = append(roots, p)
		}
	}
	return roots
}

// OwnerFolder decides whether a session whose home cwd is home belongs to the
// workbench at thisFolder: the longest workbench folder containing home
// wins; a home in one of thisRoots (worktrees outside the folder) is ours
// when no workbench folder contains it. Returns thisFolder or "".
func OwnerFolder(home string, workbenchFolders []string, thisFolder string, thisRoots []string) string {
	best := ""
	for _, f := range workbenchFolders {
		if within(home, f) && len(f) > len(best) {
			best = f
		}
	}
	if best != "" {
		if strings.EqualFold(best, thisFolder) {
			return thisFolder
		}
		return ""
	}
	for _, r := range thisRoots {
		if within(home, r) {
			return thisFolder
		}
	}
	return ""
}

func within(path, dir string) bool {
	p, d := strings.ToLower(filepath.Clean(path)), strings.ToLower(filepath.Clean(dir))
	return p == d || strings.HasPrefix(p, d+"/")
}
```

`home` and folders are compared after `filepath.EvalSymlinks` when they exist — the scanner (Task 6) resolves `home` before calling `OwnerFolder`; workbench folders are already stored resolved (`Workbench.FolderPath` comment).

- [ ] **Step 4: Run** the tests → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `git add internal/agentlog && git commit -m "feat(agentlog): transcript discovery and session ownership"`

---

### Task 6: Scanner

**Files:**
- Create: `internal/agentlog/scan.go`
- Test: `internal/agentlog/scan_test.go`

**Interfaces:**
- Consumes: T1 DB methods, T3/T4 `ParseClaude`, T5 discovery, T2 `Cost`/`PriceVersion`.
- Produces:

```go
type Options struct {
	ClaudeDir string        // ~/.claude; tests pass a temp dir
	Budget    time.Duration // 0 = unbounded
	Now       func() time.Time
}
type Result struct {
	FilesScanned   int            `json:"files_scanned"`
	FilesSkipped   int            `json:"files_skipped"`
	EventsWritten  int            `json:"events_written"`
	Sessions       int            `json:"sessions"`
	UnknownRecords map[string]int `json:"unknown_records"`
	LongLines      int            `json:"long_lines"`
	MissingFiles   int            `json:"missing_files"`
	Repriced       int            `json:"repriced"`
	Adopted        int64          `json:"adopted"`
	Incomplete     bool           `json:"incomplete"`
}
func Scan(ctx context.Context, d *db.DB, workbenchID int64, o Options) (*Result, error)
func DefaultClaudeDir() string // $HOME/.claude — never CLAUDE_CONFIG_DIR (dual path with cmd defaultTerminalClaudeDir)
```

- [ ] **Step 1: Write failing tests** (temp `ClaudeDir`, test DB, synthetic transcripts reusing `line`/`assistant` from Task 3 tests)

```go
package agentlog

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

type fixture struct {
	t      *testing.T
	d      *db.DB
	claude string
	folder string
	wb     int64
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	folder := t.TempDir()
	folder, _ = filepath.EvalSymlinks(folder)
	wb, err := d.CreateWorkbench("app", folder)
	require.NoError(t, err)
	require.NoError(t, d.SetWorkbenchAgentAnalytics(wb, true))
	return &fixture{t: t, d: d, claude: t.TempDir(), folder: folder, wb: wb}
}

// write appends content to the transcript of session sid whose cwd is cwd.
func (f *fixture) write(cwd, rel, content string) string {
	dir := filepath.Join(f.claude, "projects", Slug(cwd))
	p := filepath.Join(dir, rel)
	require.NoError(f.t, os.MkdirAll(filepath.Dir(p), 0o755))
	fh, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	require.NoError(f.t, err)
	_, err = fh.WriteString(content)
	require.NoError(f.t, err)
	require.NoError(f.t, fh.Close())
	return p
}

func (f *fixture) scan() *Result {
	r, err := Scan(context.Background(), f.d, f.wb, Options{ClaudeDir: f.claude})
	require.NoError(f.t, err)
	return r
}

func (f *fixture) totals() (calls, out int64) {
	require.NoError(f.t, f.d.QueryRow(`SELECT COUNT(*), COALESCE(SUM(output_tokens),0) FROM agent_log_events WHERE kind='api_call'`).Scan(&calls, &out))
	return
}

func call(t *testing.T, sid, cwd, uuid, msg, req string, out int64) string {
	a := assistant(sid, uuid, msg, req, out)
	a["cwd"] = cwd
	return line(t, a)
}

func TestScan_BackfillThenIncremental(t *testing.T) {
	f := newFixture(t)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	r := f.scan()
	assert.Equal(t, 1, r.Sessions)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u2", "m2", "r2", 7))
	f.scan()
	calls, out := f.totals()
	assert.Equal(t, int64(2), calls)
	assert.Equal(t, int64(12), out)
	r = f.scan() // nothing changed
	assert.Equal(t, 1, r.FilesSkipped)
}

func TestScan_PartialLineCompletedLater(t *testing.T) {
	f := newFixture(t)
	full := call(t, "s1", f.folder, "u1", "m1", "r1", 5)
	f.write(f.folder, "s1.jsonl", full[:len(full)/2])
	f.scan()
	calls, _ := f.totals()
	assert.Zero(t, calls)
	f.write(f.folder, "s1.jsonl", full[len(full)/2:])
	f.scan()
	calls, _ = f.totals()
	assert.Equal(t, int64(1), calls)
}

func TestScan_ShrunkFileReparsedWithoutDuplicates(t *testing.T) {
	f := newFixture(t)
	p := f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5)+call(t, "s1", f.folder, "u2", "m2", "r2", 5))
	f.scan()
	require.NoError(t, os.WriteFile(p, []byte(call(t, "s1", f.folder, "u1", "m1", "r1", 5)), 0o600))
	f.scan()
	calls, _ := f.totals()
	assert.Equal(t, int64(2), calls) // m2 stays (AGENTLOG-03), m1 not doubled
}

func TestScan_ForkReplayCountsOnceInEitherOrder(t *testing.T) {
	for _, order := range [][]string{{"orig", "fork"}, {"fork", "orig"}} {
		f := newFixture(t)
		lines := map[string]string{
			"orig": call(t, "orig", f.folder, "u1", "m1", "r1", 5),
			"fork": call(t, "fork", f.folder, "u1", "m1", "r1", 5) + call(t, "fork", f.folder, "u9", "m9", "r9", 3),
		}
		for _, sid := range order {
			f.write(f.folder, sid+".jsonl", lines[sid])
			f.scan()
		}
		calls, out := f.totals()
		assert.Equal(t, int64(2), calls)
		assert.Equal(t, int64(8), out)
	}
}

func TestScan_SubagentReplayOfParentSkipped(t *testing.T) {
	f := newFixture(t)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.write(f.folder, "s1/subagents/agent-a1.jsonl", call(t, "s1", f.folder, "u1", "m1", "rX", 5)+call(t, "s1", f.folder, "u2", "m2", "r2", 4))
	f.scan()
	calls, out := f.totals()
	assert.Equal(t, int64(2), calls)
	assert.Equal(t, int64(9), out)
}

func TestScan_NestedWorkbenchesLongestWins(t *testing.T) {
	f := newFixture(t)
	inner := filepath.Join(f.folder, "inner")
	require.NoError(t, os.Mkdir(inner, 0o755))
	innerWB, err := f.d.CreateWorkbench("inner", inner)
	require.NoError(t, err)
	f.write(inner, "s1.jsonl", call(t, "s1", inner, "u1", "m1", "r1", 5))
	f.scan() // outer: the session is inner's, not read, no file row
	calls, _ := f.totals()
	assert.Zero(t, calls)
	require.NoError(t, f.d.SetWorkbenchAgentAnalytics(innerWB, true))
	_, err = Scan(context.Background(), f.d, innerWB, Options{ClaudeDir: f.claude})
	require.NoError(t, err)
	calls, _ = f.totals()
	assert.Equal(t, int64(1), calls)
}

func TestScan_UnrelatedProjectNeverOpened(t *testing.T) {
	f := newFixture(t)
	other := filepath.Join(f.claude, "projects", "-somewhere-else")
	require.NoError(t, os.MkdirAll(other, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(other, "x.jsonl"), []byte("{}\n"), 0o000)) // unreadable: opening it would fail the test
	f.scan()
	fr, err := f.d.GetAgentLogFile(filepath.Join(other, "x.jsonl"))
	require.NoError(t, err)
	assert.Nil(t, fr)
}

func TestScan_DeletedFileKeepsRowsAndParserBumpRereadsPresentOnly(t *testing.T) {
	f := newFixture(t)
	p := f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.scan()
	require.NoError(t, os.Remove(p))
	r := f.scan()
	assert.Equal(t, 1, r.MissingFiles)
	calls, _ := f.totals()
	assert.Equal(t, int64(1), calls)
}

func TestScan_ConcurrentWritersCountOnce(t *testing.T) {
	f := newFixture(t)
	for i := 0; i < 20; i++ {
		f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u"+string(rune('a'+i)), "m"+string(rune('a'+i)), "r", 1))
	}
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = Scan(context.Background(), f.d, f.wb, Options{ClaudeDir: f.claude}) }()
	}
	wg.Wait()
	calls, out := f.totals()
	assert.Equal(t, int64(20), calls)
	assert.Equal(t, int64(20), out)
}

func TestScan_RepricesOlderRows(t *testing.T) {
	f := newFixture(t)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.scan()
	_, err := f.d.Exec(`UPDATE agent_log_events SET price_version = 0, cost_usd = 99`)
	require.NoError(t, err)
	r := f.scan()
	assert.Equal(t, 1, r.Repriced)
	var usd float64
	require.NoError(t, f.d.QueryRow(`SELECT cost_usd FROM agent_log_events`).Scan(&usd))
	assert.Less(t, usd, 1.0)
}
```

(`TestScan_UnrelatedProjectNeverOpened`: if the suite runs as root the 0o000 file is readable — the assertion on the absent file row still holds; keep it.)

- [ ] **Step 2: Run** `go test ./internal/agentlog -run TestScan -v` → FAIL.

- [ ] **Step 3: Implement `scan.go`**

```go
package agentlog

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/db"
)

// DefaultClaudeDir is ~/.claude. Like cmd's defaultTerminalClaudeDir it never
// reads CLAUDE_CONFIG_DIR (dual path, v1 limit).
func DefaultClaudeDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude")
}

// Scan brings workbench id's analytics up to date: adopt orphaned sessions,
// read each candidate transcript from its stored offset, mark vanished files,
// reprice old rows. Safe to run concurrently with itself (CAS + idempotent keys).
func Scan(ctx context.Context, d *db.DB, id int64, o Options) (*Result, error) {
	if o.ClaudeDir == "" {
		o.ClaudeDir = DefaultClaudeDir()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	wb, err := d.GetWorkbench(id)
	if err != nil {
		return nil, err
	}
	res := &Result{UnknownRecords: map[string]int{}}
	if res.Adopted, err = d.AdoptAgentLogSessions(id, wb.FolderPath); err != nil {
		return nil, fmt.Errorf("adopting sessions: %w", err)
	}
	all, err := d.ListWorkbenches()
	if err != nil {
		return nil, err
	}
	folders := make([]string, 0, len(all))
	for _, w := range all {
		folders = append(folders, w.FolderPath)
	}
	roots := WorktreeRoots(wb.FolderPath)
	dirs, err := CandidateDirs(filepath.Join(o.ClaudeDir, "projects"), append([]string{wb.FolderPath}, roots...))
	if err != nil {
		return nil, fmt.Errorf("listing transcript directories: %w", err)
	}
	files, err := ListTranscripts(dirs)
	if err != nil {
		return nil, err
	}
	deadline := time.Time{}
	if o.Budget > 0 {
		deadline = o.Now().Add(o.Budget)
	}
	sessions := map[string]bool{}
	present := map[string]bool{}
	owned := map[string]bool{} // session uuid → owned by this workbench
	for _, tf := range files {
		present[tf.Path] = true
		if ctx.Err() != nil || (!deadline.IsZero() && o.Now().After(deadline)) {
			res.Incomplete = true
			break
		}
		mine, err := ownsSession(d, tf, owned, folders, wb.FolderPath, roots)
		if err != nil {
			return nil, err
		}
		if !mine {
			continue
		}
		sessions[tf.SessionUUID] = true
		if err := scanFile(d, tf, wb, res); err != nil {
			return nil, err
		}
	}
	res.Sessions = len(sessions)
	known, err := d.AgentLogFilesUnder(dirs)
	if err != nil {
		return nil, err
	}
	for _, f := range known {
		if !present[f.Path] && f.MissingAt == "" {
			if err := d.MarkAgentLogFileMissing(f.Path, o.Now().UTC().Format(time.RFC3339)); err != nil {
				return nil, err
			}
			res.MissingFiles++
		}
	}
	if res.Repriced, err = d.RepriceAgentLogEvents(PriceVersion, Cost); err != nil {
		return nil, fmt.Errorf("repricing: %w", err)
	}
	return res, nil
}

// ownsSession decides once per session: a stored session keeps the folder it
// was matched to; a new one is matched by the home cwd of its main file.
func ownsSession(d *db.DB, tf TranscriptFile, owned map[string]bool, folders []string, folder string, roots []string) (bool, error) {
	if v, ok := owned[tf.SessionUUID]; ok {
		return v, nil
	}
	stored, ok, err := d.AgentLogSessionFolder(tf.SessionUUID)
	if err != nil {
		return false, err
	}
	if ok {
		owned[tf.SessionUUID] = equalFold(stored, folder)
		return owned[tf.SessionUUID], nil
	}
	home := firstCWD(tf.Path)
	if r, err := filepath.EvalSymlinks(home); err == nil {
		home = r
	}
	owned[tf.SessionUUID] = home != "" && OwnerFolder(home, folders, folder, roots) != ""
	return owned[tf.SessionUUID], nil
}

func scanFile(d *db.DB, tf TranscriptFile, wb *db.Workbench, res *Result) error {
	stored, err := d.GetAgentLogFile(tf.Path)
	if err != nil {
		return err
	}
	start, expect := int64(0), int64(-1)
	if stored != nil {
		expect = stored.ReadOffset
		if stored.MissingAt == "" && stored.Size == tf.Size && stored.MTime == tf.MTime && stored.ParserVersion == ParserVersion {
			res.FilesSkipped++
			return nil
		}
		if tf.Size >= stored.ReadOffset && stored.ParserVersion == ParserVersion {
			start = stored.ReadOffset
		}
	}
	fh, err := os.Open(tf.Path)
	if err != nil {
		return nil // vanished between listing and open: the missing sweep catches it
	}
	defer fh.Close()
	if _, err := fh.Seek(start, io.SeekStart); err != nil {
		return err
	}
	pr, err := ParseClaude(fh, start, ParseOptions{Path: tf.Path, Folder: wb.FolderPath, Subagent: tf.Subagent, AgentID: tf.AgentID})
	if err != nil {
		return err
	}
	b := db.AgentLogBatch{File: db.AgentLogFile{Path: tf.Path, Agent: "claude", Size: tf.Size, MTime: tf.MTime,
		ReadOffset: start + pr.Consumed, ParserVersion: ParserVersion}, ExpectOffset: expect,
		Events: pr.Events, ToolResults: pr.ToolResults}
	pid := wb.ID
	for _, s := range pr.Sessions {
		s.ProjectID, s.FolderPath = &pid, wb.FolderPath
		if tf.Subagent {
			s.SourcePath = filepath.Dir(filepath.Dir(tf.Path)) + ".jsonl"
		}
		b.Sessions = append(b.Sessions, *s)
	}
	applied, err := d.ApplyAgentLogBatch(b)
	if err != nil {
		return fmt.Errorf("storing %s: %w", tf.Path, err)
	}
	res.FilesScanned++
	if applied {
		res.EventsWritten += len(pr.Events)
	}
	for k, v := range pr.Unknown {
		res.UnknownRecords[k] += v
	}
	res.LongLines += pr.LongLines
	return nil
}
```

Add the two small helpers: `firstCWD(path string) string` (open the file, read lines with `nextLine` until a record with a non-empty `cwd` — at most the first 200 lines — return it, "" otherwise) and `equalFold(a, b string) bool` (`strings.EqualFold(filepath.Clean(a), filepath.Clean(b))`).

Note: a stored file row whose `missing_at` is set and that reappears is re-read from its offset (the CAS `UPDATE` clears `missing_at`). A shrunk file or a parser bump restarts at 0 with `expect` = the stored offset, so the CAS still guards it.

- [ ] **Step 4: Run** `go test ./internal/agentlog -v -race` once at the end of the task → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `git add internal/agentlog && git commit -m "feat(agentlog): incremental per-workbench scanner"`

---

### Task 7: CLI `watchtower agents`

**Files:**
- Create: `cmd/agents.go`
- Test: `cmd/agents_test.go`

**Interfaces:**
- Consumes: `agentlog.Scan`, `agentlog.Options`, `db.SetWorkbenchAgentAnalytics`, `db.AgentLogStats`.
- Produces: commands `agents enable|disable|scan|stats --workbench N [--json]`; package var `agentsClaudeDir = agentlog.DefaultClaudeDir` (test seam, like `terminalClaudeDir`).

- [ ] **Step 1: Write failing tests**

```go
package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlog"
)

func runAgentsCmd(t *testing.T, args ...string) string {
	t.Helper()
	t.Cleanup(func() {
		flagAgentsWorkbench, flagAgentsJSON = 0, false
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"agents"}, args...))
	require.NoError(t, rootCmd.Execute(), errOut.String())
	return out.String()
}

func agentsFixture(t *testing.T) (wb int64) {
	t.Helper()
	database := writeActionsConfig(t)
	folder, _ := filepath.EvalSymlinks(t.TempDir())
	wb, err := database.CreateWorkbench("app", folder)
	require.NoError(t, err)
	claude := t.TempDir()
	prev := agentsClaudeDir
	agentsClaudeDir = func() string { return claude }
	t.Cleanup(func() { agentsClaudeDir = prev })
	dir := filepath.Join(claude, "projects", agentlog.Slug(folder))
	require.NoError(t, os.MkdirAll(dir, 0o755))
	rec := `{"type":"assistant","sessionId":"s1","uuid":"u1","timestamp":"2026-10-01T10:00:00Z","cwd":"` + folder +
		`","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","role":"assistant","content":[],"usage":{"input_tokens":10,"output_tokens":5}}}` + "\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "s1.jsonl"), []byte(rec), 0o600))
	return wb
}

func TestAgentsEnable_BackfillsAtOnce(t *testing.T) {
	wb := agentsFixture(t)
	out := runAgentsCmd(t, "enable", "--workbench", strconv.FormatInt(wb, 10), "--json")
	var r map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.EqualValues(t, 1, r["sessions"])
}

func TestAgentsStatsJSON_PinnedKeys(t *testing.T) {
	wb := agentsFixture(t)
	runAgentsCmd(t, "enable", "--workbench", strconv.FormatInt(wb, 10))
	out := runAgentsCmd(t, "stats", "--workbench", strconv.FormatInt(wb, 10), "--json")
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"cost_estimated_calls", "cost_usd", "enabled", "outcomes", "owner_turns", "per_session",
		"reported_cost_usd", "sessions", "skills", "tokens", "tools", "workbench_id"}, keys)
}

func TestAgentsScan_RefusesWhenDisabled(t *testing.T) {
	wb := agentsFixture(t)
	rootCmd.SetArgs([]string{"agents", "scan", "--workbench", strconv.FormatInt(wb, 10)})
	t.Cleanup(func() { flagAgentsWorkbench = 0; rootCmd.SetArgs(nil) })
	assert.ErrorContains(t, rootCmd.Execute(), "analytics is off")
}

func TestAgentsDisable_KeepsRows(t *testing.T) {
	wb := agentsFixture(t)
	id := strconv.FormatInt(wb, 10)
	runAgentsCmd(t, "enable", "--workbench", id)
	runAgentsCmd(t, "disable", "--workbench", id)
	out := runAgentsCmd(t, "stats", "--workbench", id, "--json")
	assert.Contains(t, out, `"sessions": 1`)
	assert.Contains(t, out, `"enabled": false`)
}
```

- [ ] **Step 2: Run** `go test ./cmd -run TestAgents -v` → FAIL.

- [ ] **Step 3: Implement `cmd/agents.go`**

```go
package cmd

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/agentlog"
	"watchtower/internal/db"
)

var agentsCmd = &cobra.Command{Use: "agents", Short: "Analytics of the coding-agent sessions run in a workbench"}

var (
	flagAgentsWorkbench int64
	flagAgentsJSON      bool
	// agentsClaudeDir is a test seam; ~/.claude, never CLAUDE_CONFIG_DIR.
	agentsClaudeDir = agentlog.DefaultClaudeDir
)

func init() {
	for _, c := range []*cobra.Command{
		{Use: "enable", Short: "Turn analytics on for a workbench and load its history now", RunE: runAgentsEnable},
		{Use: "disable", Short: "Turn analytics off (stored metrics stay)", RunE: runAgentsDisable},
		{Use: "scan", Short: "Read new transcript lines into the analytics tables", RunE: runAgentsScan},
		{Use: "stats", Short: "Totals for a workbench's agent sessions", RunE: runAgentsStats},
	} {
		c.Flags().Int64Var(&flagAgentsWorkbench, "workbench", 0, "workbench id")
		c.Flags().BoolVar(&flagAgentsJSON, "json", false, "print JSON")
		_ = c.MarkFlagRequired("workbench")
		agentsCmd.AddCommand(c)
	}
	rootCmd.AddCommand(agentsCmd)
}

func runAgentsEnable(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	// FEAT-03 exception (ask #153): enabling loads history at once.
	if err := database.SetWorkbenchAgentAnalytics(flagAgentsWorkbench, true); err != nil {
		return err
	}
	return printAgentsScan(cmd, database)
}

func runAgentsDisable(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := database.SetWorkbenchAgentAnalytics(flagAgentsWorkbench, false); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Agent analytics is off for workbench %d; stored metrics stay.\n", flagAgentsWorkbench)
	return nil
}

func runAgentsScan(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	on, err := database.WorkbenchAgentAnalytics(flagAgentsWorkbench)
	if err != nil {
		return err
	}
	if !on {
		return errors.New("agent analytics is off for this workbench (watchtower agents enable --workbench N)")
	}
	return printAgentsScan(cmd, database)
}

func printAgentsScan(cmd *cobra.Command, database *db.DB) error {
	res, err := agentlog.Scan(cmd.Context(), database, flagAgentsWorkbench, agentlog.Options{ClaudeDir: agentsClaudeDir()})
	if err != nil {
		return err
	}
	if flagAgentsJSON {
		return writeJSON(cmd, res)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%d sessions, %d files read, %d unchanged, %d events written",
		res.Sessions, res.FilesScanned, res.FilesSkipped, res.EventsWritten)
	if n := len(res.UnknownRecords); n > 0 {
		fmt.Fprintf(cmd.OutOrStdout(), ", %d unknown record types", n)
	}
	fmt.Fprintln(cmd.OutOrStdout())
	return nil
}

type agentsStatsJSON struct {
	WorkbenchID int64 `json:"workbench_id"`
	Enabled     bool  `json:"enabled"`
	*db.AgentLogStats
}

func runAgentsStats(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	on, err := database.WorkbenchAgentAnalytics(flagAgentsWorkbench)
	if err != nil {
		return err
	}
	st, err := database.AgentLogStats(flagAgentsWorkbench)
	if err != nil {
		return err
	}
	if flagAgentsJSON {
		return writeJSON(cmd, agentsStatsJSON{WorkbenchID: flagAgentsWorkbench, Enabled: on, AgentLogStats: st})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%d sessions · $%.2f (Claude Code reports $%.2f) · %d owner turns\n",
		st.Sessions, st.CostUSD, st.ReportedCostUSD, st.OwnerTurns)
	return nil
}

func writeJSON(cmd *cobra.Command, v any) error {
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
```

If `cmd` already has a JSON-printing helper with another name, use it instead of adding `writeJSON` (grep `func.*JSON(cmd` first). The pinned key test expects `"sessions": 1` formatting — keep `SetIndent("", "  ")`.

- [ ] **Step 4: Run** `go test ./cmd -run TestAgents -v` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `git add cmd/agents*.go && git commit -m "feat(agentlog): watchtower agents enable/disable/scan/stats"`

---

### Task 8: Daemon phase

**Files:**
- Create: `internal/daemon/agent_analytics.go`
- Modify: `internal/daemon/daemon.go` (call after `d.phaseExternalSync(ctx)`, line ~454)
- Test: `internal/daemon/agent_analytics_test.go`

**Interfaces:**
- Consumes: `db.AgentAnalyticsWorkbenchIDs`, `agentlog.Scan`, `d.trackedPipelineRun`, `isBenignShutdownErr`.
- Produces: `func (d *Daemon) phaseAgentAnalytics(ctx context.Context)`; package var `agentAnalyticsClaudeDir = agentlog.DefaultClaudeDir`.

- [ ] **Step 1: Write failing tests** — follow the existing `TestPhaseExternalSync_DisabledWritesNothing` setup in `internal/daemon` (find it with `grep -rn DisabledWritesNothing internal/daemon`), and add:

```go
func TestPhaseAgentAnalytics_InertWithoutEnabledWorkbench(t *testing.T) {
	d := newTestDaemonWithDB(t) // the helper the DisabledWritesNothing test uses
	d.phaseAgentAnalytics(context.Background())
	var n int
	require.NoError(t, d.db.QueryRow(`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'agent-analytics'`).Scan(&n))
	assert.Zero(t, n)
}

func TestPhaseAgentAnalytics_ScansEnabledWorkbench(t *testing.T) {
	d := newTestDaemonWithDB(t)
	folder, _ := filepath.EvalSymlinks(t.TempDir())
	wb, err := d.db.CreateWorkbench("app", folder)
	require.NoError(t, err)
	require.NoError(t, d.db.SetWorkbenchAgentAnalytics(wb, true))
	claude := t.TempDir()
	prev := agentAnalyticsClaudeDir
	agentAnalyticsClaudeDir = func() string { return claude }
	t.Cleanup(func() { agentAnalyticsClaudeDir = prev })
	dir := filepath.Join(claude, "projects", agentlog.Slug(folder))
	require.NoError(t, os.MkdirAll(dir, 0o755))
	rec := `{"type":"assistant","sessionId":"s1","uuid":"u1","timestamp":"2026-10-01T10:00:00Z","cwd":"` + folder +
		`","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","role":"assistant","content":[],"usage":{"input_tokens":1,"output_tokens":1}}}` + "\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "s1.jsonl"), []byte(rec), 0o600))
	d.phaseAgentAnalytics(context.Background())
	var n int
	require.NoError(t, d.db.QueryRow(`SELECT COUNT(*) FROM agent_log_events`).Scan(&n))
	assert.Equal(t, 1, n)
}
```

Adapt the helper name and the `pipeline_runs` column name to what the existing test uses; keep both assertions.

- [ ] **Step 2: Run** `go test ./internal/daemon -run TestPhaseAgentAnalytics -v` → FAIL.

- [ ] **Step 3: Implement**

```go
package daemon

import (
	"context"
	"errors"
	"time"

	"watchtower/internal/agentlog"
)

// agentAnalyticsBudget bounds one cycle; a big first backfill normally ran
// already in `agents enable`, so this only catches up new lines.
const agentAnalyticsBudget = 30 * time.Second

var agentAnalyticsClaudeDir = agentlog.DefaultClaudeDir

// phaseAgentAnalytics keeps agent_log_* current for every workbench with
// agent_analytics = 1. Inert (no pipeline_runs row) when none is enabled —
// gated by the workbench column, not a config key (FEAT-01 note).
func (d *Daemon) phaseAgentAnalytics(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	ids, err := d.db.AgentAnalyticsWorkbenchIDs()
	if err != nil {
		d.logger.Printf("agent analytics: listing workbenches: %v", err)
		return
	}
	if len(ids) == 0 {
		return
	}
	d.trackedPipelineRun("agent-analytics", func() pipelineRunStats {
		var items int
		var errs []error
		per := agentAnalyticsBudget / time.Duration(len(ids))
		for _, id := range ids {
			res, err := agentlog.Scan(ctx, d.db, id, agentlog.Options{ClaudeDir: agentAnalyticsClaudeDir(), Budget: per})
			if err != nil {
				if isBenignShutdownErr(ctx, err) {
					break
				}
				d.logger.Printf("agent analytics: workbench %d: %v", id, err)
				errs = append(errs, err)
				continue
			}
			items += res.EventsWritten
			if res.Incomplete {
				d.logger.Printf("agent analytics: workbench %d: cycle budget reached, continuing next cycle", id)
			}
		}
		return pipelineRunStats{items: items, err: errors.Join(errs...)}
	})
}
```

In `daemon.go`, after `d.phaseExternalSync(ctx)` add `d.phaseAgentAnalytics(ctx)`.

- [ ] **Step 4: Run** `go test ./internal/daemon -run TestPhaseAgentAnalytics -v` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `git add internal/daemon && git commit -m "feat(agentlog): incremental daemon phase"`

---

### Task 9: Contracts, feature note, inventory amendments

**Files:**
- Create: `docs/inventory/agent-analytics.md`, `docs/features/agent-analytics.md`
- Modify: `docs/inventory/README.md` (module → file row for `internal/agentlog`, `cmd/agents.go`), `docs/inventory/workbench.md` (PROJ-02 amendment + guard note), `docs/inventory/features.md` (changelog: FEAT-03 exception, FEAT-01 phase note), `CLAUDE.md` (Feature Notes line)

- [ ] **Step 1: Write `docs/inventory/agent-analytics.md`** in the house format (copy the heading/Status/Observable/Test guards/Locked since structure from `docs/inventory/plan-usage.md`) with:
  - **AGENTLOG-01 No transcript text** — guards `internal/agentlog/claude_test.go::TestParseClaude_StoresNoText`, `claude_tools_test.go::TestParseClaude_ToolPairingOutcomesAndTargets`.
  - **AGENTLOG-02 Each API call counts once** — guards `TestParseClaude_StreamingChunksFoldIntoOneCall`, `internal/db/agent_log_test.go::TestApplyAgentLogBatch_ReplayOwnedByEarliestSession`, `TestApplyAgentLogBatch_SubagentReplaySkipped`, `scan_test.go::TestScan_ForkReplayCountsOnceInEitherOrder`, `TestScan_SubagentReplayOfParentSkipped`, `TestScan_ConcurrentWritersCountOnce`.
  - **AGENTLOG-03 Metrics outlive their source** — guards `TestScan_DeletedFileKeepsRowsAndParserBumpRereadsPresentOnly`, `TestScan_ShrunkFileReparsedWithoutDuplicates`, `TestAgentLog_SurvivesWorkbenchDeleteAndIsAdopted`, `cmd/agents_test.go::TestAgentsDisable_KeepsRows`.
  - **AGENTLOG-04 Only the workbench's transcripts are read** — guards `TestCandidateDirs_PrefixOnlyAndNoSymlinks`, `TestScan_UnrelatedProjectNeverOpened`, `TestScan_NestedWorkbenchesLongestWins`.
  - **AGENTLOG-05 Read-only on the agent's files** — Observable only (no write call exists under `internal/agentlog` on transcript paths; reviewers check `os.OpenFile`/`os.Create`/`os.Remove` usage stays absent there). Status: Enforced by review.
  - Changelog: `2026-10-15 (board #297): file created, AGENTLOG-01..05.`
- [ ] **Step 2: Amend PROJ-02** in `docs/inventory/workbench.md`: add "amended 2026-10-15 for agent analytics, owner approved in ask #153, board #297" to the Status line; in Observable add one sentence: "Agent analytics rows (`agent_log_sessions`/`agent_log_events`, migration `00116`) are the one exception: they outlive the workbench with `project_id` NULL (and `terminal_session_id` NULL) and are adopted by a workbench later created on the same folder." Append to the guard bullet of `TestProj02_DeleteProjectLeavesNoRows`: "since 2026-10-15, board #297, an agent analytics session of it survives with `project_id` NULL — assertion added, none relaxed".
- [ ] **Step 3: Amend `docs/inventory/features.md` changelog:** `2026-10-15 (agent analytics, board #297): not a registry feature — enabled per workbench (projects.agent_analytics) by watchtower agents enable, which loads the folder's transcript history at once; owner approved this FEAT-03 exception in ask #153 (no AI calls, local files only). phaseAgentAnalytics joins FEAT-01's phase list as gated by that column, inert with no enabled workbench (TestPhaseAgentAnalytics_InertWithoutEnabledWorkbench). No contract text weakened, no guard relaxed.`
- [ ] **Step 4: Write `docs/features/agent-analytics.md`** — sections: Purpose and the #296 roadmap; Data source (Claude Code JSONL layout, the fields read, the slug rule); Tables and the view; Dedupe and ownership rules; Cost (price table, `PriceVersion`, reprice, estimated flag, `reported_cost_usd` cross-check); Running it (CLI, daemon phase, budgets); v1 limits (Claude only — Codex next; `~/.claude` only, no `CLAUDE_CONFIG_DIR`; no UI; no hooks; analytics survive workbench delete); Contracts AGENTLOG-01..05 and the PROJ-02/FEAT-03 notes. Then add a Feature Notes line to `CLAUDE.md` after the "Claude plan limits" line:
  `- [Agent analytics — ingest core (2026-10-15, board #296/#297; #298–#300 pending)](docs/features/agent-analytics.md) — \`internal/agentlog\` Claude Code transcript parser (slug discovery + home-cwd ownership, longest folder wins), migration 00116 \`agent_log_files\`/\`agent_log_sessions\`/\`agent_log_events\` + \`agent_log_session_totals\` view + \`projects.agent_analytics\`, dedupe on \`message.id:requestId\` with earliest-session ownership, cost at ingest with \`PriceVersion\` reprice, \`watchtower agents enable|disable|scan|stats\`, \`phaseAgentAnalytics\`; AGENTLOG-01..05, PROJ-02 exception and FEAT-03 exception (ask #153).`
- [ ] **Step 5: Verify** `make lint-diff` (docs only — also run `go test ./internal/db -run TestProj02` to make sure the guard text matches the test). Commit: `git add docs CLAUDE.md && git commit -m "docs(agentlog): contracts, feature note, PROJ-02 and FEAT-03 amendments"`

---

## Phase gate (controller, once, before the PR)

`bash scripts/dev-health.sh`, then `make test`, `make lint-all`, `go test -race ./internal/agentlog ./internal/db -run 'Agent|Scan|Parse'`. No Swift sources change except the generated test schema; run `make test-swift FILTER=TestDatabase` once to confirm it still compiles.
