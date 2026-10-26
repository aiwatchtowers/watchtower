package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Spec review storage (00158): one reviewer-agent run per review ask, plus the
// owner's per-item marks. See docs/superpowers/specs/2026-10-25-spec-review-design.md.

// ErrSpecReviewNotFound is returned when an ask has no spec_reviews row.
var ErrSpecReviewNotFound = errors.New("spec review not found")

// ErrSpecReviewBusy refuses RequeueSpecReview: the row is running, or it is
// finished and force was not given. Its text names the status.
var ErrSpecReviewBusy = errors.New("spec review not re-queued")

// queuedStaleAfter is how long a queued row waits before the sweep picks it up.
const queuedStaleAfter = 60 * time.Second

// SpecReview is one spec_reviews row.
type SpecReview struct {
	AskID                           int64
	Status, Reason, Result          string
	Provider, Model, DocSHA         string
	Dropped, PID, Attempt           int
	QueuedAt, StartedAt, FinishedAt string
	// Author loop (00160). The JSON columns are written by the loop code.
	Loop, Replies, OpenItems, Ledger, LoopEnd string
	Round                                     int
}

// SpecLoopStart starts (or advances) an author loop when queueing a review.
type SpecLoopStart struct {
	Round   int
	Replies string
}

// SpecLoopRow is one open author-loop review for the sweep.
type SpecLoopRow struct {
	AskID        int64
	Status       string
	FinishedAt   string
	SessionBound bool
}

// SpecReviewMark is the owner's mark on one item (Desktop-written). About is
// a comment's finding text, kept so a comment whose finding a re-run drops
// still says what it was about.
type SpecReviewMark struct {
	State, Body, About, UpdatedAt string
}

func specReviewTime(t time.Time) string { return t.UTC().Format(automationTimeLayout) }

// ParseSpecReviewTime reads a spec_reviews timestamp (queued_at, started_at,
// finished_at: the form specReviewTime writes).
func ParseSpecReviewTime(s string) (time.Time, error) { return time.Parse(automationTimeLayout, s) }

const specReviewCols = `ask_id, status, reason, result, provider, model, doc_sha, dropped, pid, attempt,
	queued_at, started_at, finished_at, loop, round, replies, open_items, ledger, loop_end`

func scanSpecReview(row interface{ Scan(...any) error }) (*SpecReview, error) {
	var r SpecReview
	if err := row.Scan(&r.AskID, &r.Status, &r.Reason, &r.Result, &r.Provider, &r.Model, &r.DocSHA,
		&r.Dropped, &r.PID, &r.Attempt, &r.QueuedAt, &r.StartedAt, &r.FinishedAt,
			&r.Loop, &r.Round, &r.Replies, &r.OpenItems, &r.Ledger, &r.LoopEnd); err != nil {
		return nil, fmt.Errorf("scanning spec review: %w", err)
	}
	return &r, nil
}

// QueueSpecReview upserts the ask's review to queued inside the caller's
// transaction: result, reason and pid are cleared, marks are kept and attempt
// grows by one. A nil loop keeps every loop column; a non-nil loop sets
// loop='author', round and replies and clears open_items, ledger and loop_end.
func (db *DB) QueueSpecReview(tx *sql.Tx, askID int64, now time.Time, loop *SpecLoopStart) error {
	const base = `INSERT INTO spec_reviews (ask_id, status, attempt, queued_at%s)
		VALUES (?, 'queued', 1, ?%s)
		ON CONFLICT(ask_id) DO UPDATE SET status = 'queued', reason = '', result = '', provider = '',
			model = '', doc_sha = '', dropped = 0, pid = 0, attempt = attempt + 1,
			queued_at = excluded.queued_at, started_at = '', finished_at = ''%s`
	var err error
	if loop == nil {
		_, err = tx.Exec(fmt.Sprintf(base, "", "", ""), askID, specReviewTime(now))
	} else {
		_, err = tx.Exec(fmt.Sprintf(base, ", loop, round, replies", ", 'author', ?, ?",
			", loop = 'author', round = excluded.round, replies = excluded.replies, open_items = '', ledger = '', loop_end = ''"),
			askID, specReviewTime(now), loop.Round, loop.Replies)
	}
	if err != nil {
		return fmt.Errorf("queueing spec review: %w", err)
	}
	return nil
}

