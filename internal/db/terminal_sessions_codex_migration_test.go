package db

import (
	"database/sql"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const codexMigration = 109

// codexTestUUID is a placeholder Codex session id (lowercase UUIDv7 shape).
const codexTestUUID = "01890a5d-ac96-7a3b-8c4d-5e6f7a8b9c0d"

// codexDumpRows renders every row query returns as one line per row, NULL
// spelled out, so two dumps compare byte for byte.
func codexDumpRows(t *testing.T, raw *sql.DB, query string) []string {
	t.Helper()
	rows, err := raw.Query(query)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		parts := make([]string, len(cols))
		for i, v := range vals {
			if v == nil {
				parts[i] = cols[i] + "=NULL"
			} else {
				parts[i] = fmt.Sprintf("%s=%v", cols[i], v)
			}
		}
		out = append(out, strings.Join(parts, "|"))
	}
	require.NoError(t, rows.Err())
	return out
}

// terminalSessionIndexes lists terminal_sessions' own indexes with their SQL.
func terminalSessionIndexes(t *testing.T, raw *sql.DB) []string {
	t.Helper()
	return codexDumpRows(t, raw, `SELECT name, sql FROM sqlite_master WHERE type = 'index'
		AND tbl_name = 'terminal_sessions' AND name NOT LIKE 'sqlite_autoindex%' ORDER BY name`)
}

// pre109SessionCols is the terminal_sessions column list before 00109.
const pre109SessionCols = `id, project_id, kind, title, title_source, target_id, folder_path,
	claude_session_id, created_at, last_active_at, closed_at, agent_state, agent_state_at, finished_at,
	finish_summary, agent_failed_at, agent_error, agent_turn_end, agent_tool_run, agent_background,
	agent_background_at, chat_question, chat_question_at, agent_turns`

// childDumps is every row that points at terminal_sessions, plus the
// sessions themselves (pre-00109 columns).
func childDumps(t *testing.T, raw *sql.DB) map[string][]string {
	t.Helper()
	return map[string][]string{
		"terminal_sessions":        codexDumpRows(t, raw, `SELECT `+pre109SessionCols+` FROM terminal_sessions ORDER BY id`),
		"owner_asks":               codexDumpRows(t, raw, `SELECT * FROM owner_asks ORDER BY id`),
		"terminal_session_targets": codexDumpRows(t, raw, `SELECT * FROM terminal_session_targets ORDER BY session_id, target_id`),
		"owner_presence":           codexDumpRows(t, raw, `SELECT * FROM owner_presence`),
	}
}

// seedPre109Sessions plants a workbench with a fully populated claude row
// (id 10), a shell row (id 11), a target, an ask and a target link on each
// session, and the owner's presence on the claude row.
func seedPre109Sessions(t *testing.T, raw *sql.DB) {
	t.Helper()
	now := time.Now().UTC()
	stamp := AgentStateStamp(now)
	day := now.Format("2006-01-02")
	secs := now.Format("2006-01-02T15:04:05Z")
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/Users/example/acme')`, nil},
		{`INSERT INTO targets (id, text, period_start, period_end, project_id) VALUES (5, 't', ?, ?, 1)`,
			[]any{day, day}},
		{`INSERT INTO terminal_sessions (id, project_id, kind, title, title_source, target_id, folder_path,
			claude_session_id, closed_at, agent_state, agent_state_at, finished_at, finish_summary,
			agent_failed_at, agent_error, agent_turn_end, agent_tool_run, agent_background,
			agent_background_at, chat_question, chat_question_at, agent_turns)
			VALUES (10, 1, 'claude', 'agent', 'ai', 5, '/Users/example/acme', ?, ?, 'waiting', ?, ?, 'done',
			?, 'overloaded', 1234, 1, 2, ?, '{"question":"Q","options":[]}', ?, '{"since":"x","turns":{}}')`,
			[]any{agentStateUUID, secs, stamp, stamp, stamp, stamp, stamp}},
		{`INSERT INTO terminal_sessions (id, project_id, kind, title, folder_path) VALUES (11, 1, 'shell', 'sh', '/Users/example/acme')`, nil},
		{`INSERT INTO owner_asks (id, project_id, session_id, kind, title) VALUES (1, 1, 10, 'question', 'q1')`, nil},
		{`INSERT INTO owner_asks (id, project_id, session_id, kind, title) VALUES (2, 1, 11, 'check', 'c1')`, nil},
		{`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (10, 5, ?, ?)`,
			[]any{secs, secs}},
		{`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (11, 5, ?, ?)`,
			[]any{secs, secs}},
		{`INSERT INTO owner_presence (id, session_id, seen_at) VALUES (1, 10, ?)`, []any{stamp}},
	} {
		_, err := raw.Exec(q.sql, q.args...)
		require.NoError(t, err, q.sql)
	}
}

