package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// WatchmanRecentPrecedents returns the newest limit precedents of a category
// in a workbench, newest first.
func (db *DB) WatchmanRecentPrecedents(workbenchID int64, category string, limit int) ([]WatchmanPrecedent, error) {
	rows, err := db.Query(`SELECT id, workbench_id, source, source_key, category, situation, choice, owner_words, decided_at, weight
		FROM watchman_precedents WHERE workbench_id = ? AND category = ?
		ORDER BY decided_at DESC, id DESC LIMIT ?`, workbenchID, category, limit)
	if err != nil {
		return nil, fmt.Errorf("reading watchman precedents %d/%s: %w", workbenchID, category, err)
	}
	defer rows.Close()
	var out []WatchmanPrecedent
	for rows.Next() {
		var p WatchmanPrecedent
		var decided string
		if err := rows.Scan(&p.ID, &p.WorkbenchID, &p.Source, &p.SourceKey, &p.Category, &p.Situation, &p.Choice, &p.OwnerWords, &decided, &p.Weight); err != nil {
			return nil, fmt.Errorf("scanning watchman precedent: %w", err)
		}
		p.DecidedAt, _ = time.Parse(time.RFC3339, decided)
		out = append(out, p)
	}
	return out, rows.Err()
}

// SaveLearnedWatchmanProfile stores a rebuilt profile entry: a new row at
// version 1, else the text replaced and the version bumped — unless the row
// is pinned, which is left untouched (saved=false). The pinned check is in
// the same statement, so an owner pin made while the text was being built
// is never overwritten.
func (db *DB) SaveLearnedWatchmanProfile(workbenchID int64, key, text string, at time.Time) (saved bool, err error) {
	res, err := db.Exec(`INSERT INTO watchman_profile (workbench_id, key, text, pinned, version, updated_at)
		VALUES (?, ?, ?, 0, 1, ?)
		ON CONFLICT(workbench_id, key) DO UPDATE SET text = excluded.text,
			version = watchman_profile.version + 1, updated_at = excluded.updated_at
		WHERE watchman_profile.pinned = 0`,
		workbenchID, key, text, wmTime(at))
	if err != nil {
		return false, fmt.Errorf("saving watchman profile %d/%s: %w", workbenchID, key, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("saving watchman profile %d/%s: %w", workbenchID, key, err)
	}
	return n > 0, nil
}

// PinWatchmanProfile stores the owner's own text for a profile entry and pins
// it: the learning phase no longer replaces it until it is unpinned.
func (db *DB) PinWatchmanProfile(workbenchID int64, key, text string, at time.Time) error {
	_, err := db.Exec(`INSERT INTO watchman_profile (workbench_id, key, text, pinned, version, updated_at)
		VALUES (?, ?, ?, 1, 1, ?)
		ON CONFLICT(workbench_id, key) DO UPDATE SET text = excluded.text, pinned = 1,
			version = watchman_profile.version + 1, updated_at = excluded.updated_at`,
		workbenchID, key, text, wmTime(at))
	if err != nil {
		return fmt.Errorf("pinning watchman profile %d/%s: %w", workbenchID, key, err)
	}
	return nil
}

// ErrWatchmanProfileNotFound reports a profile entry that does not exist.
var ErrWatchmanProfileNotFound = errors.New("watchman profile entry not found")

// UnpinWatchmanProfile unpins an entry, keeping its text until the next
// rebuild replaces it.
func (db *DB) UnpinWatchmanProfile(workbenchID int64, key string, at time.Time) error {
	res, err := db.Exec(`UPDATE watchman_profile SET pinned = 0, updated_at = ? WHERE workbench_id = ? AND key = ?`,
		wmTime(at), workbenchID, key)
	if err != nil {
		return fmt.Errorf("unpinning watchman profile %d/%s: %w", workbenchID, key, err)
	}
	if n, err := res.RowsAffected(); err != nil {
		return fmt.Errorf("unpinning watchman profile %d/%s: %w", workbenchID, key, err)
	} else if n == 0 {
		return fmt.Errorf("%w: workbench %d, key %q", ErrWatchmanProfileNotFound, workbenchID, key)
	}
	return nil
}

// WatchmanOwnerActivity returns when the owner answered the workbench's asks
// (answered or delivered, automation runs left out) and wrote his own review
// comments (not carried copies), at or after since, in no particular order.
func (db *DB) WatchmanOwnerActivity(workbenchID int64, since time.Time) ([]time.Time, error) {
	rows, err := db.Query(`SELECT at FROM (
		SELECT strftime(`+wmAtFormat+`, a.answered_at) AS at
		FROM owner_asks a LEFT JOIN terminal_sessions s ON s.id = a.session_id
		WHERE a.project_id = ? AND a.status IN ('answered','delivered') AND a.answered_at != ''
			AND a.automation_run_id IS NULL AND s.automation_run_id IS NULL
		UNION ALL
		SELECT strftime(`+wmAtFormat+`, c.created_at)
		FROM review_comments c JOIN review_rounds r ON r.id = c.round_id
		WHERE r.project_id = ? AND c.carried_from IS NULL
	) WHERE at >= ?`,
		workbenchID, workbenchID, since.UTC().Format("2006-01-02T15:04:05.000Z"))
	if err != nil {
		return nil, fmt.Errorf("reading owner activity of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []time.Time
	for rows.Next() {
		var at sql.NullString
		if err := rows.Scan(&at); err != nil {
			return nil, fmt.Errorf("scanning owner activity: %w", err)
		}
		t, err := time.Parse(time.RFC3339, at.String)
		if err != nil {
			continue // an unparsable stamp carries no time
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
