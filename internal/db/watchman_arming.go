package db

import (
	"database/sql"
	"fmt"
	"time"
)

// Watchman arming (00202, spec §2): which sessions and targets the owner
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
	TargetID                int64  // the session's ticket; 0 = none
	Kind                    string // the agent: claude or codex
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

// ArmWatchman inserts the row unless (scope, ref_id) is already armed, which
// keeps its armed_at and armed_by; inserted reports a new row.
func (db *DB) ArmWatchman(a WatchmanArming) (inserted bool, err error) {
	return armWatchman(db, a)
}

// sqlExecer is a *DB or a *sql.Tx.
type sqlExecer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

// armWatchman is ArmWatchman's statement on ex (the handle or a tx).
func armWatchman(ex sqlExecer, a WatchmanArming) (inserted bool, err error) {
	res, err := ex.Exec(`INSERT INTO watchman_arming (scope, ref_id, armed_at, armed_by) VALUES (?, ?, ?, ?)
		ON CONFLICT(scope, ref_id) DO NOTHING`, a.Scope, a.RefID, wmArmTime(a.ArmedAt), a.ArmedBy)
	if err != nil {
		return false, fmt.Errorf("arming watchman %s %d: %w", a.Scope, a.RefID, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
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

// ClearWatchmanArming removes every row; n is how many there were.
func (db *DB) ClearWatchmanArming() (n int64, err error) {
	res, err := db.Exec(`DELETE FROM watchman_arming`)
	if err != nil {
		return 0, fmt.Errorf("disarming watchman: %w", err)
	}
	return res.RowsAffected()
}

// PruneWatchmanArming removes arming rows nothing can be decided for any
// more: a session row whose session is gone, finished or being deleted —
// unless the session finished normally (still there, not being deleted) and
// its handover is still the twin's (queued, deciding, or answered
// "Continue" with its next session still owed) — and a target row whose
// target is gone. A target with no live session stays armed (a new
// session under it is handed to the twin). n is how many went.
func (db *DB) PruneWatchmanArming() (n int64, err error) {
	res, err := db.Exec(`DELETE FROM watchman_arming WHERE
		(scope = 'session' AND NOT EXISTS (SELECT 1 FROM terminal_sessions ts
			WHERE ts.id = watchman_arming.ref_id AND ts.finished_at IS NULL AND ts.`+NotDeletingSQL+`)
		 AND NOT (EXISTS (SELECT 1 FROM terminal_sessions ts
				WHERE ts.id = watchman_arming.ref_id AND ts.finished_at IS NOT NULL AND ts.`+NotDeletingSQL+`)
			AND EXISTS (SELECT 1 FROM watchman_items wi
				WHERE wi.session_id = watchman_arming.ref_id AND wi.kind = 'handover'
				  AND (wi.state IN ('queued', 'deciding') OR (wi.state = 'done' AND wi.error IN (?, ?))))))
		OR (scope = 'target' AND NOT EXISTS (SELECT 1 FROM targets t WHERE t.id = watchman_arming.ref_id))`,
		WatchmanStartPending, WatchmanStartClaimed)
	if err != nil {
		return 0, fmt.Errorf("pruning watchman arming: %w", err)
	}
	return res.RowsAffected()
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
	SELECT ts.id, ts.project_id, ts.folder_path, p.folder_path, COALESCE(ts.target_id, 0), ts.kind
	FROM terminal_sessions ts JOIN projects p ON p.id = ts.project_id
	WHERE ts.finished_at IS NULL AND ts.` + NotDeletingSQL + ` AND ts.kind <> 'shell'
	  AND (EXISTS (SELECT 1 FROM watchman_arming a WHERE a.scope = 'session' AND a.ref_id = ts.id)
	       OR ts.target_id IN (SELECT id FROM sub))`

// WatchmanLiveSessions lists the live workbench agent sessions — the ones
// that can be armed — by id.
func (db *DB) WatchmanLiveSessions() ([]ArmedSession, error) {
	rows, err := db.Query(`SELECT ts.id, ts.project_id, ts.folder_path, p.folder_path, COALESCE(ts.target_id, 0), ts.kind
		FROM terminal_sessions ts JOIN projects p ON p.id = ts.project_id
		WHERE ts.finished_at IS NULL AND ts.` + NotDeletingSQL + ` AND ts.kind <> 'shell' ORDER BY ts.id`)
	if err != nil {
		return nil, fmt.Errorf("listing live workbench sessions: %w", err)
	}
	return scanArmedSessions(rows)
}

// WatchmanTargetWorkbench is the workbench target id lives on; 0 when it
// lives on no workbench, sql.ErrNoRows when there is no such target.
func (db *DB) WatchmanTargetWorkbench(id int64) (int64, error) {
	var wb sql.NullInt64
	if err := db.QueryRow(`SELECT project_id FROM targets WHERE id = ?`, id).Scan(&wb); err != nil {
		return 0, fmt.Errorf("reading target %d: %w", id, err)
	}
	return wb.Int64, nil
}

func scanArmedSessions(rows *sql.Rows) ([]ArmedSession, error) {
	defer rows.Close()
	var out []ArmedSession
	for rows.Next() {
		var s ArmedSession
		if err := rows.Scan(&s.SessionID, &s.WorkbenchID, &s.Folder, &s.WorkbenchFolder, &s.TargetID, &s.Kind); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// WatchmanArmedSessions lists the live sessions the twin may decide for.
func (db *DB) WatchmanArmedSessions() ([]ArmedSession, error) {
	rows, err := db.Query(armedSessionsFrom + ` ORDER BY ts.id`)
	if err != nil {
		return nil, fmt.Errorf("listing watchman armed sessions: %w", err)
	}
	return scanArmedSessions(rows)
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

// WatchmanArmedSession is session sessionID when it is armed, in one read
// (the guard hook's whole cost on an unarmed session); armed is false
// otherwise.
func (db *DB) WatchmanArmedSession(sessionID int64) (s ArmedSession, armed bool, err error) {
	rows, err := db.Query(armedSessionsFrom+` AND ts.id = ?`, sessionID)
	if err != nil {
		return ArmedSession{}, false, fmt.Errorf("reading watchman arming of session %d: %w", sessionID, err)
	}
	list, err := scanArmedSessions(rows)
	if err != nil || len(list) == 0 {
		return ArmedSession{}, false, err
	}
	return list[0], true, nil
}

// WatchmanSessionsUnderArmedTargets maps each live session whose ticket sits
// in the subtree of an armed target to that target (the oldest-armed one
// when several cover it): such a session is decided by the twin whatever
// its own arming row, and only taking the target back returns it.
func (db *DB) WatchmanSessionsUnderArmedTargets() (map[int64]int64, error) {
	rows, err := db.Query(`
		WITH RECURSIVE sub(root, id) AS (
			SELECT ref_id, ref_id FROM watchman_arming WHERE scope = 'target'
			UNION
			SELECT sub.root, t.id FROM targets t JOIN sub ON t.parent_id = sub.id
		)
		SELECT ts.id, sub.root
		FROM terminal_sessions ts
		JOIN sub ON ts.target_id = sub.id
		JOIN watchman_arming a ON a.scope = 'target' AND a.ref_id = sub.root
		WHERE ts.finished_at IS NULL AND ts.` + NotDeletingSQL + ` AND ts.kind <> 'shell'
		ORDER BY ts.id, a.armed_at, sub.root`)
	if err != nil {
		return nil, fmt.Errorf("listing sessions under armed targets: %w", err)
	}
	defer rows.Close()
	out := map[int64]int64{}
	for rows.Next() {
		var session, target int64
		if err := rows.Scan(&session, &target); err != nil {
			return nil, err
		}
		if _, ok := out[session]; !ok {
			out[session] = target
		}
	}
	return out, rows.Err()
}