func TestMigrationCodex_KindCheckAcceptsCodexWithNullID(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "codex", nil)
	s := storedSession(t, d, id)
	assert.Equal(t, "codex", s.Kind)
	assert.False(t, s.ClaudeSessionID.Valid)
	assert.False(t, s.TranscriptPath.Valid)
	// A codex row may also hold an id, and an unknown kind is still refused.
	newAgentStateRow(t, d, pid, "codex", codexTestUUID)
	_, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'gemini', 's', '/tmp/acme', ?)`, pid, codexTestUUID)
	assert.Error(t, err, "the kind CHECK accepted an unknown kind")
}

func TestMigrationCodex_ClaudeStillNeedsAnID(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	_, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path)
		VALUES (?, 'claude', 's', '/tmp/acme')`, pid)
	require.Error(t, err, "a claude row with a NULL id passed the CHECK")
	assert.Contains(t, err.Error(), "CHECK")
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	_, err = d.Exec(`UPDATE terminal_sessions SET claude_session_id = NULL WHERE id = ?`, id)
	assert.Error(t, err, "an update NULLed a claude row's id")
	newAgentStateRow(t, d, pid, "shell", nil)
}

func TestMigrationCodex_RebuildKeepsRowsAndChildren(t *testing.T) {
	t.Parallel()
	raw := rawDBAt(t, codexMigration-1)
	seedPre109Sessions(t, raw)
	before := childDumps(t, raw)

	require.NoError(t, goose.UpTo(raw, "migrations", codexMigration))

	var fk int
	require.NoError(t, raw.QueryRow(`PRAGMA foreign_keys`).Scan(&fk))
	assert.Equal(t, 1, fk, "the migration turns foreign keys back on")
	assert.Equal(t, before, childDumps(t, raw), "every session and child row is identical")
	assert.Len(t, before["owner_asks"], 2)
	assert.Len(t, before["terminal_session_targets"], 2)
	var presence sql.NullInt64
	require.NoError(t, raw.QueryRow(`SELECT session_id FROM owner_presence WHERE id = 1`).Scan(&presence))
	assert.Equal(t, sql.NullInt64{Int64: 10, Valid: true}, presence)
	var path sql.NullString
	require.NoError(t, raw.QueryRow(`SELECT agent_transcript_path FROM terminal_sessions WHERE id = 10`).Scan(&path))
	assert.False(t, path.Valid, "the new column starts NULL")
	assertSessionFKsWork(t, raw)
}

// assertSessionFKsWork: the children still reference the rebuilt table, so
// deleting a session cascades its links and detaches its asks and presence.
func assertSessionFKsWork(t *testing.T, raw *sql.DB) {
	t.Helper()
	var violations int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM pragma_foreign_key_check`).Scan(&violations))
	assert.Zero(t, violations)
	_, err := raw.Exec(`DELETE FROM terminal_sessions WHERE id = 10`)
	require.NoError(t, err)
	var links int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM terminal_session_targets WHERE session_id = 10`).Scan(&links))
	assert.Zero(t, links, "the link cascaded")
	var ask, presence sql.NullInt64
	require.NoError(t, raw.QueryRow(`SELECT session_id FROM owner_asks WHERE id = 1`).Scan(&ask))
	assert.False(t, ask.Valid, "the ask detached")
	require.NoError(t, raw.QueryRow(`SELECT session_id FROM owner_presence WHERE id = 1`).Scan(&presence))
	assert.False(t, presence.Valid, "the presence detached")
}

