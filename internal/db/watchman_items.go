package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// The twin's work items (00198, spec §6): one row per wait point, queued by
// the writers of the wait, leased by the twin worker, finished in the same
// transaction as the answer. Go never writes the feedback columns (Desktop only).

// ErrWatchmanItemExists reports that the wait point already has an item of the target kind.
var ErrWatchmanItemExists = errors.New("watchman item of that kind already exists")

// WatchmanItem is one wait point and the twin's handling of it.
type WatchmanItem struct {
	ID                  int64
	WorkbenchID         int64
	SessionID, TargetID int64 // 0 = none
	Kind, RefKind       string
	RefID               int64
	State, Outcome      string
	Attempts            int
	LeaseUntil          *time.Time
	NotBefore           *time.Time
	Question            string // redacted, at most 2048 runes
	Choice, Rationale   string
	PrecedentIDs        []int64
	Confidence          string
	Importance          string
	Category            string
	Unsure              bool
	ParkReason          string
	Delivery            string
	RoundID             int64
	CostUSD             float64
	Error               string
	CreatedAt           time.Time
	DecidedAt           *time.Time
	Feedback            string
	FeedbackText        string
	FeedbackAt          *time.Time
	CheckDoneAt         *time.Time
}

// WatchmanOutcome is what a finished item records.
type WatchmanOutcome struct {
	Outcome, Choice, Rationale, Confidence, Importance, Category, ParkReason, Delivery, Error string
	PrecedentIDs                                                                              []int64
	RoundID                                                                                   int64
	CostUSD                                                                                   float64
	DecidedAt                                                                                 time.Time
}

// WatchmanExtraLimit is a limit the owner added to the built-in table.
type WatchmanExtraLimit struct {
	ID            int64
	Kind, Pattern string
}

const (
	watchmanQuestionMax  = 2048
	watchmanLeaseScanMax = 200
	watchmanItemCols     = `id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome, attempts,
		lease_until, not_before, question, choice, rationale, precedent_ids, confidence, importance, category,
		unsure, park_reason, delivery, round_id, cost_usd, error, created_at, decided_at,
		feedback, feedback_text, feedback_at, check_done_at`
)

func wmNullTime(t *time.Time) any {
	if t == nil {
		return nil
	}
	return wmTime(*t)
}

func wmNullID(id int64) any {
	if id == 0 {
		return nil
	}
	return id
}

func wmParseNullTime(s sql.NullString) (*time.Time, error) {
	if !s.Valid || s.String == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339, s.String)
	if err != nil {
		return nil, fmt.Errorf("parsing watchman time %q: %w", s.String, err)
	}
	return &t, nil
}

func scanWatchmanItem(sc interface{ Scan(...any) error }) (*WatchmanItem, error) {
	var it WatchmanItem
	var sess, tgt, round sql.NullInt64
	var lease, notBefore, decided, fbAt, checkDone sql.NullString
	var prec, created string
	var unsure int
	if err := sc.Scan(&it.ID, &it.WorkbenchID, &sess, &tgt, &it.Kind, &it.RefKind, &it.RefID, &it.State, &it.Outcome, &it.Attempts,
		&lease, &notBefore, &it.Question, &it.Choice, &it.Rationale, &prec, &it.Confidence, &it.Importance, &it.Category,
		&unsure, &it.ParkReason, &it.Delivery, &round, &it.CostUSD, &it.Error, &created, &decided,
		&it.Feedback, &it.FeedbackText, &fbAt, &checkDone); err != nil {
		return nil, err
	}
	it.SessionID, it.TargetID, it.RoundID = sess.Int64, tgt.Int64, round.Int64
	it.Unsure = unsure != 0
	if prec != "" {
		if err := json.Unmarshal([]byte(prec), &it.PrecedentIDs); err != nil {
			return nil, fmt.Errorf("parsing watchman precedent ids %q: %w", prec, err)
		}
	}
	var err error
	if it.CreatedAt, err = time.Parse(time.RFC3339, created); err != nil {
		return nil, fmt.Errorf("parsing watchman created_at %q: %w", created, err)
	}
	for _, f := range []struct {
		in  sql.NullString
		out **time.Time
	}{{lease, &it.LeaseUntil}, {notBefore, &it.NotBefore}, {decided, &it.DecidedAt}, {fbAt, &it.FeedbackAt}, {checkDone, &it.CheckDoneAt}} {
		if *f.out, err = wmParseNullTime(f.in); err != nil {
			return nil, err
		}
	}
	return &it, nil
}

