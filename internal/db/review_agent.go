package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Diff reviewer, agent and AI layer (migration 00125, plan 3): the agent's
// notes and chapters, cached AI overviews, undone hunks and house-rule lessons.

// ReviewNote is one annotate_changes row: a line note (Kind "note") or a
// chapter (Kind "chapter", Text = title, Paths = its files).
type ReviewNote struct {
	ID                 int64
	Kind               string
	Ord                int
	Path               string
	StartLine, EndLine int
	Quote, Text        string
	Paths              []string
	Core               bool
	Why, TreeSHA       string
}

// ReplaceReviewNotes swaps the session's notes for notes in one transaction;
// ord is the slice order per kind. Other sessions' rows stay.
func (db *DB) ReplaceReviewNotes(projectID, sessionID int64, treeSHA string, notes []ReviewNote) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // a committed tx makes this a no-op
	if _, err := tx.Exec(`DELETE FROM review_notes WHERE project_id = ? AND session_id = ?`, projectID, sessionID); err != nil {
		return fmt.Errorf("clearing review notes: %w", err)
	}
	ord := map[string]int{}
	for _, n := range notes {
		paths := n.Paths
		if paths == nil {
			paths = []string{}
		}
		pj, err := json.Marshal(paths)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(`INSERT INTO review_notes (project_id, session_id, tree_sha, kind, ord, path, start_line,
			end_line, quote, text, paths_json, core, why) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			projectID, sessionID, treeSHA, n.Kind, ord[n.Kind], n.Path, n.StartLine, n.EndLine, n.Quote, n.Text,
			string(pj), n.Core, n.Why); err != nil {
			return fmt.Errorf("inserting review note: %w", err)
		}
		ord[n.Kind]++
	}
	return tx.Commit()
}

// ReviewNotes reads the session's notes, kind then ord order.
func (db *DB) ReviewNotes(projectID, sessionID int64) ([]ReviewNote, error) {
	rows, err := db.Query(`SELECT id, kind, ord, path, start_line, end_line, quote, text, paths_json, core, why, tree_sha
		FROM review_notes WHERE project_id = ? AND session_id = ? ORDER BY kind, ord`, projectID, sessionID)
	if err != nil {
		return nil, fmt.Errorf("reading review notes: %w", err)
	}
	defer rows.Close()
	var out []ReviewNote
	for rows.Next() {
		var n ReviewNote
		var pj string
		if err := rows.Scan(&n.ID, &n.Kind, &n.Ord, &n.Path, &n.StartLine, &n.EndLine, &n.Quote, &n.Text, &pj, &n.Core, &n.Why, &n.TreeSHA); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(pj), &n.Paths); err != nil {
			return nil, fmt.Errorf("review note %d paths: %w", n.ID, err)
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// ReviewOverviewJSON is the cached overview for the key; ok false on a miss.
func (db *DB) ReviewOverviewJSON(projectID int64, tree, base, intentHash string) (string, bool, error) {
	var js string
	err := db.QueryRow(`SELECT json FROM review_overviews
		WHERE project_id = ? AND tree_sha = ? AND base_sha = ? AND intent_hash = ?`, projectID, tree, base, intentHash).Scan(&js)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("reading review overview: %w", err)
	}
	return js, true, nil
}

// PutReviewOverview caches an overview, replacing one under the same key.
func (db *DB) PutReviewOverview(projectID int64, tree, base, intentHash, js, model string) error {
	if _, err := db.Exec(`INSERT OR REPLACE INTO review_overviews (project_id, tree_sha, base_sha, intent_hash, json, model)
		VALUES (?, ?, ?, ?, ?, ?)`, projectID, tree, base, intentHash, js, model); err != nil {
		return fmt.Errorf("caching review overview: %w", err)
	}
	return nil
}

// ReviewRevert is one undone hunk; Patch holds its lines so the agent sees what went.
type ReviewRevert struct {
	ID, RoundID                     int64
	HunkID, Path, Header, Patch, At string
}

var ErrHunkAlreadyReverted = errors.New("hunk already reverted in this round")

// AddReviewRevert records an undone hunk; a second one for the same round and hunk is ErrHunkAlreadyReverted.
func (db *DB) AddReviewRevert(r ReviewRevert) error {
	_, err := db.Exec(`INSERT INTO review_reverts (round_id, hunk_id, path, header, patch) VALUES (?, ?, ?, ?, ?)`,
		r.RoundID, r.HunkID, r.Path, r.Header, r.Patch)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed") {
			return ErrHunkAlreadyReverted
		}
		return fmt.Errorf("recording review revert: %w", err)
	}
	return nil
}

// ReviewReverts lists a round's undone hunks, oldest first.
func (db *DB) ReviewReverts(roundID int64) ([]ReviewRevert, error) {
	rows, err := db.Query(`SELECT id, round_id, hunk_id, path, header, patch, at FROM review_reverts
		WHERE round_id = ? ORDER BY id`, roundID)
	if err != nil {
		return nil, fmt.Errorf("reading review reverts: %w", err)
	}
	defer rows.Close()
	var out []ReviewRevert
	for rows.Next() {
		var r ReviewRevert
		if err := rows.Scan(&r.ID, &r.RoundID, &r.HunkID, &r.Path, &r.Header, &r.Patch, &r.At); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ReviewLesson is a proposed house rule distilled from the owner's review comments.
type ReviewLesson struct {
	ID, ProjectID    int64
	Lens, Text       string
	SourceCommentIDs []int64
	Status           string
}

const reviewLessonCols = `id, project_id, lens, text, source_comment_ids, status`

func scanReviewLesson(s interface{ Scan(...any) error }) (*ReviewLesson, error) {
	var l ReviewLesson
	var src string
	if err := s.Scan(&l.ID, &l.ProjectID, &l.Lens, &l.Text, &src, &l.Status); err != nil {
		return nil, err
	}
	if err := json.Unmarshal([]byte(src), &l.SourceCommentIDs); err != nil {
		return nil, fmt.Errorf("review lesson %d sources: %w", l.ID, err)
	}
	return &l, nil
}

// ReplaceProposedReviewLessons swaps the workbench's proposed lessons for ls in
// one transaction (decided ones stay) and returns the inserted rows with ids.
func (db *DB) ReplaceProposedReviewLessons(projectID int64, ls []ReviewLesson) ([]ReviewLesson, error) {
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback() //nolint:errcheck // a committed tx makes this a no-op
	if _, err := tx.Exec(`DELETE FROM review_lessons WHERE project_id = ? AND status = 'proposed'`, projectID); err != nil {
		return nil, fmt.Errorf("clearing proposed lessons: %w", err)
	}
	out := make([]ReviewLesson, 0, len(ls))
	for _, l := range ls {
		src := l.SourceCommentIDs
		if src == nil {
			src = []int64{}
		}
		sj, err := json.Marshal(src)
		if err != nil {
			return nil, err
		}
		res, err := tx.Exec(`INSERT INTO review_lessons (project_id, lens, text, source_comment_ids) VALUES (?, ?, ?, ?)`,
			projectID, l.Lens, l.Text, string(sj))
		if err != nil {
			return nil, fmt.Errorf("inserting review lesson: %w", err)
		}
		id, err := res.LastInsertId()
		if err != nil {
			return nil, err
		}
		out = append(out, ReviewLesson{ID: id, ProjectID: projectID, Lens: l.Lens, Text: l.Text, SourceCommentIDs: src, Status: "proposed"})
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return out, nil
}

// ReviewLessons lists the workbench's lessons, newest last; status "" = all.
func (db *DB) ReviewLessons(projectID int64, status string) ([]ReviewLesson, error) {
	q := `SELECT ` + reviewLessonCols + ` FROM review_lessons WHERE project_id = ?`
	args := []any{projectID}
	if status != "" {
		q += ` AND status = ?`
		args = append(args, status)
	}
	rows, err := db.Query(q+` ORDER BY id`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading review lessons: %w", err)
	}
	defer rows.Close()
	var out []ReviewLesson
	for rows.Next() {
		l, err := scanReviewLesson(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *l)
	}
	return out, rows.Err()
}

// GetReviewLesson reads lesson id of workbench projectID, nil when absent.
func (db *DB) GetReviewLesson(projectID, id int64) (*ReviewLesson, error) {
	l, err := scanReviewLesson(db.QueryRow(`SELECT `+reviewLessonCols+` FROM review_lessons WHERE project_id = ? AND id = ?`, projectID, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return l, err
}

// DecideReviewLesson moves a proposed lesson to accepted or dismissed; false
// when it is not proposed (or not this workbench's).
func (db *DB) DecideReviewLesson(projectID, id int64, status string) (bool, error) {
	res, err := db.Exec(`UPDATE review_lessons SET status = ?, decided_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE project_id = ? AND id = ? AND status = 'proposed'`, status, projectID, id)
	if err != nil {
		return false, fmt.Errorf("deciding review lesson %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("deciding review lesson %d: %w", id, err)
	}
	return n == 1, nil
}

// ReopenReviewLesson moves an accepted lesson back to proposed: Accept's
// undo when the rule could not be written after the decision was taken.
func (db *DB) ReopenReviewLesson(projectID, id int64) error {
	if _, err := db.Exec(`UPDATE review_lessons SET status = 'proposed', decided_at = NULL
		WHERE project_id = ? AND id = ? AND status = 'accepted'`, projectID, id); err != nil {
		return fmt.Errorf("reopening review lesson %d: %w", id, err)
	}
	return nil
}

// ReviewLessonInputComments are the owner's comments the lessons call learns
// from: the workbench's newest lastRounds sent or delivered rounds, comments
// sent or resolved, never carried copies, minus those a decided lesson cites.
func (db *DB) ReviewLessonInputComments(projectID int64, lastRounds int) ([]ReviewComment, error) {
	rows, err := db.Query(`SELECT c.id, c.round_id, c.path, c.side, c.start_line, c.end_line, c.quote, c.tree_sha,
			c.lens, c.body, c.status, c.carried_from, c.agent_reply
		FROM review_comments c
		WHERE c.round_id IN (SELECT id FROM review_rounds WHERE project_id = ? AND status IN ('sent','delivered')
				ORDER BY id DESC LIMIT ?)
			AND c.status IN ('sent','resolved') AND c.carried_from IS NULL
			AND c.id NOT IN (SELECT j.value FROM review_lessons l, json_each(l.source_comment_ids) j
				WHERE l.project_id = ? AND l.status IN ('accepted','dismissed'))
		ORDER BY c.id`, projectID, lastRounds, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading lesson input comments: %w", err)
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

// TerminalAgentWorking reports whether the session's agent last reported working.
func (db *DB) TerminalAgentWorking(sessionID int64) (bool, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM terminal_sessions WHERE id = ? AND agent_state = 'working'`, sessionID).Scan(&n); err != nil {
		return false, fmt.Errorf("reading agent state of session %d: %w", sessionID, err)
	}
	return n == 1, nil
}
