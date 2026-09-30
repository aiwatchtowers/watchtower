package db

import (
	"database/sql"
	"fmt"
	"slices"
)

// Status actors (targets.status_actor, target_status_history.actor,
// migration 00086). A writer of a project target's status claims one in the
// same UPDATE; the history trigger copies it and clears the claim again. An
// unclaimed write is recorded as ActorOwner.
const (
	ActorAgent  = "agent"  // the project MCP tools (watchtower mcp --project N)
	ActorOwner  = "owner"  // the Desktop, the CLI
	ActorSystem = "system" // the rollup triggers (PROJ-05), unsnooze, the Jira status sync
)

// MaxStatusHistory caps the history a reader returns for one target.
const MaxStatusHistory = 50

// TargetStatusChange is one row of target_status_history: a project target
// moved from FromStatus ("" at creation) to ToStatus at ChangedAt (UTC
// ISO-8601), by Actor (PROJ-06).
type TargetStatusChange struct {
	ID         int64  `json:"id"`
	TargetID   int64  `json:"target_id"`
	FromStatus string `json:"from_status,omitempty"`
	ToStatus   string `json:"to_status"`
	ChangedAt  string `json:"changed_at"`
	Actor      string `json:"actor"`
}

// GetTargetStatusHistory returns target targetID's newest limit status
// changes (capped at MaxStatusHistory; limit <= 0 means the cap), oldest
// first. A personal target has none.
func (db *DB) GetTargetStatusHistory(targetID int64, limit int) ([]TargetStatusChange, error) {
	if limit <= 0 || limit > MaxStatusHistory {
		limit = MaxStatusHistory
	}
	rows, err := db.Query(`SELECT id, target_id, from_status, to_status, changed_at, actor
		FROM target_status_history WHERE target_id = ?
		ORDER BY id DESC LIMIT ?`, targetID, limit)
	if err != nil {
		return nil, fmt.Errorf("listing status history of target %d: %w", targetID, err)
	}
	defer rows.Close()
	out := []TargetStatusChange{}
	for rows.Next() {
		var c TargetStatusChange
		var from sql.NullString
		if err := rows.Scan(&c.ID, &c.TargetID, &from, &c.ToStatus, &c.ChangedAt, &c.Actor); err != nil {
			return nil, fmt.Errorf("scanning status history: %w", err)
		}
		c.FromStatus = from.String
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing status history of target %d: %w", targetID, err)
	}
	slices.Reverse(out)
	return out, nil
}

// projectStatusSince maps each of project projectID's targets to the time
// it entered its current status: the changed_at of its latest history row
// (by id, the order the triggers wrote them in).
func (db *DB) projectStatusSince(projectID int64) (map[int64]string, error) {
	rows, err := db.Query(`SELECT h.target_id, h.changed_at FROM target_status_history h
		WHERE h.id IN (SELECT MAX(l.id) FROM target_status_history l
		               JOIN targets t ON t.id = l.target_id
		               WHERE t.project_id = ? GROUP BY l.target_id)`, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading board status times: %w", err)
	}
	defer rows.Close()
	out := map[int64]string{}
	for rows.Next() {
		var id int64
		var at string
		if err := rows.Scan(&id, &at); err != nil {
			return nil, fmt.Errorf("scanning board status time: %w", err)
		}
		out[id] = at
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading board status times: %w", err)
	}
	return out, nil
}

// nullableActor turns "" (no claim) into NULL for targets.status_actor.
func nullableActor(actor string) sql.NullString {
	return sql.NullString{String: actor, Valid: actor != ""}
}
