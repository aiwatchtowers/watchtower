package db

import (
	"fmt"
	"time"
)

// Watchman arming (00198, spec §2): which sessions and targets the owner
// handed to the twin. One row
// per (scope, ref_id); the last write wins.

// WatchmanArming is one armed session or target.
type WatchmanArming struct {
	Scope   string // session | target
	RefID   int64
	ArmedAt time.Time
	ArmedBy string // desktop | cli
}

// ArmedSession is a live session the twin may decide for.
type ArmedSession struct {
	SessionID, WorkbenchID  int64
	Folder, WorkbenchFolder string
	TargetID                int64 // the session's ticket; 0 = none
}

// wmArmTime keeps nanoseconds in a fixed width, so two presses in one second stay distinct and sort in time order.
func wmArmTime(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000000000Z") }

// UpsertWatchmanArming writes the whole row; a second write of the same
// (scope, ref_id) replaces the first's armed_at and armed_by.
func (db *DB) UpsertWatchmanArming(a WatchmanArming) error {
	_, err := db.Exec(`INSERT INTO watchman_arming (scope, ref_id, armed_at, armed_by) VALUES (?, ?, ?, ?)
		ON CONFLICT(scope, ref_id) DO UPDATE SET armed_at = excluded.armed_at, armed_by = excluded.armed_by`,
		a.Scope, a.RefID, wmArmTime(a.ArmedAt), a.ArmedBy)
	if err != nil {
		return fmt.Errorf("arming watchman %s %d: %w", a.Scope, a.RefID, err)
	}
	return nil
}

// DeleteWatchmanArming removes one row; false when there was none.
func (db *DB) DeleteWatchmanArming(scope string, refID int64) (bool, error) {
	res, err := db.Exec(`DELETE FROM watchman_arming WHERE scope = ? AND ref_id = ?`, scope, refID)
	if err != nil {
		return false, fmt.Errorf("disarming watchman %s %d: %w", scope, refID, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// ListWatchmanArming returns every arming row, oldest first.
func (db *DB) ListWatchmanArming() ([]WatchmanArming, error) {
	rows, err := db.Query(`SELECT scope, ref_id, armed_at, armed_by FROM watchman_arming ORDER BY armed_at, id`)
	if err != nil {
		return nil, fmt.Errorf("listing watchman arming: %w", err)
	}
	defer rows.Close()
	var out []WatchmanArming
	for rows.Next() {
		var a WatchmanArming
		var at string
		if err := rows.Scan(&a.Scope, &a.RefID, &at, &a.ArmedBy); err != nil {
			return nil, err
		}
		if a.ArmedAt, err = time.Parse(time.RFC3339Nano, at); err != nil {
			return nil, fmt.Errorf("parsing watchman armed_at %q: %w", at, err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// armedSessionsFrom selects live (not finished, not being deleted) sessions
// armed directly, or whose ticket sits in the subtree of an armed target.
const armedSessionsFrom = `
	WITH RECURSIVE sub(id) AS (
		SELECT ref_id FROM watchman_arming WHERE scope = 'target'
		UNION
		SELECT t.id FROM targets t JOIN sub ON t.parent_id = sub.id
	)
	SELECT ts.id, ts.project_id, ts.folder_path, p.folder_path, COALESCE(ts.target_id, 0)
	FROM terminal_sessions ts JOIN projects p ON p.id = ts.project_id
	WHERE ts.finished_at IS NULL AND ts.delete_requested_at IS NULL AND ts.kind <> 'shell'
	  AND (EXISTS (SELECT 1 FROM watchman_arming a WHERE a.scope = 'session' AND a.ref_id = ts.id)
	       OR ts.target_id IN (SELECT id FROM sub))`

// WatchmanArmedSessions lists the live sessions the twin may decide for.
func (db *DB) WatchmanArmedSessions() ([]ArmedSession, error) {
	rows, err := db.Query(armedSessionsFrom + ` ORDER BY ts.id`)
	if err != nil {
		return nil, fmt.Errorf("listing watchman armed sessions: %w", err)
	}
	defer rows.Close()
	var out []ArmedSession
	for rows.Next() {
		var s ArmedSession
		if err := rows.Scan(&s.SessionID, &s.WorkbenchID, &s.Folder, &s.WorkbenchFolder, &s.TargetID); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// WatchmanSessionArmed reports whether sessionID is one of the armed sessions.
func (db *DB) WatchmanSessionArmed(sessionID int64) (bool, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM (`+armedSessionsFrom+` AND ts.id = ?)`, sessionID).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("checking watchman arming of session %d: %w", sessionID, err)
	}
	return n > 0, nil
}
