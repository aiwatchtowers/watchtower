package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// The twin's work items (00200, spec §6): one row per wait point, queued by
// the writers of the wait, leased by the twin worker, finished in the same
// transaction as the answer. Go never writes the feedback columns (Desktop only).

// WatchmanItem is one wait point and the twin's handling of it.
type WatchmanItem struct {
	ID                  int64
	WorkbenchID         int64
	SessionID, TargetID int64 // 0 = none
	Kind, RefKind       string
	RefID               int64
	State, Outcome      string
	Attempts            int
	Moves               int // review_code: times its diff moved after a decision (00205)
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
		feedback, feedback_text, feedback_at, check_done_at, COALESCE(moves, 0)`
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
		&it.Feedback, &it.FeedbackText, &fbAt, &checkDone, &it.Moves); err != nil {
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
		// Only an owner's live session: none an automation started, none
		// being deleted (NotDeletingSQL), and no ask an automation filed.
		var ownerAsk bool
		if err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM terminal_sessions WHERE id = ? AND automation_run_id IS NULL AND `+NotDeletingSQL+`)
			AND NOT EXISTS (SELECT 1 FROM owner_asks WHERE id = ? AND automation_run_id IS NOT NULL)`, it.SessionID, it.RefID).Scan(&ownerAsk); err != nil {
			return 0, false, fmt.Errorf("reading ask %d's automation: %w", it.RefID, err)
		}
		if !ownerAsk {
			return 0, false, nil
		}
	}
	return db.queueWatchmanItemOnce(it)
}

// watchmanHandoverBeforeWrite runs just before PromoteWatchmanHandover's
// write transaction; a seam for the race test.
var watchmanHandoverBeforeWrite = func() {}

// WatchmanHandoverHeld is the error of a handover item that waits for its
// session's finish gate: finish_session promotes the ask before the Watchman
// review gate runs and holds it there; the lease skips it until a finish
// that passes clears it, so the twin never continues a session that has not
// finished.
const WatchmanHandoverHeld = "waiting for the session's finish check to pass"

// watchmanHeldSQL is WatchmanHandoverHeld as an SQL literal.
var watchmanHeldSQL = `'` + strings.ReplaceAll(WatchmanHandoverHeld, "'", "''") + `'`

// watchmanNotHeld is the lease's filter of a held handover: one whose ask
// still waits for the finish (open, or answered by the twin as a question)
// is skipped; one whose ask went (deleted, withdrawn, answered by the owner)
// is leased, and the twin closes it without a decision.
var watchmanNotHeld = ` AND NOT (kind = 'handover' AND error = ` + watchmanHeldSQL + `
	AND EXISTS (SELECT 1 FROM owner_asks a WHERE a.id = watchman_items.ref_id AND (a.status = 'open'
		OR (a.status IN ('answered','delivered') AND EXISTS (SELECT 1 FROM watchman_items t
			WHERE t.ref_kind = 'ask' AND t.ref_id = a.id AND t.kind != 'handover' AND t.state = 'done' AND t.outcome = 'answered')))))`

