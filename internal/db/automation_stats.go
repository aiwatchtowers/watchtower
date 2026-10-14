package db

import (
	"fmt"
	"time"
)

// AutomationRunStats is what `automations list` shows of one automation's
// runs: the status of its newest run ("" when it never ran) and the tokens
// its runs started since a moment used.
type AutomationRunStats struct {
	LastStatus  string
	TokensSince int64
}

// AutomationRunStatsSince returns, per automation that has a run, the status
// of its newest run (highest id) and the input+output tokens of its runs
// whose started_at is at or after since. Automations without a run are not
// in the map.
func (db *DB) AutomationRunStatsSince(since time.Time) (map[int64]AutomationRunStats, error) {
	rows, err := db.Query(`SELECT r.automation_id,
			(SELECT l.status FROM automation_runs l WHERE l.automation_id = r.automation_id ORDER BY l.id DESC LIMIT 1),
			COALESCE(SUM(CASE WHEN r.started_at >= ? THEN r.input_tokens + r.output_tokens ELSE 0 END), 0)
		FROM automation_runs r GROUP BY r.automation_id`, formatAutomationTime(since))
	if err != nil {
		return nil, fmt.Errorf("reading automation run stats: %w", err)
	}
	defer rows.Close()
	out := map[int64]AutomationRunStats{}
	for rows.Next() {
		var (
			id int64
			s  AutomationRunStats
		)
		if err := rows.Scan(&id, &s.LastStatus, &s.TokensSince); err != nil {
			return nil, fmt.Errorf("reading automation run stats: %w", err)
		}
		out[id] = s
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading automation run stats: %w", err)
	}
	return out, nil
}
