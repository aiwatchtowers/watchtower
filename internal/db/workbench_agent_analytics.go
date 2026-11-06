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
	return db.terminalSessionIDs("claude", uuids)
}

// CodexTerminalSessionIDs is ClaudeTerminalSessionIDs for codex rows (ask
// #507, decision D).
func (db *DB) CodexTerminalSessionIDs(uuids []string) (map[string]int64, error) {
	return db.terminalSessionIDs("codex", uuids)
}

// terminalSessionIDs maps each uuid to the oldest terminal session of kind
// that recorded it as its agent session id.
func (db *DB) terminalSessionIDs(kind string, uuids []string) (map[string]int64, error) {
	out := map[string]int64{}
	for _, u := range uuids {
		var id int64
		err := db.QueryRow(`SELECT id FROM terminal_sessions WHERE claude_session_id = ? AND kind = ? ORDER BY id LIMIT 1`, u, kind).Scan(&id)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("resolving %s terminal session of %s: %w", kind, u, err)
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

// WorkbenchCodexSessions lists the workbench's codex sessions, one per codex
// session id (a resumed session can have several rows; the stored path of
// any of them counts), oldest first: the only codex sessions agent analytics
// reads rollouts for (AGENTLOG-04). A plain read, no transaction.
func (db *DB) WorkbenchCodexSessions(workbenchID int64) ([]CodexAnalyticsRow, error) {
	rows, err := db.Query(`SELECT MIN(id), claude_session_id, COALESCE(MAX(agent_transcript_path), '') FROM terminal_sessions
		WHERE project_id = ? AND kind = 'codex' AND COALESCE(claude_session_id, '') <> ''
		GROUP BY claude_session_id ORDER BY MIN(id)`, workbenchID)
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
