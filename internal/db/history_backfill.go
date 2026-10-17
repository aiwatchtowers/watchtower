package db

import (
	"database/sql"
	"fmt"
	"time"
)

// HistoryBackfill is one source's history backfill (docs/features/history-backfill.md).
type HistoryBackfill struct {
	ID            int64
	SourceKind    string // slack | gmail | imap | jira
	AccountID     int64
	FloorTS       float64
	UpperTS       float64
	ReachedTS     float64
	Status        string // running | paused | done | off
	Waiting       string // "" | "plan_limit"
	ChunkFailures int
	LastError     string
	StartedAt     time.Time
	UpdatedAt     time.Time
	DoneAt        *time.Time
	HeldSince     *time.Time // when a transient failure began holding the chunk; nil = not held (#580)
}

// StartHistoryBackfill creates the source's row; a second call is a no-op so
// only the first sync ever starts one.
func (db *DB) StartHistoryBackfill(kind string, accountID int64, floorTS, upperTS float64, now time.Time) (bool, error) {
	ts := planTime(now)
	res, err := db.Exec(`INSERT INTO history_backfill
		(source_kind, account_id, floor_ts, upper_ts, reached_ts, started_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(source_kind, account_id) DO NOTHING`,
		kind, accountID, floorTS, upperTS, upperTS, ts, ts)
	if err != nil {
		return false, fmt.Errorf("history backfill: start: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("history backfill: start: %w", err)
	}
	return n > 0, nil
}

// ListHistoryBackfills returns every row, by id.
func (db *DB) ListHistoryBackfills() ([]HistoryBackfill, error) {
	rows, err := db.Query(`SELECT id, source_kind, account_id, floor_ts, upper_ts, reached_ts,
		status, waiting, chunk_failures, last_error, started_at, updated_at, done_at, held_since
		FROM history_backfill ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("history backfill: list: %w", err)
	}
	defer rows.Close()
	var out []HistoryBackfill
	for rows.Next() {
		var b HistoryBackfill
		var started, updated string
		var done, held sql.NullString
		if err := rows.Scan(&b.ID, &b.SourceKind, &b.AccountID, &b.FloorTS, &b.UpperTS, &b.ReachedTS,
			&b.Status, &b.Waiting, &b.ChunkFailures, &b.LastError, &started, &updated, &done, &held); err != nil {
			return nil, fmt.Errorf("history backfill: scan: %w", err)
		}
		if b.StartedAt, err = parsePlanTime(started); err != nil {
			return nil, fmt.Errorf("history backfill: started_at: %w", err)
		}
		if b.UpdatedAt, err = parsePlanTime(updated); err != nil {
			return nil, fmt.Errorf("history backfill: updated_at: %w", err)
		}
		if done.Valid && done.String != "" {
			t, err := parsePlanTime(done.String)
			if err != nil {
				return nil, fmt.Errorf("history backfill: done_at: %w", err)
			}
			b.DoneAt = &t
		}
		if held.Valid && held.String != "" {
			t, err := parsePlanTime(held.String)
			if err != nil {
				return nil, fmt.Errorf("history backfill: held_since: %w", err)
			}
			b.HeldSince = &t
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("history backfill: list: %w", err)
	}
	return out, nil
}

// AdvanceHistoryBackfill moves reached_ts, clears failures, error and the
// waiting flag, and marks the row done once reached_ts is at or below the floor.
func (db *DB) AdvanceHistoryBackfill(id int64, reachedTS float64, now time.Time) error {
	ts := planTime(now)
	_, err := db.Exec(`UPDATE history_backfill SET
		reached_ts = ?, chunk_failures = 0, last_error = '', waiting = '', held_since = NULL, updated_at = ?,
		status  = CASE WHEN ? <= floor_ts THEN 'done' ELSE status END,
		done_at = CASE WHEN ? <= floor_ts THEN ? ELSE done_at END
		WHERE id = ?`, reachedTS, ts, reachedTS, reachedTS, ts, id)
	if err != nil {
		return fmt.Errorf("history backfill: advance: %w", err)
	}
	return nil
}

// RecordHistoryBackfillFailure bumps the chunk failure count and returns it.
func (db *DB) RecordHistoryBackfillFailure(id int64, msg string, now time.Time) (int, error) {
	var n int
	err := db.QueryRow(`UPDATE history_backfill SET chunk_failures = chunk_failures + 1,
		last_error = ?, updated_at = ? WHERE id = ? RETURNING chunk_failures`,
		msg, planTime(now), id).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("history backfill: record failure: %w", err)
	}
	return n, nil
}

// SetHistoryBackfillStatus sets running | paused | done | off.
func (db *DB) SetHistoryBackfillStatus(id int64, status string, now time.Time) error {
	if _, err := db.Exec(`UPDATE history_backfill SET status = ?, updated_at = ? WHERE id = ?`,
		status, planTime(now), id); err != nil {
		return fmt.Errorf("history backfill: set status: %w", err)
	}
	return nil
}

// SetHistoryBackfillWaiting sets "" or "plan_limit".
func (db *DB) SetHistoryBackfillWaiting(id int64, waiting string, now time.Time) error {
	if _, err := db.Exec(`UPDATE history_backfill SET waiting = ?, updated_at = ? WHERE id = ?`,
		waiting, planTime(now), id); err != nil {
		return fmt.Errorf("history backfill: set waiting: %w", err)
	}
	return nil
}

// SetHistoryBackfillLastError sets last_error alone. The runner calls it
// after skipping a chunk, so `backfill status` shows the skip until the next
// advance clears it.
func (db *DB) SetHistoryBackfillLastError(id int64, msg string, now time.Time) error {
	if _, err := db.Exec(`UPDATE history_backfill SET last_error = ?, updated_at = ? WHERE id = ?`,
		msg, planTime(now), id); err != nil {
		return fmt.Errorf("history backfill: set last error: %w", err)
	}
	return nil
}

// HoldHistoryBackfill marks the row held by a transient failure since now,
// with msg as last_error (replacing an older strike's reason).
func (db *DB) HoldHistoryBackfill(id int64, msg string, now time.Time) error {
	ts := planTime(now)
	if _, err := db.Exec(`UPDATE history_backfill SET held_since = ?, last_error = ?, updated_at = ? WHERE id = ?`,
		ts, msg, ts, id); err != nil {
		return fmt.Errorf("history backfill: hold: %w", err)
	}
	return nil
}

// ReleaseHistoryBackfillHold clears held_since; last_error is left as is.
func (db *DB) ReleaseHistoryBackfillHold(id int64, now time.Time) error {
	if _, err := db.Exec(`UPDATE history_backfill SET held_since = NULL, updated_at = ? WHERE id = ?`,
		planTime(now), id); err != nil {
		return fmt.Errorf("history backfill: release hold: %w", err)
	}
	return nil
}

// HasActiveHistoryBackfill reports whether any row is running or paused.
func (db *DB) HasActiveHistoryBackfill() (bool, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM history_backfill WHERE status IN ('running','paused')`).Scan(&n); err != nil {
		return false, fmt.Errorf("history backfill: active: %w", err)
	}
	return n > 0, nil
}
