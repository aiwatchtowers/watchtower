package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ProjectComment is a comment on a project target or document, or a reply in
// a thread (ParentID = the thread root; threads are flat). Status is
// meaningful on roots only; an agent comment is unread for the owner while
// ReadAt is empty.
type ProjectComment struct {
	ID            int64
	ProjectID     int64
	TargetID      sql.NullInt64
	DocumentID    sql.NullInt64
	ParentID      sql.NullInt64
	Author        string // owner | agent
	AgentLabel    string
	Body          string
	AnchorQuote   string
	AnchorPrefix  string
	AnchorSuffix  string
	AnchorHeading string
	Status        string // open | resolved | outdated
	CreatedAt     string
	ReadAt        string
}

// ProjectCommentFilter selects comments; a zero id matches any.
type ProjectCommentFilter struct {
	ProjectID  int64
	TargetID   int64
	DocumentID int64
	// NewForAgent keeps only what the agent has not answered yet (spec §3).
	NewForAgent bool
}

const projectCommentCols = `c.id, c.project_id, c.target_id, c.document_id, c.parent_id, c.author, c.agent_label,
	c.body, c.anchor_quote, c.anchor_prefix, c.anchor_suffix, c.anchor_heading, c.status, c.created_at, c.read_at`

// newForAgentPredicate (over alias c): open owner roots, plus owner replies
// in a still-open thread newer than its latest agent comment (the agent root
// counts) — resolving a thread retires its unanswered replies too.
// "Newer" compares ids — rowids grow monotonically, created_at ties within a
// second. Replies always point at their root (AddProjectComment flattens).
const newForAgentPredicate = `(c.author = 'owner' AND (
	(c.parent_id IS NULL AND c.status = 'open')
	OR (c.parent_id IS NOT NULL
		AND EXISTS (SELECT 1 FROM project_comments r WHERE r.id = c.parent_id AND r.status = 'open')
		AND c.id > COALESCE((
		SELECT MAX(a.id) FROM project_comments a
		WHERE a.author = 'agent' AND (a.id = c.parent_id OR a.parent_id = c.parent_id)), 0))))`

var projectCommentStatuses = map[string]bool{"open": true, "resolved": true, "outdated": true}

func scanProjectComment(row interface{ Scan(...any) error }) (*ProjectComment, error) {
	var c ProjectComment
	if err := row.Scan(&c.ID, &c.ProjectID, &c.TargetID, &c.DocumentID, &c.ParentID, &c.Author, &c.AgentLabel,
		&c.Body, &c.AnchorQuote, &c.AnchorPrefix, &c.AnchorSuffix, &c.AnchorHeading, &c.Status, &c.CreatedAt, &c.ReadAt); err != nil {
		return nil, err
	}
	return &c, nil
}

// AddProjectComment stores c. A reply (ParentID set) is re-pointed at its
// thread root and inherits the root's target/document; a root must name a
// target or a document of the same project. Every reference is checked
// against c.ProjectID (ErrNotInProject).
func (db *DB) AddProjectComment(c ProjectComment) (int64, error) {
	var id int64
	err := db.WithTx(func(tx *sql.Tx) error {
		var err error
		id, err = db.AddProjectCommentTx(tx, c)
		return err
	})
	if err != nil {
		return 0, err
	}
	return id, nil
}

// AddProjectCommentTx is AddProjectComment inside the caller's transaction.
func (db *DB) AddProjectCommentTx(tx *sql.Tx, c ProjectComment) (int64, error) {
	if c.Author != "owner" && c.Author != "agent" {
		return 0, fmt.Errorf("invalid comment author %q", c.Author)
	}
	if strings.TrimSpace(c.Body) == "" {
		return 0, errors.New("comment body is required")
	}
	placed, err := placeProjectComment(tx, c)
	if err != nil {
		return 0, err
	}
	return insertProjectComment(tx, placed)
}

func placeProjectComment(q targetsQuerier, c ProjectComment) (ProjectComment, error) {
	if c.ParentID.Valid {
		return placeReply(q, c)
	}
	if !c.TargetID.Valid && !c.DocumentID.Valid {
		return c, errors.New("a comment needs a target, a document or a parent")
	}
	if c.TargetID.Valid {
		if err := checkTargetInProject(q, c.ProjectID, c.TargetID.Int64); err != nil {
			return c, err
		}
	}
	if c.DocumentID.Valid {
		if err := checkDocumentInProject(q, c.ProjectID, c.DocumentID.Int64); err != nil {
			return c, err
		}
	}
	return c, nil
}

