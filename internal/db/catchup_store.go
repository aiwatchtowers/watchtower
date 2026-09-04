package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// CatchupRef points at one source row a recap item was built from.
type CatchupRef struct {
	Area  string `json:"area"`
	ID    int    `json:"id"`
	Label string `json:"label"`
}

// CatchupRecap is one persisted absence recap (catchup_recaps row).
type CatchupRecap struct {
	ID                     int64
	PeriodFrom, PeriodTo   float64
	Status                 string
	TLDR                   string
	BodyJSON, CoverageJSON string
	Error                  string
	RegenOfID              int64
	AcknowledgedAt         string
	Model                  string
	InputTokens            int
	OutputTokens           int
	CostUSD                float64
	CreatedAt, UpdatedAt   string
}

const catchupRecapCols = `id, period_from, period_to, status, tldr, body_json, coverage_json, error,
	COALESCE(regen_of_id, 0), COALESCE(acknowledged_at, ''), model, input_tokens, output_tokens, cost_usd, created_at, updated_at`

func scanCatchupRecap(s interface{ Scan(...any) error }) (*CatchupRecap, error) {
	var r CatchupRecap
	err := s.Scan(&r.ID, &r.PeriodFrom, &r.PeriodTo, &r.Status, &r.TLDR, &r.BodyJSON, &r.CoverageJSON, &r.Error,
		&r.RegenOfID, &r.AcknowledgedAt, &r.Model, &r.InputTokens, &r.OutputTokens, &r.CostUSD, &r.CreatedAt, &r.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return &r, nil
}

// InsertCatchupRecap creates a recap row in status='building'. regenOfID links a
// regenerated recap to the one it corrects (0 = none).
func (db *DB) InsertCatchupRecap(from, to float64, regenOfID int64) (int64, error) {
	var regen any
	if regenOfID > 0 {
		regen = regenOfID
	}
	res, err := db.Exec(`INSERT INTO catchup_recaps (period_from, period_to, status, regen_of_id) VALUES (?, ?, 'building', ?)`, from, to, regen)
	if err != nil {
		return 0, fmt.Errorf("creating catchup recap: %w", err)
	}
	return res.LastInsertId()
}

// FinishCatchupRecap persists a successful compose and flips status to 'ready'.
func (db *DB) FinishCatchupRecap(id int64, tldr, bodyJSON, coverageJSON, model string, inTok, outTok int, cost float64) error {
	_, err := db.Exec(`UPDATE catchup_recaps SET status='ready', tldr=?, body_json=?, coverage_json=?, model=?,
		input_tokens=?, output_tokens=?, cost_usd=?, error='', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?`,
		tldr, bodyJSON, coverageJSON, model, inTok, outTok, cost, id)
	if err != nil {
		return fmt.Errorf("finishing catchup recap %d: %w", id, err)
	}
	return nil
}

// FailCatchupRecap records a compose/parse failure; whatever coverage was
// computed before the failure is kept for the UI.
func (db *DB) FailCatchupRecap(id int64, coverageJSON, errMsg string) error {
	_, err := db.Exec(`UPDATE catchup_recaps SET status='failed', coverage_json=?, error=?,
		updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?`, coverageJSON, errMsg, id)
	if err != nil {
		return fmt.Errorf("failing catchup recap %d: %w", id, err)
	}
	return nil
}

// GetCatchupRecap returns one recap or a wrapped sql.ErrNoRows.
func (db *DB) GetCatchupRecap(id int64) (*CatchupRecap, error) {
	r, err := scanCatchupRecap(db.QueryRow(`SELECT `+catchupRecapCols+` FROM catchup_recaps WHERE id=?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("catchup recap %d: %w", id, err)
	}
	if err != nil {
		return nil, fmt.Errorf("getting catchup recap %d: %w", id, err)
	}
	return r, nil
}

// ListCatchupRecaps returns the newest recaps first.
func (db *DB) ListCatchupRecaps(limit int) ([]CatchupRecap, error) {
	rows, err := db.Query(`SELECT `+catchupRecapCols+` FROM catchup_recaps ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup recaps: %w", err)
	}
	defer rows.Close()
	var out []CatchupRecap
	for rows.Next() {
		r, err := scanCatchupRecap(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning catchup recap: %w", err)
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}

// LastAcknowledgedCatchupTo returns period_to of the most recently acknowledged
// recap (the "I'm caught up until T" boundary), or 0 when none exists.
func (db *DB) LastAcknowledgedCatchupTo() (float64, error) {
	var to sql.NullFloat64
	err := db.QueryRow(`SELECT MAX(period_to) FROM catchup_recaps WHERE acknowledged_at IS NOT NULL`).Scan(&to)
	if err != nil {
		return 0, fmt.Errorf("reading last acknowledged catchup: %w", err)
	}
	return to.Float64, nil
}

// AcknowledgeCatchupWindow marks everything inside [from, to] read on the five
// read_at surfaces and stamps the recap acknowledged_at (first stamp wins).
// Set-based, one transaction, idempotent (CATCHUP-01).
//
// The two summary surfaces (digests, stream_digests) use the OVERLAP predicate
// `period_to > from AND period_from < to` — the exact predicate the gather uses
// (ListCatchupDigests / ListCatchupStreams). It must stay that way: the run's
// coverage top-up generates fresh digests that stamp their own period_to with
// their own time.Now(), which routinely lands a second or two past the window's
// `to`; a `period_to <= to` ack would cite such a digest in the recap and then
// leave it unread forever, so the badge would lie.
func (db *DB) AcknowledgeCatchupWindow(id int64, from, to float64) error {
	fromISO := time.Unix(int64(from), 0).UTC().Format("2006-01-02T15:04:05Z")
	toISO := time.Unix(int64(to), 0).UTC().Format("2006-01-02T15:04:05Z")
	fromDate := time.Unix(int64(from), 0).Local().Format("2006-01-02")
	toDate := time.Unix(int64(to), 0).Local().Format("2006-01-02")
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("acknowledging catchup %d: %w", id, err)
	}
	defer func() { _ = tx.Rollback() }()
	now := `strftime('%Y-%m-%dT%H:%M:%SZ','now')`
	stmts := []struct {
		q    string
		args []any
	}{
		{`UPDATE digests SET read_at=` + now + ` WHERE read_at IS NULL AND type='channel' AND period_to > ? AND period_from < ?`, []any{from, to}},
		{`UPDATE stream_digests SET read_at=` + now + ` WHERE read_at IS NULL AND period_to > ? AND period_from < ?`, []any{fromISO, toISO}},
		{`UPDATE tracks SET read_at=` + now + `, has_updates=0 WHERE dismissed_at='' AND updated_at > ? AND updated_at <= ? AND (read_at IS NULL OR has_updates=1)`, []any{fromISO, toISO}},
		{`UPDATE inbox_items SET read_at=` + now + ` WHERE read_at IS NULL AND created_at > ? AND created_at <= ?`, []any{fromISO, toISO}},
		{`UPDATE briefings SET read_at=` + now + ` WHERE read_at IS NULL AND date >= ? AND date <= ?`, []any{fromDate, toDate}},
		{`UPDATE catchup_recaps SET acknowledged_at=` + now + `, updated_at=` + now + ` WHERE id=? AND acknowledged_at IS NULL`, []any{id}},
	}
	for _, s := range stmts {
		if _, err := tx.Exec(s.q, s.args...); err != nil {
			return fmt.Errorf("acknowledging catchup %d: %w", id, err)
		}
	}
	return tx.Commit()
}
