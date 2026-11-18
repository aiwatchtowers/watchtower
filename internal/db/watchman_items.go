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

// WatchmanAskItemKind is the item kind of an ask of askKind: a review is
// review_doc, a check is check, a question (and anything else) is ask.
func WatchmanAskItemKind(askKind string) string {
	switch askKind {
	case "review":
		return "review_doc"
	case "check":
		return "check"
	}
	return "ask"
}

// WatchmanAskText is the text an ask's item shows, before redaction.
func WatchmanAskText(title, summary string) string {
	return strings.TrimSpace(strings.TrimSpace(title) + "\n" + strings.TrimSpace(summary))
}

// WatchmanPermissionText is the text a permission request's item shows,
// before redaction.
func WatchmanPermissionText(tool, summary string) string {
	return strings.TrimSpace("Tool: " + tool + "\n" + strings.TrimSpace(summary))
}

// QueueWatchmanWaitPoint queues it when its session is armed — for an ask,
// one neither an automation run filed nor a session an automation started
// (the scan's filter) — unless the wait point already has an item of any
// kind; id is that item's then, inserted false. id 0 and nothing written
// when the wait point is not the twin's. The arming read and the insert are
// two statements: a disarm between them leaves a queued item the twin does
// not act on (WATCHMAN-04).
func (db *DB) QueueWatchmanWaitPoint(it WatchmanItem) (id int64, inserted bool, err error) {
	if it.SessionID == 0 {
		return 0, false, nil
	}
	armed, err := db.WatchmanSessionArmed(it.SessionID)
	if err != nil || !armed {
		return 0, false, err
	}
	if it.RefKind == "ask" {
		var automation bool
		if err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM terminal_sessions WHERE id = ? AND automation_run_id IS NOT NULL)
			OR EXISTS (SELECT 1 FROM owner_asks WHERE id = ? AND automation_run_id IS NOT NULL)`, it.SessionID, it.RefID).Scan(&automation); err != nil {
			return 0, false, fmt.Errorf("reading ask %d's automation: %w", it.RefID, err)
		}
		if automation {
			return 0, false, nil
		}
	}
	return db.queueWatchmanItemOnce(it)
}

// watchmanHandoverBeforeWrite runs just before PromoteWatchmanHandover's
// write transaction; a seam for the race test.
var watchmanHandoverBeforeWrite = func() {}

// PromoteWatchmanHandover makes ask it.RefID the twin's handover in one write
// transaction: a queued item of the ask, whatever its kind, becomes kind
// handover; with no item at all a handover is inserted — only for an open
// ask that no automation run filed, of an armed session no automation
// started (QueueWatchmanWaitPoint's guards). An item already deciding or done
// is left. So a scan or writer racing it ends with exactly one handover row.
// it carries the insert's workbench, session, target and question; promoted
// reports a queued handover it wrote, inserted a new row.
func (db *DB) PromoteWatchmanHandover(it WatchmanItem) (promoted, inserted bool, err error) {
	watchmanHandoverBeforeWrite()
	q := []rune(it.Question)
	if len(q) > watchmanQuestionMax {
		q = q[:watchmanQuestionMax]
	}
	err = db.WithTx(func(tx *sql.Tx) error {
		res, err := tx.Exec(`UPDATE watchman_items SET kind = 'handover'
			WHERE ref_kind = 'ask' AND ref_id = ? AND state = 'queued' AND kind != 'handover'`, it.RefID)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			promoted = true
			return nil
		}
		var armed int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM (`+armedSessionsFrom+` AND ts.id = ?)`, it.SessionID).Scan(&armed); err != nil {
			return err
		}
		if armed == 0 {
			return nil
		}
		res, err = tx.Exec(`INSERT INTO watchman_items (workbench_id, session_id, target_id, kind, ref_kind, ref_id, question, created_at)
			SELECT ?, ?, ?, 'handover', 'ask', ?, ?, ?
			WHERE NOT EXISTS (SELECT 1 FROM watchman_items WHERE ref_kind = 'ask' AND ref_id = ?)
			  AND EXISTS (SELECT 1 FROM owner_asks WHERE id = ? AND status = 'open' AND automation_run_id IS NULL)
			  AND NOT EXISTS (SELECT 1 FROM terminal_sessions WHERE id = ? AND automation_run_id IS NOT NULL)
			ON CONFLICT(ref_kind, ref_id, kind) DO NOTHING`,
			it.WorkbenchID, wmNullID(it.SessionID), wmNullID(it.TargetID), it.RefID, string(q), wmTime(time.Now()),
			it.RefID, it.RefID, it.SessionID)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		inserted = n > 0
		promoted = inserted
		return nil
	})
	if err != nil {
		return false, false, fmt.Errorf("marking ask %d Watchman's handover: %w", it.RefID, err)
	}
	return promoted, inserted, nil
}

// watchmanScanBeforeInsert runs between the scan's read and its inserts; a
// seam for the race test.
var watchmanScanBeforeInsert = func() {}