func placeReply(q targetsQuerier, c ProjectComment) (ProjectComment, error) {
	parent, err := scanProjectComment(q.QueryRow(`SELECT `+projectCommentCols+` FROM project_comments c WHERE c.id = ?`, c.ParentID.Int64))
	if errors.Is(err, sql.ErrNoRows) {
		return c, fmt.Errorf("comment %d does not exist: %w", c.ParentID.Int64, ErrNotInProject)
	}
	if err != nil {
		return c, fmt.Errorf("loading comment %d: %w", c.ParentID.Int64, err)
	}
	if parent.ProjectID != c.ProjectID {
		return c, fmt.Errorf("comment %d: %w", parent.ID, ErrNotInProject)
	}
	root := parent.ID
	if parent.ParentID.Valid {
		root = parent.ParentID.Int64
	}
	c.ParentID = sql.NullInt64{Int64: root, Valid: true}
	c.TargetID, c.DocumentID = parent.TargetID, parent.DocumentID
	c.AnchorQuote, c.AnchorPrefix, c.AnchorSuffix, c.AnchorHeading = "", "", "", ""
	return c, nil
}

func insertProjectComment(tx *sql.Tx, c ProjectComment) (int64, error) {
	res, err := tx.Exec(`INSERT INTO project_comments
		(project_id, target_id, document_id, parent_id, author, agent_label, body,
		 anchor_quote, anchor_prefix, anchor_suffix, anchor_heading)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.ProjectID, c.TargetID, c.DocumentID, c.ParentID, c.Author, c.AgentLabel, c.Body,
		c.AnchorQuote, c.AnchorPrefix, c.AnchorSuffix, c.AnchorHeading)
	if err != nil {
		return 0, fmt.Errorf("inserting comment: %w", err)
	}
	return res.LastInsertId()
}

// GetProjectComment returns comment id, or (nil, nil) when absent.
func (db *DB) GetProjectComment(id int64) (*ProjectComment, error) {
	c, err := scanProjectComment(db.QueryRow(`SELECT `+projectCommentCols+` FROM project_comments c WHERE c.id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting comment %d: %w", id, err)
	}
	return c, nil
}

// ListProjectComments returns the comments f selects, oldest first.
func (db *DB) ListProjectComments(f ProjectCommentFilter) ([]ProjectComment, error) {
	where, args := projectCommentWhere(f)
	query := `SELECT ` + projectCommentCols + ` FROM project_comments c` + where + ` ORDER BY c.created_at, c.id`
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing comments: %w", err)
	}
	defer rows.Close()
	var out []ProjectComment
	for rows.Next() {
		c, err := scanProjectComment(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning comment: %w", err)
		}
		out = append(out, *c)
	}
	return out, rows.Err()
}

func projectCommentWhere(f ProjectCommentFilter) (string, []any) {
	var conds []string
	var args []any
	for _, scope := range []struct {
		col string
		id  int64
	}{{"c.project_id", f.ProjectID}, {"c.target_id", f.TargetID}, {"c.document_id", f.DocumentID}} {
		if scope.id > 0 {
			conds = append(conds, scope.col+" = ?")
			args = append(args, scope.id)
		}
	}
	if f.NewForAgent {
		conds = append(conds, newForAgentPredicate)
	}
	if len(conds) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(conds, " AND "), args
}

// SetProjectCommentStatus sets a thread root's status (open to reopen).
func (db *DB) SetProjectCommentStatus(id int64, status string) error {
	return setProjectCommentStatusOn(db, id, status)
}

// SetProjectCommentStatusTx is SetProjectCommentStatus inside the caller's
// transaction.
func (db *DB) SetProjectCommentStatusTx(tx *sql.Tx, id int64, status string) error {
	return setProjectCommentStatusOn(tx, id, status)
}

func setProjectCommentStatusOn(q targetsQuerier, id int64, status string) error {
	if !projectCommentStatuses[status] {
		return fmt.Errorf("invalid comment status %q", status)
	}
	res, err := q.Exec(`UPDATE project_comments SET status = ? WHERE id = ? AND parent_id IS NULL`, status, id)
	if err != nil {
		return fmt.Errorf("setting comment %d status: %w", id, err)
	}
	return requireAffected(res, fmt.Errorf("comment %d is not a thread root or does not exist", id))
}

// MarkProjectCommentsRead stamps read_at on the project's unread agent
// comments, narrowed to one target and/or document when those ids are set.
func (db *DB) MarkProjectCommentsRead(projectID, targetID, documentID int64) error {
	_, err := db.Exec(`UPDATE project_comments SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE project_id = ? AND author = 'agent' AND read_at = ''
		  AND (? = 0 OR target_id = ?) AND (? = 0 OR document_id = ?)`,
		projectID, targetID, targetID, documentID, documentID)
	if err != nil {
		return fmt.Errorf("marking comments read: %w", err)
	}
	return nil
}
