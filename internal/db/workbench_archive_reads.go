package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// IsWorkbenchTargetArchived reports whether target id is archived
// (workbench_target_archive, PROJ-15). A target of no workbench, or a
// missing one, is not.
func (db *DB) IsWorkbenchTargetArchived(id int64) (bool, error) {
	var archived bool
	err := db.QueryRow(`SELECT archived FROM workbench_target_archive WHERE target_id = ?`, id).Scan(&archived)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading target %d's archive state: %w", id, err)
	}
	return archived, nil
}

// CountArchived counts the archived nodes of board (BoardNode.Archived) at
// every depth.
func CountArchived(board []BoardNode) int {
	n := 0
	for _, node := range board {
		if node.Archived {
			n++
		}
		n += CountArchived(node.Children)
	}
	return n
}
