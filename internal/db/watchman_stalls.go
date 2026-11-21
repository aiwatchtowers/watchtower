package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// The stall watch (00212, spec 2026-11-21-watchman-tuning §4b): the twin
// worker's count of pings per handed session whose agent stopped. Written
// only by the twin worker; pruned with the arming (PruneWatchmanStalls).

// WatchmanStallRow is one session's stall count.
type WatchmanStallRow struct {
	SessionID int64
	// StoppedAt is when the stopped state last counted began: the turn's
	// end, or the end of its background work when that came later.
	StoppedAt time.Time
	// Pings counts the pings delivered since the last progress (a new ask,
	// a finish, the worktree HEAD moved).
	Pings      int
	LastPingAt *time.Time
	// Head is the session's worktree HEAD at the last ping ("" = unread).
	Head string
	// AsksSeen is the session's ask count at the last ping.
	AsksSeen int
	// ParkedAt is when the stall was journalled (kind 'stall'); nil = not.
	ParkedAt *time.Time
	// LastDelivery is how the last counted ping went: "submitted" or
	// "typed" ("" = none since the last reset).
	LastDelivery string
}

// wmStallTime keeps the stall stamps' nanoseconds, so a stop and the ping
// before it compare exactly.
func wmStallTime(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

func wmStallNullTime(t *time.Time) any {
	if t == nil {
		return nil
	}
	return wmStallTime(*t)
}

func wmParseStallTime(column string, s sql.NullString) (*time.Time, error) {
	if !s.Valid || s.String == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339Nano, s.String)
	if err != nil {
		return nil, fmt.Errorf("parsing watchman stall %s %q: %w", column, s.String, err)
	}
	return &t, nil
}

// WatchmanStall is sessionID's stall row; nil when it has none.
func (db *DB) WatchmanStall(sessionID int64) (*WatchmanStallRow, error) {
	r := WatchmanStallRow{SessionID: sessionID}
	var stopped string
	var lastPing, parked sql.NullString
	err := db.QueryRow(`SELECT stopped_at, pings, last_ping_at, head, asks_seen, parked_at, last_delivery
		FROM watchman_stalls WHERE session_id = ?`, sessionID).
		Scan(&stopped, &r.Pings, &lastPing, &r.Head, &r.AsksSeen, &parked, &r.LastDelivery)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading the watchman stall of session %d: %w", sessionID, err)
	}
	if r.StoppedAt, err = time.Parse(time.RFC3339Nano, stopped); err != nil {
		return nil, fmt.Errorf("parsing watchman stall stopped_at %q: %w", stopped, err)
	}
	if r.LastPingAt, err = wmParseStallTime("last_ping_at", lastPing); err != nil {
		return nil, err
	}
	if r.ParkedAt, err = wmParseStallTime("parked_at", parked); err != nil {
		return nil, err
	}
	return &r, nil
}

// UpsertWatchmanStall writes row as the session's stall row.
func (db *DB) UpsertWatchmanStall(row WatchmanStallRow) error {
	if err := upsertWatchmanStall(db, row); err != nil {
		return fmt.Errorf("writing the watchman stall of session %d: %w", row.SessionID, err)
	}
	return nil
}

func upsertWatchmanStall(ex sqlExecer, row WatchmanStallRow) error {
	_, err := ex.Exec(`INSERT INTO watchman_stalls (session_id, stopped_at, pings, last_ping_at, head, asks_seen, parked_at,
			last_delivery)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(session_id) DO UPDATE SET stopped_at = excluded.stopped_at, pings = excluded.pings,
			last_ping_at = excluded.last_ping_at, head = excluded.head, asks_seen = excluded.asks_seen,
			parked_at = excluded.parked_at, last_delivery = excluded.last_delivery`,
		row.SessionID, wmStallTime(row.StoppedAt), row.Pings, wmStallNullTime(row.LastPingAt), row.Head, row.AsksSeen,
		wmStallNullTime(row.ParkedAt), row.LastDelivery)
	return err //nolint:wrapcheck // the callers name the session
}

// DeleteWatchmanStall removes sessionID's stall row (none is fine).
func (db *DB) DeleteWatchmanStall(sessionID int64) error {
	if _, err := db.Exec(`DELETE FROM watchman_stalls WHERE session_id = ?`, sessionID); err != nil {
		return fmt.Errorf("deleting the watchman stall of session %d: %w", sessionID, err)
	}
	return nil
}

