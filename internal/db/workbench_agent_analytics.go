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
	out := map[string]int64{}
	for _, u := range uuids {
		var id int64
		err := db.QueryRow(`SELECT id FROM terminal_sessions WHERE claude_session_id = ? AND kind = 'claude' LIMIT 1`, u).Scan(&id)
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
