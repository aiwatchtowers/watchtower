package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// ErrParentOtherBoard is returned when a parent and its child would live on
// different boards — the personal board (project_id NULL) or a project's.
var ErrParentOtherBoard = errors.New("a parent and its child must be on the same board")

func boardName(projectID sql.NullInt64) string {
	if !projectID.Valid {
		return "the personal board"
	}
	return fmt.Sprintf("project %d's board", projectID.Int64)
}

func sameBoard(a, b sql.NullInt64) bool {
	return a.Valid == b.Valid && (!a.Valid || a.Int64 == b.Int64)
}

// checkParentBoard refuses parentID when it is on a different board than a
// child on projectID. A missing parent is left to the foreign key.
func checkParentBoard(q targetsQuerier, parentID, projectID sql.NullInt64) error {
	if !parentID.Valid {
		return nil
	}
	var parentProject sql.NullInt64
	err := q.QueryRow(`SELECT project_id FROM targets WHERE id = ?`, parentID.Int64).Scan(&parentProject)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("checking parent target #%d: %w", parentID.Int64, err)
	}
	if !sameBoard(parentProject, projectID) {
		return fmt.Errorf("parent target #%d is on %s, the child on %s: %w",
			parentID.Int64, boardName(parentProject), boardName(projectID), ErrParentOtherBoard)
	}
	return nil
}

// checkChildrenBoard refuses moving target id to projectID while any of its
// children stays on another board.
func checkChildrenBoard(q targetsQuerier, id int64, projectID sql.NullInt64) error {
	var child int64
	err := q.QueryRow(`SELECT id FROM targets WHERE parent_id = ? AND project_id IS NOT ? LIMIT 1`,
		id, projectID).Scan(&child)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("checking children of target #%d: %w", id, err)
	}
	return fmt.Errorf("target #%d would move to %s but its child #%d stays behind: %w",
		id, boardName(projectID), child, ErrParentOtherBoard)
}
