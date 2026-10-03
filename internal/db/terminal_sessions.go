package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

var ErrTerminalSessionNotFound = errors.New("terminal session not found")

// agentStateAtLayout is agent_state_at's fixed-width UTC form: string order
// is time order, and the Desktop parses it pinned to UTC.
const agentStateAtLayout = "2006-01-02T15:04:05.000Z"

// TerminalSession is the slice of a terminal_sessions row Go reads; the
// Desktop owns every other column but the agent state, which only the
// workbench hooks write.
type TerminalSession struct {
	ID              int64
	WorkbenchID     sql.NullInt64
	Kind            string
	Title           string
	TitleSource     string
	FolderPath      string
	ClaudeSessionID sql.NullString
	AgentState      sql.NullString
	AgentStateAt    time.Time // zero when never reported
}

func (db *DB) GetTerminalSession(id int64) (*TerminalSession, error) {
	var s TerminalSession
	var stateAt sql.NullString
	err := db.QueryRow(`SELECT id, project_id, kind, title, title_source, folder_path, claude_session_id,
		agent_state, agent_state_at
		FROM terminal_sessions WHERE id = ?`, id).
		Scan(&s.ID, &s.WorkbenchID, &s.Kind, &s.Title, &s.TitleSource, &s.FolderPath, &s.ClaudeSessionID,
			&s.AgentState, &stateAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrTerminalSessionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d: %w", id, err)
	}
	if stateAt.Valid {
		if s.AgentStateAt, err = time.Parse(agentStateAtLayout, stateAt.String); err != nil {
			return nil, fmt.Errorf("reading terminal session %d agent_state_at: %w", id, err)
		}
	}
	return &s, nil
}

// SetTerminalSessionAITitle stores an AI title only over a provisional one:
// an owner rename ('user') and an earlier AI title ('ai') are kept.
func (db *DB) SetTerminalSessionAITitle(id int64, title string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET title = ?, title_source = 'ai'
		WHERE id = ? AND title_source = 'auto'`, title, id)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d title: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d title: %w", id, err)
	}
	return n > 0, nil
}

// SetTerminalClaudeSessionID points project projectID's claude row id at the
// Claude Code conversation it now runs — the SessionStart hook after /clear
// or a resume that switched conversations, so the Desktop's next relaunch
// resumes it. The same column write as the Desktop's
// `TerminalSessionQueries.replaceClaudeSessionID`; false when the row is not
// that project's claude row or already holds sessionID.
func (db *DB) SetTerminalClaudeSessionID(id, projectID int64, sessionID string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET claude_session_id = ?
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id IS NOT ?`,
		sessionID, id, projectID, sessionID)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d claude session id: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d claude session id: %w", id, err)
	}
	return n > 0, nil
}

// SetTerminalAgentState records what workbench workbenchID's claude row id is
// doing, reported by a Claude Code hook of conversation sessionID at at. It
// writes only when the row still runs that conversation (a nested `claude -p`
// that inherited the row's env has another id), the state changes (a repeat
// keeps the transition time), at is later than the stored time (a late async
// hook never overwrites a newer state) and, with onlyFrom set, the stored
// state is onlyFrom. One guarded UPDATE, no transaction; false when a guard
// held it back.
func (db *DB) SetTerminalAgentState(id, workbenchID int64, sessionID, state string, at time.Time, onlyFrom string) (bool, error) {
	stamp := at.UTC().Format(agentStateAtLayout)
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ?
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?
		  AND agent_state IS NOT ?
		  AND (agent_state_at IS NULL OR agent_state_at < ?)
		  AND (? = '' OR agent_state = ?)`,
		state, stamp, id, workbenchID, sessionID, state, stamp, onlyFrom, onlyFrom)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d agent state: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d agent state: %w", id, err)
	}
	return n > 0, nil
}
