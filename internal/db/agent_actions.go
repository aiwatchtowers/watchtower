package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// AgentAction is one row of agent_actions: a write-tool call the assistant
// made, recorded as a proposal and later decided/executed by the owner's
// Desktop through `watchtower actions …`. Rows are never deleted (audit).
type AgentAction struct {
	ID             int64
	Tool           string
	External       bool
	ArgsJSON       string
	Reason         string
	Surface        string
	ConversationID int64
	ContextType    string
	ContextID      string
	TurnID         string
	Status         string // pending | approved | rejected | applied | failed
	TrustAtCreate  string // ask | execute
	ResultJSON     string
	Error          string
	CreatedAt      string
	DecidedAt      string
	AppliedAt      string
}

// AgentActionFilter narrows ListAgentActions; zero values mean "any".
type AgentActionFilter struct {
	Status         string
	ConversationID int64
	Limit          int
}

const agentActionColumns = `id, tool, external, args_json, reason, surface, conversation_id,
	context_type, context_id, turn_id, status, trust_at_create, result_json, error,
	created_at, decided_at, applied_at`

func scanAgentAction(row interface{ Scan(dest ...any) error }) (*AgentAction, error) {
	var a AgentAction
	err := row.Scan(&a.ID, &a.Tool, &a.External, &a.ArgsJSON, &a.Reason, &a.Surface, &a.ConversationID,
		&a.ContextType, &a.ContextID, &a.TurnID, &a.Status, &a.TrustAtCreate, &a.ResultJSON, &a.Error,
		&a.CreatedAt, &a.DecidedAt, &a.AppliedAt)
	if err != nil {
		return nil, err
	}
	return &a, nil
}

// InsertAgentAction records a proposal. Status defaults to pending and
// trust_at_create to ask unless the caller sets them (the execute path
// inserts as approved).
func (db *DB) InsertAgentAction(a AgentAction) (int64, error) {
	if a.Status == "" {
		a.Status = "pending"
	}
	if a.TrustAtCreate == "" {
		a.TrustAtCreate = "ask"
	}
	res, err := db.Exec(`INSERT INTO agent_actions
		(tool, external, args_json, reason, surface, conversation_id, context_type, context_id,
		 turn_id, status, trust_at_create)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.Tool, a.External, a.ArgsJSON, a.Reason, a.Surface, a.ConversationID, a.ContextType, a.ContextID,
		a.TurnID, a.Status, a.TrustAtCreate)
	if err != nil {
		return 0, fmt.Errorf("inserting agent action: %w", err)
	}
	return res.LastInsertId()
}

// GetAgentAction returns the row or nil when it does not exist.
func (db *DB) GetAgentAction(id int64) (*AgentAction, error) {
	a, err := scanAgentAction(db.QueryRow(`SELECT `+agentActionColumns+` FROM agent_actions WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting agent action %d: %w", id, err)
	}
	return a, nil
}

// ListAgentActions returns rows oldest-first, optionally filtered.
func (db *DB) ListAgentActions(f AgentActionFilter) ([]AgentAction, error) {
	var where []string
	var args []any
	if f.Status != "" {
		where = append(where, "status = ?")
		args = append(args, f.Status)
	}
	if f.ConversationID != 0 {
		where = append(where, "conversation_id = ?")
		args = append(args, f.ConversationID)
	}
	q := `SELECT ` + agentActionColumns + ` FROM agent_actions`
	if len(where) > 0 {
		q += " WHERE " + strings.Join(where, " AND ")
	}
	q += " ORDER BY created_at ASC, id ASC"
	if f.Limit > 0 {
		q += fmt.Sprintf(" LIMIT %d", f.Limit)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing agent actions: %w", err)
	}
	defer rows.Close()
	var out []AgentAction
	for rows.Next() {
		a, err := scanAgentAction(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning agent action: %w", err)
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

// TransitionAgentAction moves a row to `to` only when its current status is
// one of `from`; it returns false when the row was in another state (or does
// not exist), which is how callers detect a lost race or a bad transition.
// decided_at is stamped for approved/rejected, applied_at for applied/failed.
func (db *DB) TransitionAgentAction(id int64, from []string, to, resultJSON, errMsg string) (bool, error) {
	if len(from) == 0 {
		return false, fmt.Errorf("transition to %s: no source statuses", to)
	}
	now := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	decided, applied := "", ""
	switch to {
	case "approved", "rejected":
		decided = now
	case "applied", "failed":
		applied = now
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(from)), ",")
	args := []any{to, resultJSON, errMsg, decided, decided, applied, applied, id}
	for _, s := range from {
		args = append(args, s)
	}
	res, err := db.Exec(`UPDATE agent_actions SET status = ?, result_json = ?, error = ?,
		decided_at = CASE WHEN ? != '' THEN ? ELSE decided_at END,
		applied_at = CASE WHEN ? != '' THEN ? ELSE applied_at END
		WHERE id = ? AND status IN (`+placeholders+`)`, args...)
	if err != nil {
		return false, fmt.Errorf("transitioning agent action %d to %s: %w", id, to, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// GetToolTrust returns "ask" when no row exists.
func (db *DB) GetToolTrust(tool string) (string, error) {
	var trust string
	err := db.QueryRow(`SELECT trust FROM tool_trust WHERE tool = ?`, tool).Scan(&trust)
	if errors.Is(err, sql.ErrNoRows) {
		return "ask", nil
	}
	if err != nil {
		return "", fmt.Errorf("getting trust for %s: %w", tool, err)
	}
	return trust, nil
}

// SetToolTrust upserts the trust level. The registry, not this function,
// enforces the external-never-execute rule (AGENT-03).
func (db *DB) SetToolTrust(tool, trust string) error {
	_, err := db.Exec(`INSERT INTO tool_trust (tool, trust, updated_at)
		VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
		ON CONFLICT(tool) DO UPDATE SET trust = excluded.trust, updated_at = excluded.updated_at`, tool, trust)
	if err != nil {
		return fmt.Errorf("setting trust for %s: %w", tool, err)
	}
	return nil
}
