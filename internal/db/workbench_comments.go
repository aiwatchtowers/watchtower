package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// WorkbenchComment is a comment on a project target or document, or a reply in
// a thread (ParentID = the thread root; threads are flat). Status is
// meaningful on roots only; an agent comment is unread for the owner while
// ReadAt is empty.
type WorkbenchComment struct {
	ID            int64
	WorkbenchID   int64
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

// WorkbenchCommentFilter selects comments; a zero id matches any.
type WorkbenchCommentFilter struct {
	WorkbenchID int64
	TargetID    int64
	DocumentID  int64
	// NewForAgent keeps only what the agent has not answered yet (spec §3).
	NewForAgent bool
}

const workbenchCommentCols = `c.id, c.project_id, c.target_id, c.document_id, c.parent_id, c.author, c.agent_label,
	c.body, c.anchor_quote, c.anchor_prefix, c.anchor_suffix, c.anchor_heading, c.status, c.created_at, c.read_at`

// newForAgentPredicate (over alias c): open owner roots, plus owner replies
// in a still-open thread newer than its latest agent comment (the agent root
// counts) — resolving a thread retires its unanswered replies too.
// "Newer" compares ids — rowids grow monotonically, created_at ties within a
// second. Replies always point at their root (AddWorkbenchComment flattens).
const newForAgentPredicate = `(c.author = 'owner' AND (
	(c.parent_id IS NULL AND c.status = 'open')
	OR (c.parent_id IS NOT NULL
		AND EXISTS (SELECT 1 FROM project_comments r WHERE r.id = c.parent_id AND r.status = 'open')
		AND c.id > COALESCE((
		SELECT MAX(a.id) FROM project_comments a
		WHERE a.author = 'agent' AND (a.id = c.parent_id OR a.parent_id = c.parent_id)), 0))))`

var workbenchCommentStatuses = map[string]bool{"open": true, "resolved": true, "outdated": true}

func scanWorkbenchComment(row interface{ Scan(...any) error }) (*WorkbenchComment, error) {
	var c WorkbenchComment
	if err := row.Scan(&c.ID, &c.WorkbenchID, &c.TargetID, &c.DocumentID, &c.ParentID, &c.Author, &c.AgentLabel,
		&c.Body, &c.AnchorQuote, &c.AnchorPrefix, &c.AnchorSuffix, &c.AnchorHeading, &c.Status, &c.CreatedAt, &c.ReadAt); err != nil {
		return nil, err
	}
	return &c, nil
}

// AddWorkbenchComment stores c. A reply (ParentID set) is re-pointed at its
// thread root and inherits the root's target/document; a root must name a
// target or a document of the same project. Every reference is checked
// against c.ProjectID (ErrNotInWorkbench).
func (db *DB) AddWorkbenchComment(c WorkbenchComment) (int64, error) {
	var id int64
	err := db.WithTx(func(tx *sql.Tx) error {
		var err error
		id, err = db.AddWorkbenchCommentTx(tx, c)
		return err
	})
	if err != nil {
		return 0, err
	}
	return id, nil
}

// AddWorkbenchCommentTx is AddWorkbenchComment inside the caller's transaction.
// An owner reply to a resolved or outdated thread reopens its root in the
// same transaction — newForAgentPredicate reads only open threads, so the
// reply would otherwise never reach the agent. An agent reply never reopens.
// Swift twin: ProjectQueries.reply.
func (db *DB) AddWorkbenchCommentTx(tx *sql.Tx, c WorkbenchComment) (int64, error) {
	if c.Author != "owner" && c.Author != "agent" {
		return 0, fmt.Errorf("invalid comment author %q", c.Author)
	}
	if strings.TrimSpace(c.Body) == "" {
		return 0, errors.New("comment body is required")
	}
	placed, err := placeWorkbenchComment(tx, c)
	if err != nil {
		return 0, err
	}
	id, err := insertWorkbenchComment(tx, placed)
	if err != nil {
		return 0, err
	}
	if placed.Author == "owner" && placed.ParentID.Valid {
		if _, err := tx.Exec(`UPDATE project_comments SET status = 'open' WHERE id = ? AND status != 'open'`,
			placed.ParentID.Int64); err != nil {
			return 0, fmt.Errorf("reopening thread %d: %w", placed.ParentID.Int64, err)
		}
	}
	return id, nil
}

func placeWorkbenchComment(q targetsQuerier, c WorkbenchComment) (WorkbenchComment, error) {
	if c.ParentID.Valid {
		return placeReply(q, c)
	}
	if !c.TargetID.Valid && !c.DocumentID.Valid {
		return c, errors.New("a comment needs a target, a document or a parent")
	}
	if c.TargetID.Valid {
		if err := checkTargetInWorkbench(q, c.WorkbenchID, c.TargetID.Int64); err != nil {
			return c, err
		}
	}
	if c.DocumentID.Valid {
		if err := checkDocumentInWorkbench(q, c.WorkbenchID, c.DocumentID.Int64); err != nil {
			return c, err
		}
	}
	return c, nil
}

func placeReply(q targetsQuerier, c WorkbenchComment) (WorkbenchComment, error) {
	parent, err := scanWorkbenchComment(q.QueryRow(`SELECT `+workbenchCommentCols+` FROM project_comments c WHERE c.id = ?`, c.ParentID.Int64))
	if errors.Is(err, sql.ErrNoRows) {
		return c, fmt.Errorf("comment %d does not exist: %w", c.ParentID.Int64, ErrNotInWorkbench)
	}
	if err != nil {
		return c, fmt.Errorf("loading comment %d: %w", c.ParentID.Int64, err)
	}
	if parent.WorkbenchID != c.WorkbenchID {
		return c, fmt.Errorf("comment %d: %w", parent.ID, ErrNotInWorkbench)
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

func insertWorkbenchComment(tx *sql.Tx, c WorkbenchComment) (int64, error) {
	res, err := tx.Exec(`INSERT INTO project_comments
		(project_id, target_id, document_id, parent_id, author, agent_label, body,
		 anchor_quote, anchor_prefix, anchor_suffix, anchor_heading)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.WorkbenchID, c.TargetID, c.DocumentID, c.ParentID, c.Author, c.AgentLabel, c.Body,
		c.AnchorQuote, c.AnchorPrefix, c.AnchorSuffix, c.AnchorHeading)
	if err != nil {
		return 0, fmt.Errorf("inserting comment: %w", err)
	}
	return res.LastInsertId()
}

// GetWorkbenchComment returns comment id, or (nil, nil) when absent.
func (db *DB) GetWorkbenchComment(id int64) (*WorkbenchComment, error) {
	c, err := scanWorkbenchComment(db.QueryRow(`SELECT `+workbenchCommentCols+` FROM project_comments c WHERE c.id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting comment %d: %w", id, err)
	}
	return c, nil
}

// ListWorkbenchComments returns the comments f selects, oldest first.
func (db *DB) ListWorkbenchComments(f WorkbenchCommentFilter) ([]WorkbenchComment, error) {
	where, args := workbenchCommentWhere(f)
	query := `SELECT ` + workbenchCommentCols + ` FROM project_comments c` + where + ` ORDER BY c.created_at, c.id`
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing comments: %w", err)
	}
	defer rows.Close()
	var out []WorkbenchComment
	for rows.Next() {
		c, err := scanWorkbenchComment(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning comment: %w", err)
		}
		out = append(out, *c)
	}
	return out, rows.Err()
}

func workbenchCommentWhere(f WorkbenchCommentFilter) (string, []any) {
	var conds []string
	var args []any
	for _, scope := range []struct {
		col string
		id  int64
	}{{"c.project_id", f.WorkbenchID}, {"c.target_id", f.TargetID}, {"c.document_id", f.DocumentID}} {
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

// SetWorkbenchCommentStatus sets a thread root's status (open to reopen).
func (db *DB) SetWorkbenchCommentStatus(id int64, status string) error {
	return setWorkbenchCommentStatusOn(db, id, status)
}

// SetWorkbenchCommentStatusTx is SetWorkbenchCommentStatus inside the caller's
// transaction.
func (db *DB) SetWorkbenchCommentStatusTx(tx *sql.Tx, id int64, status string) error {
	return setWorkbenchCommentStatusOn(tx, id, status)
}

func setWorkbenchCommentStatusOn(q targetsQuerier, id int64, status string) error {
	if !workbenchCommentStatuses[status] {
		return fmt.Errorf("invalid comment status %q", status)
	}
	res, err := q.Exec(`UPDATE project_comments SET status = ? WHERE id = ? AND parent_id IS NULL`, status, id)
	if err != nil {
		return fmt.Errorf("setting comment %d status: %w", id, err)
	}
	return requireAffected(res, fmt.Errorf("comment %d is not a thread root or does not exist", id))
}
