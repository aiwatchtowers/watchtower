package db

import (
	"context"
	"fmt"
	"time"
)

// TerminalAgentSession is one agent session id a terminal tab has had.
type TerminalAgentSession struct {
	AgentSessionID string
	FirstSeenAt    time.Time
}

// ListTerminalAgentSessions returns every agent session id the terminal tab
// terminalSessionID has had, oldest first. The ledger
// (terminal_session_agent_sessions, migration 00127) is filled by triggers on
// terminal_sessions, so the row's creation, SetTerminalClaudeSessionID and
// SetTerminalAgentSessionID need no ledger code of their own.
func (db *DB) ListTerminalAgentSessions(terminalSessionID int64) ([]TerminalAgentSession, error) {
	rows, err := db.Query(`SELECT agent_session_id, first_seen_at FROM terminal_session_agent_sessions
		WHERE terminal_session_id = ? ORDER BY first_seen_at, rowid`, terminalSessionID)
	if err != nil {
		return nil, fmt.Errorf("listing agent sessions of terminal session %d: %w", terminalSessionID, err)
	}
	defer func() { _ = rows.Close() }()
	var out []TerminalAgentSession
	for rows.Next() {
		var s TerminalAgentSession
		var at string
		if err := rows.Scan(&s.AgentSessionID, &at); err != nil {
			return nil, fmt.Errorf("scanning agent session of terminal session %d: %w", terminalSessionID, err)
		}
		if s.FirstSeenAt, err = time.Parse(time.RFC3339, at); err != nil {
			return nil, fmt.Errorf("parsing first_seen_at of agent session %s: %w", s.AgentSessionID, err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// AgentSessionIDs is every agent session id the terminal session rowID has
// had: its history in terminal_session_agent_sessions plus its current
// claude_session_id (in the history too unless a trigger missed it),
// deduplicated, sorted. An unknown row has none.
func (db *DB) AgentSessionIDs(ctx context.Context, rowID int64) ([]string, error) {
	rows, err := db.QueryContext(ctx, `SELECT agent_session_id FROM terminal_session_agent_sessions WHERE terminal_session_id = ?
		UNION SELECT claude_session_id FROM terminal_sessions WHERE id = ? AND claude_session_id IS NOT NULL AND claude_session_id <> ''
		ORDER BY 1`, rowID, rowID)
	if err != nil {
		return nil, fmt.Errorf("reading agent session ids of terminal session %d: %w", rowID, err)
	}
	defer func() { _ = rows.Close() }()
	out := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning agent session id of terminal session %d: %w", rowID, err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// AgentSessionIDOwners is every terminal session row whose history or
// current claude_session_id holds uuid, ascending. More than one owner
// means the conversation was resumed in another tab (auto cleanup spec
// 2026-11-10 §2b: such a uuid adopts nothing).
func (db *DB) AgentSessionIDOwners(ctx context.Context, uuid string) ([]int64, error) {
	rows, err := db.QueryContext(ctx, `SELECT terminal_session_id FROM terminal_session_agent_sessions WHERE agent_session_id = ?
		UNION SELECT id FROM terminal_sessions WHERE claude_session_id = ?
		ORDER BY 1`, uuid, uuid)
	if err != nil {
		return nil, fmt.Errorf("reading the owners of agent session %s: %w", uuid, err)
	}
	defer func() { _ = rows.Close() }()
	out := []int64{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning an owner of agent session %s: %w", uuid, err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
