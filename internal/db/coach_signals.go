package db

import (
	"fmt"
	"time"
)

// CoachSpecReview is a finished spec review the coach reads its findings from.
type CoachSpecReview struct {
	AskID, WorkbenchID int64
	Result             string // the validated reviewer reply (JSON)
	FinishedAt         time.Time
}

// ListDoneSpecReviewsBetween returns the spec reviews finished in
// [since, until), newest first.
func (db *DB) ListDoneSpecReviewsBetween(since, until time.Time) ([]CoachSpecReview, error) {
	rows, err := db.Query(`SELECT r.ask_id, a.project_id, r.result, r.finished_at
		FROM spec_reviews r JOIN owner_asks a ON a.id = r.ask_id
		WHERE r.status = 'done' AND r.finished_at >= ? AND r.finished_at < ?
		ORDER BY r.finished_at DESC, r.ask_id DESC`, specReviewTime(since), specReviewTime(until))
	if err != nil {
		return nil, fmt.Errorf("listing done spec reviews: %w", err)
	}
	defer rows.Close()
	var out []CoachSpecReview
	for rows.Next() {
		var r CoachSpecReview
		var finished string
		if err := rows.Scan(&r.AskID, &r.WorkbenchID, &r.Result, &finished); err != nil {
			return nil, fmt.Errorf("scanning done spec review: %w", err)
		}
		if r.FinishedAt, err = ParseSpecReviewTime(finished); err != nil {
			return nil, fmt.Errorf("parsing spec review finished_at: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing done spec reviews: %w", err)
	}
	return out, nil
}

// CoachReviewComment is one owner comment of a first-round diff review.
type CoachReviewComment struct {
	RoundID, CommentID, WorkbenchID int64
	Body                            string
	CreatedAt                       time.Time
}

// ListFirstRoundReviewCommentsBetween returns the non-empty comments of
// first-round reviews (no previous round, not carried) that the owner sent
// to the agent (status sent, or resolved after it; never a draft or an
// outdated comment) created in
// [since, until), newest first. The table records no author: every comment is
// the owner's (the agent answers in agent_reply).
func (db *DB) ListFirstRoundReviewCommentsBetween(since, until time.Time) ([]CoachReviewComment, error) {
	rows, err := db.Query(`SELECT c.round_id, c.id, r.project_id, c.body, c.created_at
		FROM review_comments c JOIN review_rounds r ON r.id = c.round_id
		WHERE c.carried_from IS NULL AND r.prev_round_id IS NULL AND c.body != ''
		  AND c.status IN ('sent','resolved')
		  AND r.created_at >= ? AND r.created_at < ?
		ORDER BY c.created_at DESC, c.id DESC`, coachStamp(since), coachStamp(until))
	if err != nil {
		return nil, fmt.Errorf("listing first-round review comments: %w", err)
	}
	defer rows.Close()
	var out []CoachReviewComment
	for rows.Next() {
		var c CoachReviewComment
		var created string
		if err := rows.Scan(&c.RoundID, &c.CommentID, &c.WorkbenchID, &c.Body, &created); err != nil {
			return nil, fmt.Errorf("scanning review comment: %w", err)
		}
		if c.CreatedAt, err = parseCoachStamp(created); err != nil {
			return nil, fmt.Errorf("parsing review comment created_at: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing first-round review comments: %w", err)
	}
	return out, nil
}
