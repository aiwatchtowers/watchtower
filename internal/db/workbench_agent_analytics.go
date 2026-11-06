package db

import (
	"database/sql"
	"errors"
	"fmt"
)

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

// ClaudeTerminalSessionIDs maps each of uuids that a Claude terminal session
// recorded as its claude_session_id to that session's id; a uuid without one
// is absent. A plain read, no transaction: agent analytics resolve
// agent_log_sessions.terminal_session_id with it outside agentlog.db's write.
func (db *DB) ClaudeTerminalSessionIDs(uuids []string) (map[string]int64, error) {
	return db.terminalSessionIDs(`SELECT id FROM terminal_sessions WHERE claude_session_id = ? AND kind = 'claude' ORDER BY id LIMIT 1`, uuids)
}

// CodexTerminalSessionIDs is ClaudeTerminalSessionIDs for codex rows (ask
// #507, decision D), through the agent session ledger
// (terminal_session_agent_sessions): a codex tab keeps the conversations it
// had before a /clear or a resume switched its current id.
func (db *DB) CodexTerminalSessionIDs(uuids []string) (map[string]int64, error) {
	return db.terminalSessionIDs(`SELECT ts.id FROM terminal_session_agent_sessions a
		JOIN terminal_sessions ts ON ts.id = a.terminal_session_id
		WHERE a.agent_session_id = ? AND ts.kind = 'codex' ORDER BY ts.id LIMIT 1`, uuids)
}

// terminalSessionIDs maps each uuid to the terminal session id query (one
// placeholder: the uuid) returns for it.
func (db *DB) terminalSessionIDs(query string, uuids []string) (map[string]int64, error) {
	out := map[string]int64{}
	for _, u := range uuids {
		var id int64
		err := db.QueryRow(query, u).Scan(&id)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("resolving terminal session of %s: %w", u, err)
		}
		out[u] = id
	}
	return out, nil
}

// CodexAnalyticsRow is one codex session of a workbench: the oldest terminal
// session row that runs it, its codex session id and the rollout path a
// SessionStart stored ("" = none).
type CodexAnalyticsRow struct {
	ID             int64
	SessionID      string
	TranscriptPath string
}

// WorkbenchCodexSessions lists the workbench's codex sessions: every
// conversation id its codex tabs have had (the agent session ledger, so one
// a /clear or a resume replaced still counts), one per id, oldest row first:
// the only codex sessions agent analytics reads rollouts for (AGENTLOG-04).
// TranscriptPath is the stored path of a row whose current id it is (it
// belongs to that conversation only). A plain read, no transaction.
func (db *DB) WorkbenchCodexSessions(workbenchID int64) ([]CodexAnalyticsRow, error) {
	rows, err := db.Query(`SELECT MIN(ts.id), a.agent_session_id,
			COALESCE(MIN(CASE WHEN ts.claude_session_id = a.agent_session_id THEN ts.agent_transcript_path END), '')
		FROM terminal_session_agent_sessions a JOIN terminal_sessions ts ON ts.id = a.terminal_session_id
		WHERE ts.project_id = ? AND ts.kind = 'codex' AND a.agent_session_id <> ''
		GROUP BY a.agent_session_id ORDER BY MIN(ts.id), a.agent_session_id`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("listing codex sessions of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []CodexAnalyticsRow
	for rows.Next() {
		var r CodexAnalyticsRow
		if err := rows.Scan(&r.ID, &r.SessionID, &r.TranscriptPath); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