// PruneWatchmanStalls removes the stall rows of sessions the twin no longer
// acts for: taken back, finished, ended or being deleted (the arming rule of
// armedSessionsFrom). n is how many went.
func (db *DB) PruneWatchmanStalls() (n int64, err error) {
	res, err := db.Exec(`DELETE FROM watchman_stalls WHERE session_id NOT IN (SELECT id FROM (` + armedSessionsFrom + `))`)
	if err != nil {
		return 0, fmt.Errorf("pruning watchman stalls: %w", err)
	}
	return res.RowsAffected()
}

// WatchmanSessionAskCount is how many asks sessionID ever filed, whatever
// became of them: a new ask raises it (the stall watch's progress).
func (db *DB) WatchmanSessionAskCount(sessionID int64) (int, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM owner_asks WHERE session_id = ?`, sessionID).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting the asks of session %d: %w", sessionID, err)
	}
	return n, nil
}

// WatchmanStallItemDone reports whether sessionID's stall item exists and
// the owner marked it done (owner_done_at, the Desktop's Mark done): the
// stall watch then counts its pings again.
func (db *DB) WatchmanStallItemDone(sessionID int64) (bool, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM watchman_items
		WHERE ref_kind = 'session' AND ref_id = ? AND kind = 'stall' AND owner_done_at IS NOT NULL`, sessionID).Scan(&n); err != nil {
		return false, fmt.Errorf("reading the watchman stall item of session %d: %w", sessionID, err)
	}
	return n > 0, nil
}

// InsertWatchmanStallItem journals a stalled session for the owner: kind
// 'stall', ref ('session', sessionID), finished parked with reason (created_at
// = decided_at = at, unsure 1), so it waits under Waiting for you until Mark
// done. One open stall item per session: while one waits it keeps its id and
// created_at and takes the new reason (a re-park says why this time); one
// the owner marked done (shown nowhere since) gives way to the new one in the
// same transaction (the item is UNIQUE by ref and kind).
func (db *DB) InsertWatchmanStallItem(sessionID, targetID, workbenchID int64, reason string, at time.Time) error {
	if err := db.WithTx(func(tx *sql.Tx) error {
		return insertWatchmanStallItem(tx, sessionID, targetID, workbenchID, reason, at)
	}); err != nil {
		return fmt.Errorf("journalling the watchman stall of session %d: %w", sessionID, err)
	}
	return nil
}

func insertWatchmanStallItem(tx *sql.Tx, sessionID, targetID, workbenchID int64, reason string, at time.Time) error {
	if _, err := tx.Exec(`DELETE FROM watchman_items
		WHERE ref_kind = 'session' AND ref_id = ? AND kind = 'stall' AND owner_done_at IS NOT NULL`, sessionID); err != nil {
		return err //nolint:wrapcheck // the callers name the session
	}
	_, err := tx.Exec(`INSERT INTO watchman_items (workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome,
			unsure, park_reason, created_at, decided_at)
		VALUES (?, ?, ?, 'stall', 'session', ?, 'done', 'parked', 1, ?, ?, ?)
		ON CONFLICT(ref_kind, ref_id, kind) DO UPDATE SET park_reason = excluded.park_reason`,
		workbenchID, sessionID, wmNullID(targetID), sessionID, reason, wmTime(at), wmTime(at))
	return err //nolint:wrapcheck // the callers name the session
}

// ParkWatchmanStall parks row's session for the owner in one transaction
// that first re-checks the arming (WATCHMAN-04): still armed → the stall
// item (InsertWatchmanStallItem's rule) and the row with parked_at = at;
// taken back meanwhile → nothing is written and parked is false.
func (db *DB) ParkWatchmanStall(row WatchmanStallRow, targetID, workbenchID int64, reason string, at time.Time) (parked bool, err error) {
	err = db.WithTx(func(tx *sql.Tx) error {
		var n int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM (`+armedSessionsFrom+` AND ts.id = ?)`, row.SessionID).Scan(&n); err != nil {
			return err //nolint:wrapcheck // wrapped below
		}
		if n == 0 {
			return nil
		}
		if err := insertWatchmanStallItem(tx, row.SessionID, targetID, workbenchID, reason, at); err != nil {
			return err
		}
		row.ParkedAt = &at
		if err := upsertWatchmanStall(tx, row); err != nil {
			return err
		}
		parked = true
		return nil
	})
	if err != nil {
		return false, fmt.Errorf("parking the watchman stall of session %d: %w", row.SessionID, err)
	}
	return parked, nil
}