// queueWatchmanItemOnce inserts it queued unless (ref_kind, ref_id) already
// has an item of any kind — one statement, so a writer racing the scan, or
// an item whose kind changed (a handover), never gets a second row. When
// one exists, its id (the oldest) is returned with inserted false.
func (db *DB) queueWatchmanItemOnce(it WatchmanItem) (id int64, inserted bool, err error) {
	created := it.CreatedAt
	if created.IsZero() {
		created = time.Now()
	}
	q := []rune(it.Question)
	if len(q) > watchmanQuestionMax {
		q = q[:watchmanQuestionMax]
	}
	res, err := db.Exec(`INSERT INTO watchman_items (workbench_id, session_id, target_id, kind, ref_kind, ref_id, not_before, question, created_at)
		SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
		WHERE NOT EXISTS (SELECT 1 FROM watchman_items WHERE ref_kind = ? AND ref_id = ?)
		ON CONFLICT(ref_kind, ref_id, kind) DO NOTHING`,
		it.WorkbenchID, wmNullID(it.SessionID), wmNullID(it.TargetID), it.Kind, it.RefKind, it.RefID, wmNullTime(it.NotBefore), string(q), wmTime(created),
		it.RefKind, it.RefID)
	if err != nil {
		return 0, false, fmt.Errorf("queueing watchman item %s/%d: %w", it.RefKind, it.RefID, err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		id, err = res.LastInsertId()
		return id, true, err
	}
	err = db.QueryRow(`SELECT id FROM watchman_items WHERE ref_kind = ? AND ref_id = ? ORDER BY id LIMIT 1`, it.RefKind, it.RefID).Scan(&id)
	if err != nil {
		return 0, false, fmt.Errorf("reading queued watchman item %s/%d: %w", it.RefKind, it.RefID, err)
	}
	return id, false, nil
}

// WatchmanItemByRef is the item of kind for wait point (refKind, refID);
// nil when there is none.
func (db *DB) WatchmanItemByRef(refKind string, refID int64, kind string) (*WatchmanItem, error) {
	it, err := scanWatchmanItem(db.QueryRow(`SELECT `+watchmanItemCols+` FROM watchman_items
		WHERE ref_kind = ? AND ref_id = ? AND kind = ?`, refKind, refID, kind))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading watchman item %s/%d: %w", refKind, refID, err)
	}
	return it, nil
}

// ScanWatchmanWaitPoints queues the wait points of armed sessions that have
// no item: open asks (none of an automation's) and pending permission
// requests — the recovery of a writer whose insert failed (spec §7).
// question turns an item's text into its stored question (redacted and
// clipped; internal/db cannot import the redactor). n is how many it queued.
func (db *DB) ScanWatchmanWaitPoints(now time.Time, question func(string) string) (n int, err error) {
	sessions, err := db.WatchmanArmedSessions()
	if err != nil {
		return 0, err
	}
	var missed []WatchmanItem
	for _, s := range sessions {
		items, err := db.watchmanMissedWaitPoints(s.SessionID)
		if err != nil {
			return 0, err
		}
		missed = append(missed, items...)
	}
	watchmanScanBeforeInsert()
	for _, it := range missed {
		it.Question, it.CreatedAt = question(it.Question), now
		if _, inserted, err := db.queueWatchmanItemOnce(it); err != nil {
			return n, err
		} else if inserted {
			n++
		}
	}
	return n, nil
}

// watchmanMissedWaitPoints lists session's open asks (not an automation's)
// and pending permission requests with no item of any kind, their Question
// the unredacted text.
func (db *DB) watchmanMissedWaitPoints(session int64) ([]WatchmanItem, error) {
	rows, err := db.Query(`SELECT 'ask', a.id, a.project_id, COALESCE(a.target_id, 0), a.kind, a.title, a.summary
		FROM owner_asks a JOIN terminal_sessions s ON s.id = a.session_id
		WHERE a.session_id = ? AND a.status = 'open' AND a.automation_run_id IS NULL AND s.automation_run_id IS NULL
		  AND NOT EXISTS (SELECT 1 FROM watchman_items w WHERE w.ref_kind = 'ask' AND w.ref_id = a.id)
		UNION ALL
		SELECT 'permission', r.id, r.workbench_id, 0, '', r.tool_name, r.summary
		FROM permission_requests r
		WHERE r.terminal_session_id = ? AND r.status = 'pending'
		  AND NOT EXISTS (SELECT 1 FROM watchman_items w WHERE w.ref_kind = 'permission' AND w.ref_id = r.id)
		ORDER BY 1, 2`, session, session)
	if err != nil {
		return nil, fmt.Errorf("scanning watchman wait points of session %d: %w", session, err)
	}
	defer rows.Close()
	var out []WatchmanItem
	for rows.Next() {
		it := WatchmanItem{SessionID: session}
		var askKind, a, b string
		if err := rows.Scan(&it.RefKind, &it.RefID, &it.WorkbenchID, &it.TargetID, &askKind, &a, &b); err != nil {
			return nil, err
		}
		if it.RefKind == "ask" {
			it.Kind, it.Question = WatchmanAskItemKind(askKind), WatchmanAskText(a, b)
		} else {
			it.Kind, it.Question = "permission", WatchmanPermissionText(a, b)
		}
		out = append(out, it)
	}
	return out, rows.Err()
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

// DropWatchmanItem deletes a deciding item under the caller's lease — its
// wait point went away before the twin answered (the ask was withdrawn or
// superseded), so there is nothing to journal; false when the lease is stale.
func (db *DB) DropWatchmanItem(id int64, lease time.Time) (bool, error) {
	res, err := db.Exec(`DELETE FROM watchman_items WHERE id = ? AND state = 'deciding' AND lease_until = ?`, id, wmTime(lease))
	if err != nil {
		return false, fmt.Errorf("dropping watchman item %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// NoteWatchmanItemDelivery records, on a done item, how its answer reached
// the session (the answer's line is typed after the commit that finished the
// item) and an error of a step after it ("" keeps none).
func (db *DB) NoteWatchmanItemDelivery(id int64, delivery, errText string) error {
	if _, err := db.Exec(`UPDATE watchman_items SET delivery = ?, error = ? WHERE id = ? AND state = 'done'`,
		delivery, errText, id); err != nil {
		return fmt.Errorf("noting watchman item %d delivery: %w", id, err)
	}
	return nil
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