// QueueWatchmanItem inserts a queued item; a wait point already queued (same
// ref_kind, ref_id, kind) is left alone and its id returned with inserted false.
func (db *DB) QueueWatchmanItem(it WatchmanItem) (id int64, inserted bool, err error) {
	created := it.CreatedAt
	if created.IsZero() {
		created = time.Now()
	}
	q := []rune(it.Question)
	if len(q) > watchmanQuestionMax {
		q = q[:watchmanQuestionMax]
	}
	res, err := db.Exec(`INSERT INTO watchman_items (workbench_id, session_id, target_id, kind, ref_kind, ref_id, not_before, question, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(ref_kind, ref_id, kind) DO NOTHING`,
		it.WorkbenchID, wmNullID(it.SessionID), wmNullID(it.TargetID), it.Kind, it.RefKind, it.RefID, wmNullTime(it.NotBefore), string(q), wmTime(created))
	if err != nil {
		return 0, false, fmt.Errorf("queueing watchman item %s/%d: %w", it.RefKind, it.RefID, err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		id, err = res.LastInsertId()
		return id, true, err
	}
	err = db.QueryRow(`SELECT id FROM watchman_items WHERE ref_kind = ? AND ref_id = ? AND kind = ?`, it.RefKind, it.RefID, it.Kind).Scan(&id)
	if err != nil {
		return 0, false, fmt.Errorf("reading queued watchman item %s/%d: %w", it.RefKind, it.RefID, err)
	}
	return id, false, nil
}

// ParkWatchmanGuard journals one denial of the guard hook (kind guard) as a
// finished parked item, for Waiting for you on the night it happened
// (created_at = decided_at = at). Each denial is its own row: ref_kind
// 'guard' with ref_id the next number after the guard items before it, taken
// in the same statement (00201). it.Question is the denial's line,
// it.ParkReason names the limit.
func (db *DB) ParkWatchmanGuard(it WatchmanItem, at time.Time) error {
	q := []rune(it.Question)
	if len(q) > watchmanQuestionMax {
		q = q[:watchmanQuestionMax]
	}
	_, err := db.Exec(`INSERT INTO watchman_items (workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome,
			question, park_reason, created_at, decided_at)
		SELECT ?, ?, ?, 'guard', 'guard', COALESCE(MAX(ref_id), 0) + 1, 'done', 'parked', ?, ?, ?, ?
		FROM watchman_items WHERE ref_kind = 'guard'`,
		it.WorkbenchID, wmNullID(it.SessionID), wmNullID(it.TargetID), string(q), it.ParkReason, wmTime(at), wmTime(at))
	if err != nil {
		return fmt.Errorf("journalling the watchman guard denial of session %d: %w", it.SessionID, err)
	}
	return nil
}

// LeaseWatchmanItem takes the oldest queued item (not_before reached) or
// deciding item whose lease expired that eligible accepts, and moves it to
// deciding with attempts+1 and lease_until = now+lease. Nil when none. The
// move is a compare-and-set, so two workers never get the same item.
func (db *DB) LeaseWatchmanItem(now time.Time, lease time.Duration, eligible func(WatchmanItem) bool) (*WatchmanItem, error) {
	nowS := wmTime(now)
	until := now.Add(lease)
	afterCreated, afterID := "", int64(0)
	for {
		cands, err := db.watchmanLeaseCandidates(nowS, afterCreated, afterID)
		if err != nil {
			return nil, err
		}
		for _, c := range cands {
			if eligible != nil && !eligible(*c) {
				continue
			}
			res, err := db.Exec(`UPDATE watchman_items SET state = 'deciding', attempts = attempts + 1, lease_until = ?
				WHERE id = ? AND kind = ? AND attempts = ?
				  AND ((state = 'queued' AND (not_before IS NULL OR not_before <= ?)) OR (state = 'deciding' AND lease_until < ?))`,
				wmTime(until), c.ID, c.Kind, c.Attempts, nowS, nowS)
			if err != nil {
				return nil, fmt.Errorf("leasing watchman item %d: %w", c.ID, err)
			}
			if n, _ := res.RowsAffected(); n == 0 {
				continue // another worker took it, or its kind changed
			}
			c.State, c.Attempts = "deciding", c.Attempts+1
			u := until.UTC().Truncate(time.Second)
			c.LeaseUntil = &u
			return c, nil
		}
		if len(cands) < watchmanLeaseScanMax {
			return nil, nil
		}
		last := cands[len(cands)-1]
		afterCreated, afterID = wmTime(last.CreatedAt), last.ID
	}
}

// watchmanLeaseCandidates returns one page of leasable items after the
// (created_at, id) cursor, oldest first.
func (db *DB) watchmanLeaseCandidates(nowS, afterCreated string, afterID int64) ([]*WatchmanItem, error) {
	rows, err := db.Query(`SELECT `+watchmanItemCols+` FROM watchman_items
		WHERE ((state = 'queued' AND (not_before IS NULL OR not_before <= ?)) OR (state = 'deciding' AND lease_until < ?))
		  AND (created_at > ? OR (created_at = ? AND id > ?))
		ORDER BY created_at, id LIMIT ?`, nowS, nowS, afterCreated, afterCreated, afterID, watchmanLeaseScanMax)
	if err != nil {
		return nil, fmt.Errorf("scanning watchman items: %w", err)
	}
	defer rows.Close()
	var out []*WatchmanItem
	for rows.Next() {
		it, err := scanWatchmanItem(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

// CountDecidingWatchmanItems counts items whose lease is still running.
func (db *DB) CountDecidingWatchmanItems(now time.Time) (int, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM watchman_items WHERE state = 'deciding' AND lease_until >= ?`, wmTime(now)).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("counting deciding watchman items: %w", err)
	}
	return n, nil
}

// FinishWatchmanItemTx records the outcome inside tx (the answer's transaction)
// while the item is still deciding under the lease the caller holds; false
// when the lease is stale and nothing was written.
func (db *DB) FinishWatchmanItemTx(tx *sql.Tx, id int64, lease time.Time, o WatchmanOutcome) (bool, error) {
	prec := o.PrecedentIDs
	if prec == nil {
		prec = []int64{}
	}
	precJSON, err := json.Marshal(prec)
	if err != nil {
		return false, err
	}
	decided := o.DecidedAt
	if decided.IsZero() {
		decided = time.Now()
	}
	res, err := tx.Exec(`UPDATE watchman_items SET state = 'done', outcome = ?, choice = ?, rationale = ?, confidence = ?,
			importance = ?, category = ?, park_reason = ?, delivery = ?, error = ?, precedent_ids = ?, round_id = ?,
			cost_usd = ?, decided_at = ?, lease_until = NULL
		WHERE id = ? AND state = 'deciding' AND lease_until = ?`,
		o.Outcome, o.Choice, o.Rationale, o.Confidence, o.Importance, o.Category, o.ParkReason, o.Delivery, o.Error,
		string(precJSON), wmNullID(o.RoundID), o.CostUSD, wmTime(decided), id, wmTime(lease))
	if err != nil {
		return false, fmt.Errorf("finishing watchman item %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// RequeueWatchmanItem hands a deciding item back to the queue, not before
// notBefore, keeping errText; false when the lease is stale.
func (db *DB) RequeueWatchmanItem(id int64, lease time.Time, notBefore time.Time, errText string) (bool, error) {
	res, err := db.Exec(`UPDATE watchman_items SET state = 'queued', lease_until = NULL, not_before = ?, error = ?
		WHERE id = ? AND state = 'deciding' AND lease_until = ?`, wmTime(notBefore), errText, id, wmTime(lease))
	if err != nil {
		return false, fmt.Errorf("requeueing watchman item %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// SetWatchmanItemKind changes the kind of a still queued item.
func (db *DB) SetWatchmanItemKind(refKind string, refID int64, from, to string) (bool, error) {
	res, err := db.Exec(`UPDATE watchman_items SET kind = ? WHERE ref_kind = ? AND ref_id = ? AND kind = ? AND state = 'queued'`,
		to, refKind, refID, from)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed") {
			return false, fmt.Errorf("changing watchman item kind %s/%d to %s: %w", refKind, refID, to, ErrWatchmanItemExists)
		}
		return false, fmt.Errorf("changing watchman item kind %s/%d: %w", refKind, refID, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// AddWatchmanGap records a span the Mac slept through.
func (db *DB) AddWatchmanGap(start, end time.Time) error {
	if _, err := db.Exec(`INSERT INTO watchman_gaps (started_at, ended_at) VALUES (?, ?)`, wmTime(start), wmTime(end)); err != nil {
		return fmt.Errorf("adding watchman gap: %w", err)
	}
	return nil
}

// WatchmanExtraLimits lists the owner's added limits, oldest first.
func (db *DB) WatchmanExtraLimits() ([]WatchmanExtraLimit, error) {
	rows, err := db.Query(`SELECT id, kind, pattern FROM watchman_extra_limits ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing watchman extra limits: %w", err)
	}
	defer rows.Close()
	var out []WatchmanExtraLimit
	for rows.Next() {
		var l WatchmanExtraLimit
		if err := rows.Scan(&l.ID, &l.Kind, &l.Pattern); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// AddWatchmanExtraLimit adds a limit; the same (kind, pattern) again returns its id.
func (db *DB) AddWatchmanExtraLimit(kind, pattern string) (int64, error) {
	if _, err := db.Exec(`INSERT INTO watchman_extra_limits (kind, pattern, created_at) VALUES (?, ?, ?)
		ON CONFLICT(kind, pattern) DO NOTHING`, kind, pattern, wmTime(time.Now())); err != nil {
		return 0, fmt.Errorf("adding watchman extra limit: %w", err)
	}
	var id int64
	if err := db.QueryRow(`SELECT id FROM watchman_extra_limits WHERE kind = ? AND pattern = ?`, kind, pattern).Scan(&id); err != nil {
		return 0, fmt.Errorf("reading watchman extra limit: %w", err)
	}
	return id, nil
}

// DeleteWatchmanExtraLimit removes one added limit; false when it was gone.
func (db *DB) DeleteWatchmanExtraLimit(id int64) (bool, error) {
	res, err := db.Exec(`DELETE FROM watchman_extra_limits WHERE id = ?`, id)
	if err != nil {
		return false, fmt.Errorf("deleting watchman extra limit %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}
