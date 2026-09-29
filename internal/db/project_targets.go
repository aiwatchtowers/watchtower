package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ProjectTargetInput is one item of a CreateProjectTargetsTx batch. Its parent
// is an existing target of the same project (ParentID) or an earlier item of
// the same batch (BatchParent, 1-based; 0 = none) — never both — so a whole
// plan (feature → tasks → steps) lands in one call.
type ProjectTargetInput struct {
	Title       string
	Intent      string
	ParentID    sql.NullInt64
	BatchParent int
}

// CreateProjectTarget creates one target on project projectID's board.
func (db *DB) CreateProjectTarget(projectID int64, parentID sql.NullInt64, title, intent string) (int64, error) {
	var ids []int64
	err := db.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = db.CreateProjectTargetsTx(tx, projectID,
			[]ProjectTargetInput{{Title: title, Intent: intent, ParentID: parentID}})
		return err
	})
	if err != nil {
		return 0, err
	}
	return ids[0], nil
}

// CreateProjectTargetsTx inserts items, in order, as targets of project
// projectID inside tx and returns their ids. Every item gets the board
// defaults: level custom, custom_label project, period = the UTC day of
// creation, source chat, ownership mine, status todo. The first invalid item
// fails the call; the caller's transaction then rolls the whole batch back.
func (db *DB) CreateProjectTargetsTx(tx *sql.Tx, projectID int64, items []ProjectTargetInput) ([]int64, error) {
	if err := requireProject(tx, projectID); err != nil {
		return nil, err
	}
	day := time.Now().UTC().Format("2006-01-02")
	ids := make([]int64, 0, len(items))
	for i, it := range items {
		id, err := insertProjectTarget(tx, projectID, day, it, ids)
		if err != nil {
			return nil, fmt.Errorf("target %d of %d: %w", i+1, len(items), err)
		}
		ids = append(ids, id)
	}
	return ids, nil
}

func insertProjectTarget(tx *sql.Tx, projectID int64, day string, it ProjectTargetInput, created []int64) (int64, error) {
	title := strings.TrimSpace(it.Title)
	if title == "" {
		return 0, errors.New("empty title")
	}
	parent, err := resolveProjectParent(tx, projectID, it, created)
	if err != nil {
		return 0, err
	}
	res, err := tx.Exec(`INSERT INTO targets
		(text, intent, level, custom_label, period_start, period_end, parent_id,
		 status, ownership, source_type, project_id)
		VALUES (?, ?, 'custom', 'project', ?, ?, ?, 'todo', 'mine', 'chat', ?)`,
		title, strings.TrimSpace(it.Intent), day, day, parent, projectID)
	if err != nil {
		return 0, fmt.Errorf("inserting project target: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	if parent.Valid {
		if err := recomputeParentProgressOn(tx, parent.Int64); err != nil {
			return 0, err
		}
	}
	return id, nil
}

func resolveProjectParent(q targetsQuerier, projectID int64, it ProjectTargetInput, created []int64) (sql.NullInt64, error) {
	switch {
	case it.ParentID.Valid && it.BatchParent != 0:
		return sql.NullInt64{}, errors.New("parent_id and a batch parent are mutually exclusive")
	case it.BatchParent < 0 || it.BatchParent > len(created):
		return sql.NullInt64{}, fmt.Errorf("batch parent %d is not an earlier item of this batch", it.BatchParent)
	case it.BatchParent > 0:
		return sql.NullInt64{Int64: created[it.BatchParent-1], Valid: true}, nil
	case it.ParentID.Valid:
		return it.ParentID, checkTargetInProject(q, projectID, it.ParentID.Int64)
	}
	return sql.NullInt64{}, nil
}
