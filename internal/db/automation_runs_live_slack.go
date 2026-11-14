package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Live Slack runs (#1709, migration 00188 automation_runs.live_slack).

// MarkAutomationRunLiveSlack marks run runID as one that used Live Slack (its
// agent() called the owner's Slack connector). Idempotent.
func (db *DB) MarkAutomationRunLiveSlack(runID int64) error {
	res, err := db.Exec(`UPDATE automation_runs SET live_slack = 1 WHERE id = ?`, runID)
	if err != nil {
		return fmt.Errorf("marking automation run %d live slack: %w", runID, err)
	}
	if n, err := res.RowsAffected(); err == nil && n == 0 {
		return fmt.Errorf("automation run %d: %w", runID, ErrAutomationRunNotFound)
	}
	return nil
}

// LastLiveSlackRunStart is the newest started_at of automationID's runs other
// than exceptRunID, whatever their trigger or live flag (the hourly limit of
// a slack:live recipe, D15). A run ended by the limit never started, so it
// never counts. ErrAutomationRunNotFound when no run of it ever started.
func (db *DB) LastLiveSlackRunStart(automationID, exceptRunID int64) (time.Time, error) {
	var last sql.NullString
	err := db.QueryRow(`SELECT MAX(started_at) FROM automation_runs
		WHERE automation_id = ? AND id <> ? AND started_at IS NOT NULL`, automationID, exceptRunID).Scan(&last)
	if err != nil {
		return time.Time{}, fmt.Errorf("reading the last run start of automation %d: %w", automationID, err)
	}
	if !last.Valid {
		return time.Time{}, fmt.Errorf("automation %d: no started run: %w", automationID, ErrAutomationRunNotFound)
	}
	t, err := time.Parse(automationTimeLayout, last.String)
	if err != nil {
		return time.Time{}, fmt.Errorf("automation %d started_at %q: %w", automationID, last.String, err)
	}
	return t, nil
}

// LimitQueuedLiveSlackRun ends queued run runID unstarted, as cancelled with
// error_kind='not_runnable' and reason as its error: a slack:live recipe's
// run inside the hourly limit. ErrRunNotQueued when it was claimed or ended
// meanwhile.
func (db *DB) LimitQueuedLiveSlackRun(runID int64, reason string, now time.Time) error {
	if err := requireRunTime(now, fmt.Sprintf("limiting automation run %d", runID)); err != nil {
		return err
	}
	if reason == "" {
		return errors.New("limiting an automation run needs a reason")
	}
	res, err := db.Exec(`UPDATE automation_runs SET status = 'cancelled', error_kind = 'not_runnable',
		error = ?, finished_at = ?
		WHERE id = ? AND status = 'queued'`, reason, formatAutomationTime(now), runID)
	if err != nil {
		return fmt.Errorf("limiting automation run %d: %w", runID, err)
	}
	return requireRunTransition(db, res, runID, ErrRunNotQueued)
}
