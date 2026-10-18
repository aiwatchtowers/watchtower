package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// Diff reviewer rounds (migration 00121, spec
// 2026-10-16-workbench-diff-reviewer-design.md §5, §10). Go writes rounds and
// the send transition; drafts and Viewed marks are the Desktop's.

var ErrReviewRoundNotOpen = errors.New("review round is not open")

type ReviewRound struct {
	ID, ProjectID int64
	SessionID     sql.NullInt64
	Source        string
	FolderRoot    string
	BaseSHA       string
	BaseLabel     string
	TreeSHA       string
	PrevRoundID   sql.NullInt64
	Status        string
	Mode          string
	Phase         string
	ChapterKey    string
	ActiveSeconds int
	CreatedAt     string
	SentAt        sql.NullString
	DeliveredAt   sql.NullString
}

type ReviewComment struct {
	ID, RoundID        int64
	Path               sql.NullString
	Side               string
	StartLine, EndLine int
	Quote, TreeSHA     string
	Lens, Body, Status string
	CarriedFrom        sql.NullInt64
	AgentReply         string
}

const reviewRoundCols = `id, project_id, session_id, source, folder_root, base_sha, base_label, tree_sha,
	prev_round_id, status, mode, phase, chapter_key, active_seconds, created_at, sent_at, delivered_at`

func scanReviewRound(s interface{ Scan(...any) error }) (*ReviewRound, error) {
	var r ReviewRound
	err := s.Scan(&r.ID, &r.ProjectID, &r.SessionID, &r.Source, &r.FolderRoot, &r.BaseSHA, &r.BaseLabel,
		&r.TreeSHA, &r.PrevRoundID, &r.Status, &r.Mode, &r.Phase, &r.ChapterKey, &r.ActiveSeconds, &r.CreatedAt, &r.SentAt, &r.DeliveredAt)
	if err != nil {
		return nil, err
	}
	return &r, nil
}

func (db *DB) oneReviewRound(query string, args ...any) (*ReviewRound, error) {
	r, err := scanReviewRound(db.QueryRow(query, args...))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return r, err
}

// OpenReviewRound is session sessionID's open round, nil when none.
func (db *DB) OpenReviewRound(projectID, sessionID int64) (*ReviewRound, error) {
	return db.oneReviewRound(`SELECT `+reviewRoundCols+` FROM review_rounds
		WHERE project_id = ? AND session_id = ? AND status = 'open'`, projectID, sessionID)
}

// LastSentReviewRound is the session's newest sent or delivered round.
func (db *DB) LastSentReviewRound(projectID, sessionID int64) (*ReviewRound, error) {
	return db.oneReviewRound(`SELECT `+reviewRoundCols+` FROM review_rounds
		WHERE project_id = ? AND session_id = ? AND status IN ('sent','delivered')
		ORDER BY id DESC LIMIT 1`, projectID, sessionID)
}

// GetReviewRound reads round id of workbench projectID.
func (db *DB) GetReviewRound(projectID, id int64) (*ReviewRound, error) {
	r, err := scanReviewRound(db.QueryRow(`SELECT `+reviewRoundCols+` FROM review_rounds
		WHERE id = ? AND project_id = ?`, id, projectID))
	if err != nil {
		return nil, fmt.Errorf("review round %d: %w", id, err)
	}
	return r, nil
}

