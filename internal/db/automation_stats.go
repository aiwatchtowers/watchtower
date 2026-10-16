package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// ErrAutomationActive is wrapped when DeleteIdleAutomation finds a running
// or waiting run of the automation.
var ErrAutomationActive = errors.New("automation has an active run")

// DeleteIdleAutomation deletes automation id with its runs, steps, state and
// outputs (FK cascade) in one transaction that holds only while no run of it
// is running or waiting — a run claimed between a check and the delete cannot
// lose its rows. Its runs' open asks are withdrawn (agent) first, in the same
// transaction: the run's FK would otherwise leave an open ask of no run and
// no session. An active run → ErrAutomationActive naming it; a missing row
// → ErrAutomationNotFound.
func (db *DB) DeleteIdleAutomation(id int64) error {
	const idle = ` NOT EXISTS (SELECT 1 FROM automation_runs WHERE automation_id = ? AND status IN ('running','waiting'))`
	var n int64
	err := db.WithTx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = ?, withdrawn_at = `+askNowSQL+`
			WHERE status = 'open' AND automation_run_id IN (SELECT id FROM automation_runs WHERE automation_id = ?) AND`+idle,
			WithdrawnByAgent, id, id); err != nil {
			return fmt.Errorf("withdrawing the open asks of automation %d: %w", id, err)
		}
		res, err := tx.Exec(`DELETE FROM automations WHERE id = ? AND`+idle, id, id)
		if err != nil {
			return fmt.Errorf("deleting automation %d: %w", id, err)
		}
		if n, err = res.RowsAffected(); err != nil {
			return fmt.Errorf("deleting automation %d: %w", id, err)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if n == 1 {
		return nil
	}
	if _, err := db.GetAutomation(id); err != nil {
		return err
	}
	var runID int64
	err = db.QueryRow(`SELECT id FROM automation_runs WHERE automation_id = ? AND status IN ('running','waiting')
		ORDER BY id LIMIT 1`, id).Scan(&runID)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("automation %d: %w (it ended meanwhile; try again)", id, ErrAutomationActive)
	}
	if err != nil {
		return fmt.Errorf("deleting automation %d: %w", id, err)
	}
	return fmt.Errorf("automation %d: %w: run %d", id, ErrAutomationActive, runID)
}

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