// RequeueSpecReview queues the ask's review for a run the owner asked for, in
// one transaction: no row is queued anew, a queued row stays queued (it is
// launched again), a running row is refused, and a done|failed|skipped row is
// re-queued only with force. A refusal wraps ErrSpecReviewBusy. The owner's
// run starts the launch count over (attempt = 1): the sweep's cap counts its
// own relaunches only.
func (db *DB) RequeueSpecReview(askID int64, force bool, now time.Time) error {
	return db.WithTx(func(tx *sql.Tx) error {
		var status string
		err := tx.QueryRow(`SELECT status FROM spec_reviews WHERE ask_id = ?`, askID).Scan(&status)
		switch {
		case errors.Is(err, sql.ErrNoRows):
		case err != nil:
			return fmt.Errorf("reading spec review: %w", err)
		case status == "queued":
		case status == "running":
			return fmt.Errorf("%w: already running", ErrSpecReviewBusy)
		case !force:
			return fmt.Errorf("%w: it is %s (--force runs it again)", ErrSpecReviewBusy, status)
		}
		if status != "queued" {
			if err := db.QueueSpecReview(tx, askID, now, nil); err != nil {
				return fmt.Errorf("re-queueing spec review: %w", err)
			}
		}
		if _, err := tx.Exec(`UPDATE spec_reviews SET attempt = 1 WHERE ask_id = ?`, askID); err != nil {
			return fmt.Errorf("resetting spec review attempts: %w", err)
		}
		return nil
	})
}