// CreateReviewRound inserts an open round; a second open round of the same
// session fails on review_rounds_one_open.
func (db *DB) CreateReviewRound(r ReviewRound) (int64, error) {
	if r.Source == "" {
		r.Source = "session"
	}
	if r.Mode == "" {
		r.Mode = "quick"
	}
	res, err := db.Exec(`INSERT INTO review_rounds (project_id, session_id, source, folder_root, base_sha,
		base_label, tree_sha, prev_round_id, mode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ProjectID, r.SessionID, r.Source, r.FolderRoot, r.BaseSHA, r.BaseLabel, r.TreeSHA, r.PrevRoundID, r.Mode)
	if err != nil {
		return 0, fmt.Errorf("creating review round: %w", err)
	}
	return res.LastInsertId()
}

// UpdateReviewRoundTree moves an open round to a fresh snapshot (Refresh).
func (db *DB) UpdateReviewRoundTree(id int64, tree string) error {
	res, err := db.Exec(`UPDATE review_rounds SET tree_sha = ? WHERE id = ? AND status = 'open'`, tree, id)
	if err != nil {
		return fmt.Errorf("refreshing review round %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("review round %d: %w", id, ErrReviewRoundNotOpen)
	}
	return nil
}

// SendReviewRound moves an open round to sent and its draft and carried
// comments to sent in one transaction; outdated rows are never sent. ok false
// (nothing written) when the round is not open or not this workbench's. sent
// counts the round's comments now sent.
func (db *DB) SendReviewRound(projectID, id int64) (sent int, ok bool, err error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, false, err
	}
	defer tx.Rollback() // a committed tx makes this a no-op
	res, err := tx.Exec(`UPDATE review_rounds SET status = 'sent', sent_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND project_id = ? AND status = 'open'`, id, projectID)
	if err != nil {
		return 0, false, fmt.Errorf("sending review round %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return 0, false, nil
	}
	if _, err := tx.Exec(`UPDATE review_comments SET status = 'sent', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE round_id = ? AND status IN ('draft','carried')`, id); err != nil {
		return 0, false, err
	}
	if err := tx.QueryRow(`SELECT COUNT(*) FROM review_comments WHERE round_id = ? AND status = 'sent'`, id).Scan(&sent); err != nil {
		return 0, false, err
	}
	return sent, true, tx.Commit()
}

// ReviewRoundComments lists a round's comments in id order.
func (db *DB) ReviewRoundComments(roundID int64) ([]ReviewComment, error) {
	rows, err := db.Query(`SELECT id, round_id, path, side, start_line, end_line, quote, tree_sha, lens, body,
		status, carried_from, agent_reply FROM review_comments WHERE round_id = ? ORDER BY id`, roundID)
	if err != nil {
		return nil, fmt.Errorf("reading review round %d comments: %w", roundID, err)
	}
	defer rows.Close()
	var out []ReviewComment
	for rows.Next() {
		var c ReviewComment
		if err := rows.Scan(&c.ID, &c.RoundID, &c.Path, &c.Side, &c.StartLine, &c.EndLine, &c.Quote, &c.TreeSHA,
			&c.Lens, &c.Body, &c.Status, &c.CarriedFrom, &c.AgentReply); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// MarkReviewRoundDelivered marks a sent round delivered once get_review read it (false otherwise).
func (db *DB) MarkReviewRoundDelivered(projectID, id int64) (bool, error) {
	res, err := db.Exec(`UPDATE review_rounds SET status = 'delivered',
		delivered_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND project_id = ? AND status = 'sent'`, id, projectID)
	if err != nil {
		return false, fmt.Errorf("delivering review round %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

// ReviewRoundsWaiting lists the session's sent, unread rounds, oldest first (the brief).
func (db *DB) ReviewRoundsWaiting(projectID, sessionID int64) ([]ReviewRound, error) {
	rows, err := db.Query(`SELECT `+reviewRoundCols+` FROM review_rounds
		WHERE project_id = ? AND session_id = ? AND status = 'sent' ORDER BY id`, projectID, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ReviewRound
	for rows.Next() {
		r, err := scanReviewRound(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}

// ReplyReviewComment stores the agent's reply on a sent comment of the
// workbench's sent or delivered round (status sent or resolved), and with
// resolved marks it resolved; the same reply goes to its copies in the
// session's open round (carried or outdated), which an owner-resolved copy
// never receives. resolved false never reopens. ok false (nothing written)
// when the comment is not such a comment of this workbench.
func (db *DB) ReplyReviewComment(projectID, commentID int64, reply string, resolved bool) (bool, error) {
	tx, err := db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback() // a committed tx makes this a no-op
	const now = `strftime('%Y-%m-%dT%H:%M:%SZ','now')`
	set := `agent_reply = ?, agent_reply_at = ` + now + `, updated_at = ` + now
	if resolved {
		set += `, status = 'resolved'`
	}
	res, err := tx.Exec(`UPDATE review_comments SET `+set+` WHERE id = ? AND status IN ('sent','resolved')
		AND round_id IN (SELECT id FROM review_rounds WHERE project_id = ? AND status IN ('sent','delivered'))`,
		reply, commentID, projectID)
	if err != nil {
		return false, fmt.Errorf("replying to review comment %d: %w", commentID, err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return false, nil
	}
	if _, err := tx.Exec(`UPDATE review_comments SET `+set+` WHERE carried_from = ? AND status IN ('carried','outdated')
		AND round_id IN (SELECT o.id FROM review_rounds o, review_comments c JOIN review_rounds r ON r.id = c.round_id
			WHERE c.id = ? AND o.project_id = r.project_id AND o.session_id IS r.session_id AND o.status = 'open')`,
		reply, commentID, commentID); err != nil {
		return false, fmt.Errorf("replying to the open copies of review comment %d: %w", commentID, err)
	}
	return true, tx.Commit()
}

// ReviewCommentRepliable reports whether commentID is a sent or resolved
// comment of a sent or delivered round of workbench projectID: what
// ReplyReviewComment accepts, without writing.
func (db *DB) ReviewCommentRepliable(projectID, commentID int64) (bool, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM review_comments WHERE id = ? AND status IN ('sent','resolved')
		AND round_id IN (SELECT id FROM review_rounds WHERE project_id = ? AND status IN ('sent','delivered'))`,
		commentID, projectID).Scan(&n); err != nil {
		return false, fmt.Errorf("reading review comment %d: %w", commentID, err)
	}
	return n == 1, nil
}
