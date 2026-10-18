package db

import (
	"database/sql"
	"fmt"
)

// StatusChange is one target_status_history row: the status entered and when.
type StatusChange struct{ To, At string }

// AgentReportTarget is a workbench board target with its status history,
// oldest change first.
type AgentReportTarget struct {
	ID       int64
	ParentID *int64
	Text     string
	Status   string
	History  []StatusChange
}

// AgentReportTargets lists a workbench's targets by id with their status history.
func (db *DB) AgentReportTargets(projectID int64) ([]AgentReportTarget, error) {
	out := []AgentReportTarget{}
	byID := map[int64]int{}
	err := db.eachRow(`SELECT id, parent_id, text, status FROM targets WHERE project_id = ? ORDER BY id`,
		[]any{projectID}, func(r *sql.Rows) error {
			var t AgentReportTarget
			var parent sql.NullInt64
			if err := r.Scan(&t.ID, &parent, &t.Text, &t.Status); err != nil {
				return err
			}
			if parent.Valid {
				t.ParentID = &parent.Int64
			}
			byID[t.ID] = len(out)
			out = append(out, t)
			return nil
		})
	if err != nil {
		return nil, fmt.Errorf("agent report targets: %w", err)
	}
	err = db.eachRow(`SELECT h.target_id, h.to_status, h.changed_at
		FROM target_status_history h JOIN targets t ON t.id = h.target_id
		WHERE t.project_id = ? ORDER BY h.target_id, h.changed_at, h.id`,
		[]any{projectID}, func(r *sql.Rows) error {
			var id int64
			var c StatusChange
			if err := r.Scan(&id, &c.To, &c.At); err != nil {
				return err
			}
			if i, ok := byID[id]; ok {
				out[i].History = append(out[i].History, c)
			}
			return nil
		})
	if err != nil {
		return nil, fmt.Errorf("agent report target history: %w", err)
	}
	return out, nil
}

// eachRow runs q and calls each for every row.
func (db *DB) eachRow(q string, args []any, each func(*sql.Rows) error) error {
	rows, err := db.Query(q, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := each(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}
