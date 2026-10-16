package db

import (
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
// (terminal_session_agent_sessions, migration 00124) is filled by triggers on
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
