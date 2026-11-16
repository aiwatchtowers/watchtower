package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Watchman phase 1 storage (migration 00194): precedents mined from the
// owner's past decisions, their FTS index, per-source cursors, the learned
// profile and backtest results. Times are RFC 3339 UTC strings.

// WatchmanPrecedent is one past decision of the owner in a workbench.
type WatchmanPrecedent struct {
	ID          int64
	WorkbenchID int64
	Source      string // ask, review, spec, permission, turn, git
	SourceKey   string // unique within Source
	Category    string
	Situation   string
	Choice      string
	OwnerWords  string
	DecidedAt   time.Time
	Weight      float64
}

// WatchmanProfile is one learned profile entry; Key is a category or
// "sleep_window".
type WatchmanProfile struct {
	WorkbenchID int64
	Key, Text   string
	Pinned      bool
	Version     int
	UpdatedAt   time.Time
}

// WatchmanBacktest is one backtest run; Rows are written with it on insert.
type WatchmanBacktest struct {
	ID, WorkbenchID int64
	StartedAt       time.Time
	FinishedAt      *time.Time
	Status, Error   string // Status: running, done, failed
	Verdict         string // "", go, stop
	CostUSD         float64
	Progress        string
	Rows            []WatchmanBacktestRow
}

// WatchmanBacktestRow is one category's result in a backtest.
type WatchmanBacktestRow struct {
	Category  string
	Total     int
	Agree     int
	WrongHigh int
	Status    string // strong, weak, not_measured
	CostUSD   float64
}

func wmTime(t time.Time) string { return t.UTC().Format(time.RFC3339) }

// UpsertWatchmanPrecedents inserts or updates precedents keyed by
// (source, source_key) inside tx.
func (db *DB) UpsertWatchmanPrecedents(tx *sql.Tx, ps []WatchmanPrecedent) error {
	for _, p := range ps {
		_, err := tx.Exec(`INSERT INTO watchman_precedents
			(workbench_id, source, source_key, category, situation, choice, owner_words, decided_at, weight)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(source, source_key) DO UPDATE SET
				workbench_id = excluded.workbench_id, category = excluded.category,
				situation = excluded.situation, choice = excluded.choice,
				owner_words = excluded.owner_words, decided_at = excluded.decided_at,
				weight = excluded.weight`,
			p.WorkbenchID, p.Source, p.SourceKey, p.Category, p.Situation, p.Choice, p.OwnerWords, wmTime(p.DecidedAt), p.Weight)
		if err != nil {
			return fmt.Errorf("upserting watchman precedent %s/%s: %w", p.Source, p.SourceKey, err)
		}
	}
	return nil
}

// wmMatchQuery turns free text into a safe FTS5 query: each word quoted,
// joined by OR. Returns "" when no word is left.
func wmMatchQuery(q string) string {
	var terms []string
	for _, w := range strings.FieldsFunc(q, func(r rune) bool {
		return !(r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r > 127)
	}) {
		terms = append(terms, `"`+w+`"`)
	}
	return strings.Join(terms, " OR ")
}

