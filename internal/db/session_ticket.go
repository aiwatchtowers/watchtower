package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// The finish_session gates (spec 2026-10-24-finish-whole-ticket, PROJ-14):
// the session's ticket and the open leaves under it.

// OpenTicketLeaf is one open leaf of a ticket.
type OpenTicketLeaf struct {
	ID     int64
	Status string
	Text   string
}

// SessionTicket is the target terminal session sessionID was launched for
// (terminal_sessions.target_id); 0 when it has none or the row is gone.
func (db *DB) SessionTicket(sessionID int64) (int64, error) {
	var id sql.NullInt64
	err := db.QueryRow(`SELECT target_id FROM terminal_sessions WHERE id = ?`, sessionID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("reading session %d's ticket: %w", sessionID, err)
	}
	return id.Int64, nil
}

// ticketSubtreeCTE is targetID (?1) and its descendants on workbench ?2's
// board; UNION ends the walk on a row already seen.
const ticketSubtreeCTE = `WITH RECURSIVE down(id) AS (
		SELECT id FROM targets WHERE id = ?1 AND project_id = ?2
		UNION
		SELECT t.id FROM targets t JOIN down ON t.parent_id = down.id WHERE t.project_id = ?2
	)`

// OpenTicketLeaves lists the leaves of targetID's subtree on workbench
// projectID's board — targetID itself when it has no sub-targets — whose
// status is todo, in_progress or in_review, by id. An open target is never
// archived (PROJ-15), so no archive filter is needed.
func (db *DB) OpenTicketLeaves(projectID, targetID int64) ([]OpenTicketLeaf, error) {
	rows, err := db.Query(ticketSubtreeCTE+`
		SELECT t.id, t.status, t.text FROM targets t JOIN down ON t.id = down.id
		WHERE t.status IN ('todo', 'in_progress', 'in_review')
		  AND NOT EXISTS (SELECT 1 FROM targets c WHERE c.parent_id = t.id AND c.project_id = ?2)
		ORDER BY t.id`, targetID, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading the open leaves of target %d: %w", targetID, err)
	}
	defer rows.Close()
	var out []OpenTicketLeaf
	for rows.Next() {
		var l OpenTicketLeaf
		if err := rows.Scan(&l.ID, &l.Status, &l.Text); err != nil {
			return nil, fmt.Errorf("reading the open leaves of target %d: %w", targetID, err)
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// InTicketSubtree reports whether id is targetID or one of its descendants
// on workbench projectID's board.
func (db *DB) InTicketSubtree(projectID, targetID, id int64) (bool, error) {
	var in bool
	err := db.QueryRow(ticketSubtreeCTE+` SELECT EXISTS (SELECT 1 FROM down WHERE id = ?3)`,
		targetID, projectID, id).Scan(&in)
	if err != nil {
		return false, fmt.Errorf("checking target %d under target %d: %w", id, targetID, err)
	}
	return in, nil
}
