package db

import (
	"database/sql"
	"fmt"
)

// WatchmanSourceCounts is what the learning estimate reads from the
// database: no source is walked.
type WatchmanSourceCounts struct {
	Decided  int // rows of the four database sources (asks, review, spec marks, permissions)
	Asks     int // of them, asks: each goes to the labeller (a category, or a review ask's parked flag)
	Sessions int // the workbench's agent sessions (their owner turns need labels)
}

// WatchmanCounts counts the rows the database sources would offer for a
// workbench (the readers' own selects) and its agent sessions.
func (db *DB) WatchmanCounts(workbenchID int64) (WatchmanSourceCounts, error) {
	var c WatchmanSourceCounts
	wb := workbenchID
	for _, q := range []struct {
		sql  string
		args []any
		into *int
	}{
		{`SELECT COUNT(*) FROM (` + wmAsksSQL + `)`, []any{wb}, nil},
		{`SELECT COUNT(*) FROM (` + wmReviewSQL + `)`, []any{wb, wb, wb, wb}, nil},
		{`SELECT COUNT(*) FROM (` + wmSpecMarksSQL + `)`, []any{wb}, nil},
		{`SELECT COUNT(*) FROM (` + wmPermissionSQL + `)`, []any{wb}, nil},
		{`SELECT COUNT(*) FROM (` + wmAsksSQL + `)`, []any{wb}, &c.Asks},
		{`SELECT COUNT(*) FROM terminal_sessions WHERE project_id = ? AND kind IN ('claude','codex') AND ` + NotDeletingSQL, []any{wb}, &c.Sessions},
	} {
		var n int
		if err := db.QueryRow(q.sql, q.args...).Scan(&n); err != nil {
			return WatchmanSourceCounts{}, fmt.Errorf("counting watchman sources of workbench %d: %w", workbenchID, err)
		}
		if q.into != nil {
			*q.into = n
		} else {
			c.Decided += n
		}
	}
	return c, nil
}

// AddWatchmanUnlabelled adds n decisions a source offered and the learner did
// not place in a category to the workbench's counter, inside tx (with the
// batch and its cursor). A workbench Watchman is not on for has no row: no-op.
func (db *DB) AddWatchmanUnlabelled(tx *sql.Tx, workbenchID int64, n int) error {
	if n == 0 {
		return nil
	}
	if _, err := tx.Exec(`UPDATE watchman_workbenches SET unlabelled = unlabelled + ? WHERE workbench_id = ?`, n, workbenchID); err != nil {
		return fmt.Errorf("counting unlabelled watchman decisions of workbench %d: %w", workbenchID, err)
	}
	return nil
}