// SearchWatchmanPrecedents returns the best bm25 matches of query among the
// workbench's precedents in category, decided strictly before `before`, and
// whose ids are not in exclude.
func (db *DB) SearchWatchmanPrecedents(workbenchID int64, category, query string, before time.Time, exclude []int64, limit int) ([]WatchmanPrecedent, error) {
	match := wmMatchQuery(query)
	if match == "" || limit <= 0 {
		return nil, nil
	}
	args := []any{match, workbenchID, category, wmTime(before)}
	sqlText := `SELECT p.id, p.workbench_id, p.source, p.source_key, p.category, p.situation, p.choice, p.owner_words, p.decided_at, p.weight
		FROM watchman_fts f JOIN watchman_precedents p ON p.id = f.rowid
		WHERE watchman_fts MATCH ? AND p.workbench_id = ? AND p.category = ? AND p.decided_at < ?`
	if len(exclude) > 0 {
		sqlText += ` AND p.id NOT IN (` + strings.TrimSuffix(strings.Repeat("?,", len(exclude)), ",") + `)`
		for _, id := range exclude {
			args = append(args, id)
		}
	}
	sqlText += ` ORDER BY bm25(watchman_fts), p.id LIMIT ?`
	args = append(args, limit)
	rows, err := db.Query(sqlText, args...)
	if err != nil {
		return nil, fmt.Errorf("searching watchman precedents: %w", err)
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

// WatchmanCursor returns the saved cursor of a source ("" when none).
func (db *DB) WatchmanCursor(workbenchID int64, source string) (string, error) {
	var c string
	err := db.QueryRow(`SELECT cursor FROM watchman_cursors WHERE workbench_id = ? AND source = ?`, workbenchID, source).Scan(&c)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("reading watchman cursor %d/%s: %w", workbenchID, source, err)
	}
	return c, nil
}

// SetWatchmanCursor saves a source's cursor inside tx.
func (db *DB) SetWatchmanCursor(tx *sql.Tx, workbenchID int64, source, cursor string) error {
	_, err := tx.Exec(`INSERT INTO watchman_cursors (workbench_id, source, cursor, updated_at)
		VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
		ON CONFLICT(workbench_id, source) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at`,
		workbenchID, source, cursor)
	if err != nil {
		return fmt.Errorf("saving watchman cursor %d/%s: %w", workbenchID, source, err)
	}
	return nil
}

// WatchmanWorkbenches lists the workbenches Watchman is enabled on.
func (db *DB) WatchmanWorkbenches() ([]int64, error) {
	rows, err := db.Query(`SELECT workbench_id FROM watchman_workbenches ORDER BY workbench_id`)
	if err != nil {
		return nil, fmt.Errorf("listing watchman workbenches: %w", err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning watchman workbench: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// EnableWatchmanWorkbench turns Watchman on for a workbench. Enabling again
// keeps the first estimate (the learning progress's denominator).
func (db *DB) EnableWatchmanWorkbench(id int64, at time.Time, estimatedDecisions int) error {
	if _, err := db.Exec(`INSERT OR IGNORE INTO watchman_workbenches (workbench_id, enabled_at, estimated_decisions) VALUES (?, ?, ?)`,
		id, wmTime(at), estimatedDecisions); err != nil {
		return fmt.Errorf("enabling watchman on workbench %d: %w", id, err)
	}
	return nil
}

// MarkWatchmanLearned records that every source finished its backfill.
func (db *DB) MarkWatchmanLearned(id int64, at time.Time) error {
	if _, err := db.Exec(`UPDATE watchman_workbenches SET learned_through = ? WHERE workbench_id = ?`, wmTime(at), id); err != nil {
		return fmt.Errorf("marking watchman workbench %d learned: %w", id, err)
	}
	return nil
}

// UpsertWatchmanProfile writes one profile entry.
func (db *DB) UpsertWatchmanProfile(p WatchmanProfile) error {
	pinned := 0
	if p.Pinned {
		pinned = 1
	}
	_, err := db.Exec(`INSERT INTO watchman_profile (workbench_id, key, text, pinned, version, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(workbench_id, key) DO UPDATE SET text = excluded.text, pinned = excluded.pinned,
			version = excluded.version, updated_at = excluded.updated_at`,
		p.WorkbenchID, p.Key, p.Text, pinned, p.Version, wmTime(p.UpdatedAt))
	if err != nil {
		return fmt.Errorf("saving watchman profile %d/%s: %w", p.WorkbenchID, p.Key, err)
	}
	return nil
}

// WatchmanProfiles returns a workbench's profile entries ordered by key.
func (db *DB) WatchmanProfiles(workbenchID int64) ([]WatchmanProfile, error) {
	rows, err := db.Query(`SELECT workbench_id, key, text, pinned, version, updated_at FROM watchman_profile WHERE workbench_id = ? ORDER BY key`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading watchman profile %d: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []WatchmanProfile
	for rows.Next() {
		var p WatchmanProfile
		var pinned int
		var upd string
		if err := rows.Scan(&p.WorkbenchID, &p.Key, &p.Text, &pinned, &p.Version, &upd); err != nil {
			return nil, fmt.Errorf("scanning watchman profile: %w", err)
		}
		p.Pinned = pinned != 0
		p.UpdatedAt, _ = time.Parse(time.RFC3339, upd)
		out = append(out, p)
	}
	return out, rows.Err()
}

// InsertWatchmanBacktest stores a backtest and its rows in one transaction.
func (db *DB) InsertWatchmanBacktest(b WatchmanBacktest) (int64, error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("inserting watchman backtest: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var fin any
	if b.FinishedAt != nil {
		fin = wmTime(*b.FinishedAt)
	}
	res, err := tx.Exec(`INSERT INTO watchman_backtests (workbench_id, started_at, finished_at, status, error, verdict, cost_usd, progress)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		b.WorkbenchID, wmTime(b.StartedAt), fin, b.Status, b.Error, b.Verdict, b.CostUSD, b.Progress)
	if err != nil {
		return 0, fmt.Errorf("inserting watchman backtest: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("inserting watchman backtest: %w", err)
	}
	for _, r := range b.Rows {
		if _, err := tx.Exec(`INSERT INTO watchman_backtest_rows (backtest_id, category, total, agree, wrong_high, cost_usd, status)
			VALUES (?, ?, ?, ?, ?, ?, ?)`, id, r.Category, r.Total, r.Agree, r.WrongHigh, r.CostUSD, r.Status); err != nil {
			return 0, fmt.Errorf("inserting watchman backtest row %s: %w", r.Category, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("inserting watchman backtest: %w", err)
	}
	return id, nil
}

func (db *DB) watchmanBacktestWhere(where string, workbenchID int64) (*WatchmanBacktest, []WatchmanBacktestRow, error) {
	var b WatchmanBacktest
	var started string
	var fin sql.NullString
	err := db.QueryRow(`SELECT id, workbench_id, started_at, finished_at, status, error, verdict, cost_usd, progress
		FROM watchman_backtests WHERE workbench_id = ? `+where+` ORDER BY id DESC LIMIT 1`, workbenchID).
		Scan(&b.ID, &b.WorkbenchID, &started, &fin, &b.Status, &b.Error, &b.Verdict, &b.CostUSD, &b.Progress)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("reading watchman backtest of workbench %d: %w", workbenchID, err)
	}
	b.StartedAt, _ = time.Parse(time.RFC3339, started)
	if fin.Valid {
		t, _ := time.Parse(time.RFC3339, fin.String)
		b.FinishedAt = &t
	}
	rows, err := db.Query(`SELECT category, total, agree, wrong_high, status, cost_usd FROM watchman_backtest_rows WHERE backtest_id = ? ORDER BY category`, b.ID)
	if err != nil {
		return nil, nil, fmt.Errorf("reading watchman backtest rows %d: %w", b.ID, err)
	}
	defer rows.Close()
	var out []WatchmanBacktestRow
	for rows.Next() {
		var r WatchmanBacktestRow
		if err := rows.Scan(&r.Category, &r.Total, &r.Agree, &r.WrongHigh, &r.Status, &r.CostUSD); err != nil {
			return nil, nil, fmt.Errorf("scanning watchman backtest row: %w", err)
		}
		out = append(out, r)
	}
	return &b, out, rows.Err()
}

// LatestWatchmanBacktest returns the newest backtest of any status (nil when
// there is none) with its rows.
func (db *DB) LatestWatchmanBacktest(workbenchID int64) (*WatchmanBacktest, []WatchmanBacktestRow, error) {
	return db.watchmanBacktestWhere("", workbenchID)
}

// LatestDoneWatchmanBacktest returns the newest backtest with status done, so
// a failed run can still show the last results.
func (db *DB) LatestDoneWatchmanBacktest(workbenchID int64) (*WatchmanBacktest, []WatchmanBacktestRow, error) {
	return db.watchmanBacktestWhere("AND status = 'done'", workbenchID)
}

// SetWatchmanBacktestProgress updates a running backtest's progress line.
func (db *DB) SetWatchmanBacktestProgress(id int64, progress string) error {
	if _, err := db.Exec(`UPDATE watchman_backtests SET progress = ? WHERE id = ?`, progress, id); err != nil {
		return fmt.Errorf("saving watchman backtest %d progress: %w", id, err)
	}
	return nil
}

// FailRunningWatchmanBacktests marks every running backtest of the workbench
// failed with reason and returns how many changed.
func (db *DB) FailRunningWatchmanBacktests(workbenchID int64, reason string, at time.Time) (int, error) {
	res, err := db.Exec(`UPDATE watchman_backtests SET status = 'failed', error = ?, finished_at = ? WHERE workbench_id = ? AND status = 'running'`,
		reason, wmTime(at), workbenchID)
	if err != nil {
		return 0, fmt.Errorf("failing running watchman backtests of workbench %d: %w", workbenchID, err)
	}
	n, err := res.RowsAffected()
	return int(n), err
}