func TestMigrationCodex_IndexesRecreated(t *testing.T) {
	t.Parallel()
	raw := rawDBAt(t, codexMigration-1)
	before := terminalSessionIndexes(t, raw)
	require.Len(t, before, 2)
	require.NoError(t, goose.UpTo(raw, "migrations", codexMigration))
	assert.Equal(t, before, terminalSessionIndexes(t, raw))
	require.NoError(t, goose.DownTo(raw, "migrations", codexMigration-1))
	assert.Equal(t, before, terminalSessionIndexes(t, raw), "Down recreates them too")
}

func TestMigrationCodex_DownDropsCodexRowsAndColumn(t *testing.T) {
	t.Parallel()
	raw := rawDBAt(t, codexMigration-1)
	seedPre109Sessions(t, raw)
	before := childDumps(t, raw)
	require.NoError(t, goose.UpTo(raw, "migrations", codexMigration))
	_, err := raw.Exec(`INSERT INTO terminal_sessions (id, project_id, kind, title, folder_path, claude_session_id,
		agent_transcript_path) VALUES (20, 1, 'codex', 'cx', '/Users/example/acme', ?, '/Users/example/r.jsonl')`, codexTestUUID)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO terminal_sessions (id, project_id, kind, title, folder_path) VALUES (21, 1, 'codex', 'cx2', '/Users/example/acme')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO owner_asks (id, project_id, session_id, kind, title) VALUES (3, 1, 20, 'question', 'q2')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (20, 5, 'a', 'b')`)
	require.NoError(t, err)

	require.NoError(t, goose.DownTo(raw, "migrations", codexMigration-1))

	assert.False(t, columnNames(t, raw, "terminal_sessions")["agent_transcript_path"])
	var codex int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM terminal_sessions WHERE kind = 'codex'`).Scan(&codex))
	assert.Zero(t, codex, "Down deletes the codex rows")
	after := childDumps(t, raw)
	assert.Equal(t, before["terminal_sessions"], after["terminal_sessions"], "claude and shell rows survive")
	assert.Equal(t, before["terminal_session_targets"], after["terminal_session_targets"], "only the codex link went")
	assert.Equal(t, before["owner_presence"], after["owner_presence"])
	var askSession sql.NullInt64
	require.NoError(t, raw.QueryRow(`SELECT session_id FROM owner_asks WHERE id = 3`).Scan(&askSession))
	assert.False(t, askSession.Valid, "the codex row's ask detached, as for any deleted session")
	_, err = raw.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (1, 'codex', 'x', '/tmp')`)
	assert.Error(t, err, "the 00108 CHECK has no codex")

	require.NoError(t, goose.UpTo(raw, "migrations", codexMigration))
	assert.True(t, columnNames(t, raw, "terminal_sessions")["agent_transcript_path"])
	assert.Equal(t, before["terminal_sessions"], childDumps(t, raw)["terminal_sessions"])
}

// The readers that open a database without migrating it read a claude row
// of a 00108 database: GetTerminalSession needs agent_transcript_path only
// for a codex row, which a 00108 database cannot hold.
func TestGetTerminalSessionNeedsNoTranscriptPathColumnForClaude(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	_, err := d.Exec(`ALTER TABLE terminal_sessions DROP COLUMN agent_transcript_path`)
	require.NoError(t, err)
	s, err := d.GetTerminalSession(id)
	require.NoError(t, err, "GetTerminalSession on a 00108 schema")
	assert.False(t, s.TranscriptPath.Valid)
}