// RelaunchQueuedSpecReview is the sweep's re-queue: it counts one more launch
// (attempt + 1, the minute restarts) only while the row is still queued and
// has launches left (attempt < maxAttempts), so a row a slow reviewer has just
// claimed is never reset. True when the row was re-queued and is to be
// launched; false when it is no longer queued or out of launches.
func (db *DB) RelaunchQueuedSpecReview(askID int64, maxAttempts int, now time.Time) (bool, error) {
	res, err := db.Exec(`UPDATE spec_reviews SET attempt = attempt + 1, queued_at = ?, pid = 0
		WHERE ask_id = ? AND status = 'queued' AND attempt < ?`, specReviewTime(now), askID, maxAttempts)
	if err != nil {
		return false, fmt.Errorf("re-queueing spec review: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("re-queueing spec review: %w", err)
	}
	return n == 1, nil
}

// SkipSpecReview records that no review runs for the ask, and why.
func (db *DB) SkipSpecReview(askID int64, reason string, now time.Time) error {
	ts := specReviewTime(now)
	_, err := db.Exec(`INSERT INTO spec_reviews (ask_id, status, reason, queued_at, finished_at)
		VALUES (?, 'skipped', ?, ?, ?)
		ON CONFLICT(ask_id) DO UPDATE SET status = 'skipped', reason = excluded.reason, result = '',
			pid = 0, finished_at = excluded.finished_at`,
		askID, reason, ts, ts)
	if err != nil {
		return fmt.Errorf("skipping spec review: %w", err)
	}
	return nil
}

// ClaimSpecReview moves queued to running for pid; false when the row is not
// queued (someone else owns it).
func (db *DB) ClaimSpecReview(askID int64, pid int, now time.Time) (bool, error) {
	res, err := db.Exec(`UPDATE spec_reviews SET status = 'running', pid = ?, started_at = ?
		WHERE ask_id = ? AND status = 'queued'`, pid, specReviewTime(now), askID)
	if err != nil {
		return false, fmt.Errorf("claiming spec review: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("claiming spec review: %w", err)
	}
	return n == 1, nil
}

// FinishSpecReview stores r's result as done, only while the row is running
// under pid; any other state is a no-op. Loop, OpenItems, Ledger and LoopEnd
// are written only while the row's loop is 'author'; an 'owner' row keeps them.
func (db *DB) FinishSpecReview(askID int64, pid int, r SpecReview, now time.Time) error {
	_, err := db.Exec(`UPDATE spec_reviews SET status = 'done', result = ?, provider = ?, model = ?,
		doc_sha = ?, dropped = ?, reason = '', finished_at = ?,
			open_items = CASE WHEN loop = 'author' THEN ? ELSE open_items END,
			ledger = CASE WHEN loop = 'author' THEN ? ELSE ledger END,
			loop_end = CASE WHEN loop = 'author' THEN ? ELSE loop_end END,
			loop = CASE WHEN loop = 'author' THEN ? ELSE loop END
		WHERE ask_id = ? AND status = 'running' AND pid = ?`,
		r.Result, r.Provider, r.Model, r.DocSHA, r.Dropped, specReviewTime(now),
		r.OpenItems, r.Ledger, r.LoopEnd, r.Loop, askID, pid)
	if err != nil {
		return fmt.Errorf("finishing spec review: %w", err)
	}
	return nil
}

// FailSpecReview records a failure with reason, with FinishSpecReview's guard.
func (db *DB) FailSpecReview(askID int64, pid int, reason string, now time.Time) error {
	_, err := db.Exec(`UPDATE spec_reviews SET status = 'failed', reason = ?, finished_at = ?
		WHERE ask_id = ? AND status = 'running' AND pid = ?`,
		reason, specReviewTime(now), askID, pid)
	if err != nil {
		return fmt.Errorf("failing spec review: %w", err)
	}
	return nil
}

// GetSpecReview returns the ask's review, or ErrSpecReviewNotFound.
func (db *DB) GetSpecReview(askID int64) (*SpecReview, error) {
	r, err := scanSpecReview(db.QueryRow(`SELECT `+specReviewCols+` FROM spec_reviews WHERE ask_id = ?`, askID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSpecReviewNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("reading spec review: %w", err)
	}
	return r, nil
}

// SpecReviewsToSweep lists the queued reviews older than 60 s (ask ids) and
// every running review; the caller checks the running rows' pids.
func (db *DB) SpecReviewsToSweep(now time.Time) (queued []int64, running []SpecReview, err error) {
	rows, err := db.Query(`SELECT ask_id FROM spec_reviews WHERE status = 'queued' AND queued_at <= ?
		ORDER BY ask_id`, specReviewTime(now.Add(-queuedStaleAfter)))
	if err != nil {
		return nil, nil, fmt.Errorf("listing queued spec reviews: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, nil, fmt.Errorf("scanning queued spec review: %w", err)
		}
		queued = append(queued, id)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("listing queued spec reviews: %w", err)
	}
	rrows, err := db.Query(`SELECT ` + specReviewCols + ` FROM spec_reviews WHERE status = 'running' ORDER BY ask_id`)
	if err != nil {
		return nil, nil, fmt.Errorf("listing running spec reviews: %w", err)
	}
	defer rrows.Close()
	for rrows.Next() {
		r, err := scanSpecReview(rrows)
		if err != nil {
			return nil, nil, fmt.Errorf("listing running spec reviews: %w", err)
		}
		running = append(running, *r)
	}
	if err := rrows.Err(); err != nil {
		return nil, nil, fmt.Errorf("listing running spec reviews: %w", err)
	}
	return queued, running, nil
}

// ListSpecReviewMarks returns the owner's marks of the ask by item key.
func (db *DB) ListSpecReviewMarks(askID int64) (map[string]SpecReviewMark, error) {
	rows, err := db.Query(`SELECT item_key, state, body, about, updated_at FROM spec_review_marks WHERE ask_id = ?`, askID)
	if err != nil {
		return nil, fmt.Errorf("listing spec review marks: %w", err)
	}
	defer rows.Close()
	marks := map[string]SpecReviewMark{}
	for rows.Next() {
		var key string
		var m SpecReviewMark
		if err := rows.Scan(&key, &m.State, &m.Body, &m.About, &m.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning spec review mark: %w", err)
		}
		marks[key] = m
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing spec review marks: %w", err)
	}
	return marks, nil
}

// RevealSpecLoop ends the author loop for the owner: loop='owner' with the end
// reason and the settled ledger, open_items cleared. False when the row was not
// in the 'author' loop (nothing changed).
func (db *DB) RevealSpecLoop(askID int64, end, ledger string, now time.Time) (bool, error) {
	res, err := db.Exec(`UPDATE spec_reviews SET loop = 'owner', loop_end = ?, ledger = ?, open_items = ''
		WHERE ask_id = ? AND loop = 'author'`, end, ledger, askID)
	if err != nil {
		return false, fmt.Errorf("revealing spec loop: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("revealing spec loop: %w", err)
	}
	return n == 1, nil
}

// SpecLoopsToSweep lists the author-loop reviews whose ask is still open.
func (db *DB) SpecLoopsToSweep() ([]SpecLoopRow, error) {
	rows, err := db.Query(`SELECT r.ask_id, r.status, r.finished_at, a.session_id IS NOT NULL
		FROM spec_reviews r JOIN owner_asks a ON a.id = r.ask_id
		WHERE r.loop = 'author' AND a.status = 'open' ORDER BY r.ask_id`)
	if err != nil {
		return nil, fmt.Errorf("listing spec loops: %w", err)
	}
	defer rows.Close()
	var out []SpecLoopRow
	for rows.Next() {
		var r SpecLoopRow
		if err := rows.Scan(&r.AskID, &r.Status, &r.FinishedAt, &r.SessionBound); err != nil {
			return nil, fmt.Errorf("scanning spec loop: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing spec loops: %w", err)
	}
	return out, nil
}
