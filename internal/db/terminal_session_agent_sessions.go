package db

import (
	"context"
	"fmt"
	"strings"
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

// AgentSessionID is one agent session id a terminal session row has had and
// Since, when the row acquired it (UTC ISO-8601 seconds, as stored).
type AgentSessionID struct {
	ID, Since string
}

// AgentSessionIDs is every agent session id the terminal session rowID has
// had, by id: its history in terminal_session_agent_sessions with each
// first_seen_at, plus its current claude_session_id at the row's created_at
// when the history lacks it (a pre-00127 gap). An unknown row has none.
func (db *DB) AgentSessionIDs(ctx context.Context, rowID int64) ([]AgentSessionID, error) {
	rows, err := db.QueryContext(ctx, `SELECT agent_session_id, first_seen_at FROM terminal_session_agent_sessions
		WHERE terminal_session_id = ?
		UNION ALL SELECT claude_session_id, created_at FROM terminal_sessions
		WHERE id = ? AND claude_session_id IS NOT NULL AND claude_session_id <> ''
		AND claude_session_id NOT IN (SELECT agent_session_id FROM terminal_session_agent_sessions WHERE terminal_session_id = ?)
		ORDER BY 1`, rowID, rowID, rowID)
	if err != nil {
		return nil, fmt.Errorf("reading agent session ids of terminal session %d: %w", rowID, err)
	}
	defer func() { _ = rows.Close() }()
	out := []AgentSessionID{}
	for rows.Next() {
		var a AgentSessionID
		if err := rows.Scan(&a.ID, &a.Since); err != nil {
			return nil, fmt.Errorf("scanning agent session id of terminal session %d: %w", rowID, err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// AgentSessionIDOwners maps each of uuids to every terminal session row
// whose history or current claude_session_id holds it, ascending; a uuid
// no row holds is absent. A uuid a deleted row had (agent_session_tombstones,
// 00188) also lists owner 0, "a deleted row". One query for all of them.
// More than one owner means the conversation was resumed in another tab, or
// by a row since deleted (auto cleanup spec 2026-11-10 §2b: such a uuid
// adopts nothing).
func (db *DB) AgentSessionIDOwners(ctx context.Context, uuids []string) (map[string][]int64, error) {
	out := map[string][]int64{}
	if len(uuids) == 0 {
		return out, nil
	}
	in := strings.TrimSuffix(strings.Repeat("?,", len(uuids)), ",")
	args := make([]any, 0, 3*len(uuids))
	for range 3 {
		for _, u := range uuids {
			args = append(args, u)
		}
	}
	rows, err := db.QueryContext(ctx, `SELECT agent_session_id, terminal_session_id FROM terminal_session_agent_sessions
		WHERE agent_session_id IN (`+in+`)
		UNION SELECT claude_session_id, id FROM terminal_sessions WHERE claude_session_id IN (`+in+`)
		UNION SELECT agent_session_id, 0 FROM agent_session_tombstones WHERE agent_session_id IN (`+in+`)
		ORDER BY 1, 2`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading the owners of %d agent session ids: %w", len(uuids), err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var u string
		var id int64
		if err := rows.Scan(&u, &id); err != nil {
			return nil, fmt.Errorf("scanning an agent session owner: %w", err)
		}
		out[u] = append(out[u], id)
	}
	return out, rows.Err()
}
