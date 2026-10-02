package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// BoardNode is one target of a workbench board with its subtree, its comment
// counters and the documents attached to it.
type BoardNode struct {
	Target         Target
	Children       []BoardNode
	NewForAgent    int // comments the agent has not answered (newForAgentPredicate)
	UnreadForOwner int // agent comments with an empty read_at
	Documents      []WorkbenchDocument
	// StatusSince is when the target entered its current status (its latest
	// target_status_history row, UTC ISO-8601); "" when it has none.
	StatusSince string
}

// boardSiblingOrder sorts siblings by priority (high, medium, low), then by
// status (in_progress, in_review, blocked, todo, done, then dismissed/snoozed),
// then id.
const boardSiblingOrder = `CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END,
	CASE status WHEN 'in_progress' THEN 0 WHEN 'in_review' THEN 1 WHEN 'blocked' THEN 2
	WHEN 'todo' THEN 3 WHEN 'done' THEN 4 ELSE 5 END, id`

type boardCounts struct{ newForAgent, unreadForOwner int }

// GetWorkbenchBoard returns workbench projectID's target forest. An unknown
// workbench yields an empty board; callers check GetWorkbench first.
func (db *DB) GetWorkbenchBoard(projectID int64) ([]BoardNode, error) {
	targets, err := db.listBoardTargets(projectID)
	if err != nil {
		return nil, err
	}
	counts, err := db.boardCommentCounts(projectID)
	if err != nil {
		return nil, err
	}
	docs, err := db.ListWorkbenchDocuments(projectID)
	if err != nil {
		return nil, err
	}
	since, err := db.workbenchStatusSince(projectID)
	if err != nil {
		return nil, err
	}
	return assembleBoard(targets, counts, docs, since), nil
}

func (db *DB) listBoardTargets(projectID int64) ([]Target, error) {
	rows, err := db.Query(`SELECT `+targetSelectCols+` FROM targets WHERE project_id = ? ORDER BY `+boardSiblingOrder, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing board targets: %w", err)
	}
	defer rows.Close()
	var out []Target
	for rows.Next() {
		t, err := scanTarget(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning board target: %w", err)
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

func (db *DB) boardCommentCounts(projectID int64) (map[int64]boardCounts, error) {
	rows, err := db.Query(`SELECT c.target_id,
		SUM(CASE WHEN `+newForAgentPredicate+` THEN 1 ELSE 0 END),
		SUM(CASE WHEN c.author = 'agent' AND c.read_at = '' THEN 1 ELSE 0 END)
		FROM project_comments c
		WHERE c.project_id = ? AND c.target_id IS NOT NULL
		GROUP BY c.target_id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("counting board comments: %w", err)
	}
	defer rows.Close()
	out := map[int64]boardCounts{}
	for rows.Next() {
		var id int64
		var c boardCounts
		if err := rows.Scan(&id, &c.newForAgent, &c.unreadForOwner); err != nil {
			return nil, fmt.Errorf("scanning board comment counts: %w", err)
		}
		out[id] = c
	}
	return out, rows.Err()
}

// boardIndex builds the forest from the flat, already-ordered target list.
type boardIndex struct {
	children map[int64][]Target
	counts   map[int64]boardCounts
	docs     map[int64][]WorkbenchDocument
	seen     map[int64]bool
	since    map[int64]string
}

func assembleBoard(targets []Target, counts map[int64]boardCounts, docs []WorkbenchDocument, since map[int64]string) []BoardNode {
	onBoard := make(map[int64]bool, len(targets))
	for _, t := range targets {
		onBoard[int64(t.ID)] = true
	}
	ix := boardIndex{children: map[int64][]Target{}, counts: counts, docs: map[int64][]WorkbenchDocument{}, seen: map[int64]bool{}, since: since}
	for _, d := range docs {
		if d.TargetID.Valid {
			ix.docs[d.TargetID.Int64] = append(ix.docs[d.TargetID.Int64], d)
		}
	}
	var roots []Target
	for _, t := range targets {
		if t.ParentID.Valid && onBoard[t.ParentID.Int64] {
			ix.children[t.ParentID.Int64] = append(ix.children[t.ParentID.Int64], t)
			continue
		}
		roots = append(roots, t)
	}
	return ix.build(roots)
}

// build turns one sibling list into nodes. seen stops a parent cycle (which
// no workbench writer can create) from recursing forever.
func (ix boardIndex) build(level []Target) []BoardNode {
	nodes := make([]BoardNode, 0, len(level))
	for _, t := range level {
		id := int64(t.ID)
		if ix.seen[id] {
			continue
		}
		ix.seen[id] = true
		c := ix.counts[id]
		nodes = append(nodes, BoardNode{Target: t, NewForAgent: c.newForAgent, UnreadForOwner: c.unreadForOwner,
			Documents: ix.docs[id], StatusSince: ix.since[id], Children: ix.build(ix.children[id])})
	}
	return nodes
}

// MoveWorkbenchTargetTx nests target id of workbench projectID under parent,
// or moves it to the top level when parent is not Valid (board #186). Both
// must be on that workbench (ErrNotInWorkbench otherwise, also for a missing
// row), and parent must not be the target or one of its sub-targets
// (ErrParentCycle). An unchanged parent writes nothing. The old and new
// parents' progress is recomputed in tx; their status follows from the
// PROJ-05 rollup triggers, which re-derive both on the parent_id change.
//
// Dual path: the Desktop board moves targets with
// WorkbenchQueries.moveTarget (WatchtowerCore) — change the rules together.
func (db *DB) MoveWorkbenchTargetTx(tx *sql.Tx, projectID, id int64, parent sql.NullInt64) error {
	var owner, oldParent sql.NullInt64
	err := tx.QueryRow(`SELECT project_id, parent_id FROM targets WHERE id = ?`, id).Scan(&owner, &oldParent)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && owner.Int64 != projectID) {
		return fmt.Errorf("target #%d: %w", id, ErrNotInWorkbench)
	}
	if err != nil {
		return fmt.Errorf("loading target #%d: %w", id, err)
	}
	if parent.Valid {
		var parentOwner sql.NullInt64
		err := tx.QueryRow(`SELECT project_id FROM targets WHERE id = ?`, parent.Int64).Scan(&parentOwner)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && parentOwner.Int64 != projectID) {
			return fmt.Errorf("parent target #%d: %w", parent.Int64, ErrNotInWorkbench)
		}
		if err != nil {
			return fmt.Errorf("loading parent target #%d: %w", parent.Int64, err)
		}
		if err := checkParentCycle(tx, id, parent); err != nil {
			return err
		}
	}
	if parent.Valid == oldParent.Valid && (!parent.Valid || parent.Int64 == oldParent.Int64) {
		return nil
	}
	if _, err := tx.Exec(`UPDATE targets SET parent_id = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, parent, id); err != nil {
		return fmt.Errorf("moving target #%d: %w", id, err)
	}
	for _, p := range []sql.NullInt64{oldParent, parent} {
		if p.Valid {
			if err := recomputeParentProgressOn(tx, p.Int64); err != nil {
				return err
			}
		}
	}
	return nil
}