// SettleWatchmanHandoversTx settles session's held handovers inside the
// finish's own write transaction (a finish that passed): the one of ask
// askID is released to be decided, every other is closed superseded (a
// retry named another ask, or none). released reports the release.
func (db *DB) SettleWatchmanHandoversTx(tx *sql.Tx, sessionID, askID int64, now time.Time) (released bool, err error) {
	if _, err := tx.Exec(`UPDATE watchman_items SET state = 'done', outcome = 'superseded', error = '', decided_at = ?
		WHERE session_id = ? AND kind = 'handover' AND state = 'queued' AND error = `+watchmanHeldSQL+` AND ref_id != ?`,
		wmTime(now), sessionID, askID); err != nil {
		return false, fmt.Errorf("closing session %d's other handovers: %w", sessionID, err)
	}
	if askID == 0 {
		return false, nil
	}
	res, err := tx.Exec(`UPDATE watchman_items SET error = ''
		WHERE ref_kind = 'ask' AND ref_id = ? AND kind = 'handover' AND state IN ('queued','deciding') AND error = `+watchmanHeldSQL, askID)
	if err != nil {
		return false, fmt.Errorf("releasing the handover of ask %d: %w", askID, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// CloseStaleWatchmanHandovers closes superseded every held handover whose
// session will not pass a finish any more: it ended without one, is being
// deleted or is gone, or is no longer armed (daemon upkeep, every cycle).
func (db *DB) CloseStaleWatchmanHandovers(now time.Time) (int64, error) {
	res, err := db.Exec(`UPDATE watchman_items SET state = 'done', outcome = 'superseded', error = '', decided_at = ?
		WHERE kind = 'handover' AND state = 'queued' AND error = `+watchmanHeldSQL+`
		  AND (NOT EXISTS (SELECT 1 FROM terminal_sessions ts WHERE ts.id = watchman_items.session_id
		                   AND ts.finished_at IS NULL AND ts.`+NotDeletingSQL+`)
		       OR NOT `+watchmanHandoverArmed+`)`, wmTime(now))
	if err != nil {
		return 0, fmt.Errorf("closing stale watchman handovers: %w", err)
	}
	return res.RowsAffected()
}

// PromoteWatchmanHandover makes ask it.RefID the twin's handover in one write
// transaction, held (WatchmanHandoverHeld) when held is true, released when
// it is false: a queued or deciding item of the ask that is not a handover
// yet, or a held one, becomes kind handover with that hold (the twin
// deciding it as a question re-reads the kind in its finish transaction and
// takes it again as a handover). With no item at all a handover is inserted —
// only for an open ask that no automation run filed, of an armed session no
// automation started (QueueWatchmanWaitPoint's guards). An ask the twin
// already answered as a question (its item done, outcome answered) gets a
// second row, the handover, beside it — the earlier answer stays in the
// journal and the twin decides the handover without answering the ask
// again. A handover released or done is left. So a scan or writer racing it
// ends with exactly one handover row. it carries the insert's workbench,
// session, target and question; promoted reports a handover it wrote,
// inserted a new row.
func (db *DB) PromoteWatchmanHandover(it WatchmanItem, held bool) (promoted, inserted bool, err error) {
	watchmanHandoverBeforeWrite()
	q := []rune(it.Question)
	if len(q) > watchmanQuestionMax {
		q = q[:watchmanQuestionMax]
	}
	hold := ""
	if held {
		hold = WatchmanHandoverHeld
	}
	err = db.WithTx(func(tx *sql.Tx) error {
		res, err := tx.Exec(`UPDATE watchman_items SET kind = 'handover', error = ?
			WHERE ref_kind = 'ask' AND ref_id = ? AND state IN ('queued','deciding')
			  AND (kind != 'handover' OR error = ?)`, hold, it.RefID, WatchmanHandoverHeld)
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
		// No row: an open ask. Only a done question the twin answered: that
		// ask, answered or delivered.
		res, err = tx.Exec(`INSERT INTO watchman_items (workbench_id, session_id, target_id, kind, ref_kind, ref_id, question, error, created_at)
			SELECT ?1, ?2, ?3, 'handover', 'ask', ?4, ?5, ?6, ?7
			WHERE NOT EXISTS (SELECT 1 FROM watchman_items WHERE ref_kind = 'ask' AND ref_id = ?4
			                  AND (kind = 'handover' OR state != 'done' OR outcome != 'answered'))
			  AND EXISTS (SELECT 1 FROM owner_asks WHERE id = ?4 AND automation_run_id IS NULL
			              AND CASE WHEN EXISTS (SELECT 1 FROM watchman_items WHERE ref_kind = 'ask' AND ref_id = ?4)
			                   THEN status IN ('answered','delivered') ELSE status = 'open' END)
			  AND EXISTS (SELECT 1 FROM terminal_sessions WHERE id = ?2 AND automation_run_id IS NULL AND `+NotDeletingSQL+`)
			ON CONFLICT(ref_kind, ref_id, kind) DO NOTHING`,
			it.WorkbenchID, wmNullID(it.SessionID), wmNullID(it.TargetID), it.RefID, string(q), hold, wmTime(time.Now()))
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

// WatchmanAskAnsweredByTwin reports whether the twin answered ask askID as a
// question (a done item of the ask, not its handover, outcome answered).
func (db *DB) WatchmanAskAnsweredByTwin(askID int64) (bool, error) {
	var yes bool
	err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM watchman_items WHERE ref_kind = 'ask' AND ref_id = ?
		AND kind != 'handover' AND state = 'done' AND outcome = 'answered')`, askID).Scan(&yes)
	if err != nil {
		return false, fmt.Errorf("reading the twin's answer of ask %d: %w", askID, err)
	}
	return yes, nil
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
		WHERE a.session_id = ? AND a.status = 'open' AND a.automation_run_id IS NULL AND s.automation_run_id IS NULL AND s.`+NotDeletingSQL+`
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

// ParkWatchmanGuard journals one denial of the guard hook (kind guard) as a
// finished parked item, for Waiting for you on the night it happened
// (created_at = decided_at = at). Each denial is its own row: ref_kind
// 'guard' with ref_id the next number after the guard items before it, taken
// in the same statement (00203). it.Question is the denial's line,
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

// LeaseArmedWatchmanItem takes the oldest queued item (not_before reached)
// or deciding item whose lease expired that eligible accepts, and moves it
// to deciding with attempts+1 and lease_until = now+lease. Nil when none.
// The move is a compare-and-set, so two workers never get the same item; it
// also requires the item's session to be armed at that statement
// (armedSessionsFrom; a handover by its arming row), so a disarm between
// the caller's arming read and the lease leaves the item queued
// (WATCHMAN-04). armedOnly false (tests) leaves the arming out.
func (db *DB) LeaseArmedWatchmanItem(now time.Time, lease time.Duration, eligible func(WatchmanItem) bool) (*WatchmanItem, error) {
	return db.leaseWatchmanItem(now, lease, eligible, true)
}

func (db *DB) leaseWatchmanItem(now time.Time, lease time.Duration, eligible func(WatchmanItem) bool, armedOnly bool) (*WatchmanItem, error) {
	armed := ""
	if armedOnly {
		// A handover outlives its session (finish_session ends it): it is
		// leased by its arming row; every other kind needs a live armed session.
		armed = ` AND (CASE WHEN kind = 'handover' THEN ` + watchmanHandoverArmed + `
			ELSE session_id IN (SELECT id FROM (` + armedSessionsFrom + `)) END)`
	}
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
				  AND ((state = 'queued' AND (not_before IS NULL OR not_before <= ?)) OR (state = 'deciding' AND lease_until < ?))`+watchmanNotHeld+armed,
				wmTime(until), c.ID, c.Kind, c.Attempts, nowS, nowS)
			if err != nil {
				return nil, fmt.Errorf("leasing watchman item %d: %w", c.ID, err)
			}
			if n, _ := res.RowsAffected(); n == 0 {
				continue // another worker took it, its kind changed or its session was disarmed
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
		WHERE ((state = 'queued' AND (not_before IS NULL OR not_before <= ?)) OR (state = 'deciding' AND lease_until < ?))`+watchmanNotHeld+`
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
			cost_usd = cost_usd + ?, decided_at = ?, lease_until = NULL
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
	// A handover promoted and held meanwhile keeps its hold.
	res, err := db.Exec(`UPDATE watchman_items SET state = 'queued', lease_until = NULL, not_before = ?,
			error = CASE WHEN kind = 'handover' AND error = ? THEN error ELSE ? END
		WHERE id = ? AND state = 'deciding' AND lease_until = ?`, wmTime(notBefore), WatchmanHandoverHeld, errText, id, wmTime(lease))
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

// ReleaseWatchmanItem hands a deciding item back to the queue as if this
// attempt never ran (attempts-1), not before notBefore — a short backoff, so
// a release that repeats (a kind changed, a read that failed) cannot spin
// the twin's wake-on-finish: the worker stopped (shutdown) or the item
// changed under it. costUSD, what the released attempt's calls cost, is
// added to the item's cost. False when the lease is stale.
func (db *DB) ReleaseWatchmanItem(id int64, lease time.Time, costUSD float64, notBefore time.Time) (bool, error) {
	res, err := db.Exec(`UPDATE watchman_items SET state = 'queued', lease_until = NULL, attempts = MAX(attempts - 1, 0),
			cost_usd = cost_usd + ?, not_before = ?
		WHERE id = ? AND state = 'deciding' AND lease_until = ?`, costUSD, wmTime(notBefore), id, wmTime(lease))
	if err != nil {
		return false, fmt.Errorf("releasing watchman item %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// DeferWatchmanItem hands a deciding item back to the queue, not before
// notBefore, as if this attempt never ran (attempts-1): the item waits for
// something outside the twin (a spec review still running, the owner
// writing review comments), or — moved — its diff moved after the
// decision, counted in moves (never in attempts). costUSD, what the
// attempt's calls cost, is added to the item's cost. False when the lease
// is stale.
func (db *DB) DeferWatchmanItem(id int64, lease, notBefore time.Time, costUSD float64, moved bool) (bool, error) {
	move := 0
	if moved {
		move = 1
	}
	res, err := db.Exec(`UPDATE watchman_items SET state = 'queued', lease_until = NULL, attempts = MAX(attempts - 1, 0),
			not_before = ?, cost_usd = cost_usd + ?, moves = COALESCE(moves, 0) + ?
		WHERE id = ? AND state = 'deciding' AND lease_until = ?`, wmTime(notBefore), costUSD, move, id, wmTime(lease))
	if err != nil {
		return false, fmt.Errorf("deferring watchman item %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// WatchmanTwinReviewRounds counts the review rounds the twin sent on
// sessionID asking for changes since its last Approve there (review_code
// items finished changes after the newest one finished approved).
func (db *DB) WatchmanTwinReviewRounds(sessionID int64) (int, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM watchman_items
		WHERE session_id = ? AND kind = 'review_code' AND state = 'done' AND outcome = 'changes'
		  AND id > COALESCE((SELECT MAX(id) FROM watchman_items
			WHERE session_id = ? AND kind = 'review_code' AND state = 'done' AND outcome = 'approved'), 0)`,
		sessionID, sessionID).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("counting Watchman's review rounds of session %d: %w", sessionID, err)
	}
	return n, nil
}

// WatchmanItemKindTx is item id's kind inside tx (the finish transaction's
// re-read).
func (db *DB) WatchmanItemKindTx(tx *sql.Tx, id int64) (string, error) {
	var kind string
	if err := tx.QueryRow(`SELECT kind FROM watchman_items WHERE id = ?`, id).Scan(&kind); err != nil {
		return "", fmt.Errorf("reading watchman item %d kind: %w", id, err)
	}
	return kind, nil
}

// DoneWatchmanItemsWithError lists answered done items of kind whose error
// is exactly errText, oldest first (a step after the answer still owed).
func (db *DB) DoneWatchmanItemsWithError(kind, errText string) ([]WatchmanItem, error) {
	rows, err := db.Query(`SELECT `+watchmanItemCols+` FROM watchman_items
		WHERE kind = ? AND state = 'done' AND outcome = 'answered' AND error = ? ORDER BY id`, kind, errText)
	if err != nil {
		return nil, fmt.Errorf("listing watchman items with an owed step: %w", err)
	}
	defer rows.Close()
	var out []WatchmanItem
	for rows.Next() {
		it, err := scanWatchmanItem(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *it)
	}
	return out, rows.Err()
}

// SetWatchmanItemError moves a done item's error from was to errText (a
// compare-and-set on the error: the step a later step owes); false when it
// was no longer was.
func (db *DB) SetWatchmanItemError(id int64, was, errText string) (bool, error) {
	res, err := db.Exec(`UPDATE watchman_items SET error = ? WHERE id = ? AND state = 'done' AND error = ?`, errText, id, was)
	if err != nil {
		return false, fmt.Errorf("setting watchman item %d error: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// ClaimWatchmanItemStep is SetWatchmanItemError for a step that is tried a
// bounded number of times: it also counts the try in attempts (reset by
// ResetWatchmanItemAttemptsTx when the step became owed) and returns the
// count. The claim also requires the start's arming (watchmanStartArmed: the
// session's row or an armed target covering the destination) in the same
// statement; claimed false when the
// error was no longer was or the item is no longer armed.
func (db *DB) ClaimWatchmanItemStep(id int64, was, errText string) (tries int, claimed bool, err error) {
	err = db.WithTx(func(tx *sql.Tx) error {
		res, err := tx.Exec(`UPDATE watchman_items SET error = ?, attempts = attempts + 1
			WHERE id = ? AND state = 'done' AND error = ? AND `+watchmanStartArmed,
			errText, id, was)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return nil
		}
		claimed = true
		return tx.QueryRow(`SELECT attempts FROM watchman_items WHERE id = ?`, id).Scan(&tries)
	})
	if err != nil {
		return 0, false, fmt.Errorf("claiming watchman item %d step: %w", id, err)
	}
	return tries, claimed, nil
}

// ResetWatchmanItemAttemptsTx zeroes a finished item's attempts inside tx: the
// count is the owed step's from then on.
func (db *DB) ResetWatchmanItemAttemptsTx(tx *sql.Tx, id int64) error {
	if _, err := tx.Exec(`UPDATE watchman_items SET attempts = 0 WHERE id = ?`, id); err != nil {
		return fmt.Errorf("resetting watchman item %d attempts: %w", id, err)
	}
	return nil
}

// The error of a "Continue" handover whose next session is owed: pending
// until a start claims it, claimed while that start runs.
const (
	WatchmanStartPending = "next session not started yet"
	WatchmanStartClaimed = "next session starting"
)

// watchmanArmedTargets is every target an armed target covers (its subtree).
const watchmanArmedTargets = `WITH RECURSIVE sub(id) AS (
			SELECT ref_id FROM watchman_arming WHERE scope = 'target'
			UNION
			SELECT t.id FROM targets t JOIN sub ON t.parent_id = sub.id
		) SELECT id FROM sub`

// watchmanHandoverArmed is a watchman_items row's arming as a handover
// reads it, finished session or not: its session's own arming row, or an
// armed target covering the item's target or its session's target.
const watchmanHandoverArmed = `(watchman_items.session_id IN (SELECT ref_id FROM watchman_arming WHERE scope = 'session')
	OR watchman_items.target_id IN (` + watchmanArmedTargets + `)
	OR (SELECT ts.target_id FROM terminal_sessions ts WHERE ts.id = watchman_items.session_id AND ts.` + NotDeletingSQL + `)
		IN (` + watchmanArmedTargets + `))`

// watchmanStartArmed authorises starting a handover's next session on the
// item's target (its destination): the session's own arming row, or an armed
// target covering that destination — never the source session's target.
const watchmanStartArmed = `(watchman_items.session_id IN (SELECT ref_id FROM watchman_arming WHERE scope = 'session')
	OR watchman_items.target_id IN (` + watchmanArmedTargets + `))`

// WatchmanStartArmed reports whether the twin may start the next session of
// a handover of session on target (its destination): the session armed
// directly, or target or one of its ancestors armed. The source session's
// own target does not count (WatchmanItemArmed's lease fallback).
func (db *DB) WatchmanStartArmed(sessionID, targetID int64) (bool, error) {
	var n int
	err := db.QueryRow(`WITH RECURSIVE up(id) AS (
			SELECT ? WHERE ? > 0
			UNION
			SELECT t.parent_id FROM targets t JOIN up ON t.id = up.id WHERE t.parent_id IS NOT NULL
		)
		SELECT COUNT(*) FROM watchman_arming
		WHERE (scope = 'session' AND ref_id = ?) OR (scope = 'target' AND ref_id IN (SELECT id FROM up))`,
		targetID, targetID, sessionID).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("checking watchman start arming of session %d / target %d: %w", sessionID, targetID, err)
	}
	return n > 0, nil
}

// WatchmanItemArmed reports whether the twin may still act for an item of
// session and target: the session armed directly, or the item's target, the
// session's target or one of their ancestors armed (the session itself may
// have ended).
func (db *DB) WatchmanItemArmed(sessionID, targetID int64) (bool, error) {
	var n int
	err := db.QueryRow(`WITH RECURSIVE up(id) AS (
			SELECT ? WHERE ? > 0
			UNION
			SELECT target_id FROM terminal_sessions WHERE id = ? AND target_id IS NOT NULL AND `+NotDeletingSQL+`
			UNION
			SELECT t.parent_id FROM targets t JOIN up ON t.id = up.id WHERE t.parent_id IS NOT NULL
		)
		SELECT COUNT(*) FROM watchman_arming
		WHERE (scope = 'session' AND ref_id = ?) OR (scope = 'target' AND ref_id IN (SELECT id FROM up))`,
		targetID, targetID, sessionID, sessionID).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("checking watchman arming of session %d / target %d: %w", sessionID, targetID, err)
	}
	return n > 0, nil
}

// NoteWatchmanItemDelivery records, on a done item, how its answer reached
// the session (the answer's line is typed after the commit that finished the
// item). It never touches error: the finish set it, and a start may have
// moved it since.
func (db *DB) NoteWatchmanItemDelivery(id int64, delivery string) error {
	if _, err := db.Exec(`UPDATE watchman_items SET delivery = ? WHERE id = ? AND state = 'done'`,
		delivery, id); err != nil {
		return fmt.Errorf("noting watchman item %d delivery: %w", id, err)
	}
	return nil
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
