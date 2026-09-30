package db

import "fmt"

// BoardNode is one target of a project board with its subtree, its comment
// counters and the documents attached to it.
type BoardNode struct {
	Target         Target
	Children       []BoardNode
	NewForAgent    int // comments the agent has not answered (newForAgentPredicate)
	UnreadForOwner int // agent comments with an empty read_at
	Documents      []ProjectDocument
}

// boardSiblingOrder sorts siblings by priority (high, medium, low), then by
// status (in_progress, blocked, todo, done, then dismissed/snoozed), then id.
const boardSiblingOrder = `CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END,
	CASE status WHEN 'in_progress' THEN 0 WHEN 'blocked' THEN 1
	WHEN 'todo' THEN 2 WHEN 'done' THEN 3 ELSE 4 END, id`

type boardCounts struct{ newForAgent, unreadForOwner int }

// GetProjectBoard returns project projectID's target forest. An unknown
// project yields an empty board; callers check GetProject first.
func (db *DB) GetProjectBoard(projectID int64) ([]BoardNode, error) {
	targets, err := db.listBoardTargets(projectID)
	if err != nil {
		return nil, err
	}
	counts, err := db.boardCommentCounts(projectID)
	if err != nil {
		return nil, err
	}
	docs, err := db.ListProjectDocuments(projectID)
	if err != nil {
		return nil, err
	}
	return assembleBoard(targets, counts, docs), nil
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
	docs     map[int64][]ProjectDocument
	seen     map[int64]bool
}

func assembleBoard(targets []Target, counts map[int64]boardCounts, docs []ProjectDocument) []BoardNode {
	onBoard := make(map[int64]bool, len(targets))
	for _, t := range targets {
		onBoard[int64(t.ID)] = true
	}
	ix := boardIndex{children: map[int64][]Target{}, counts: counts, docs: map[int64][]ProjectDocument{}, seen: map[int64]bool{}}
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
// no project writer can create) from recursing forever.
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
			Documents: ix.docs[id], Children: ix.build(ix.children[id])})
	}
	return nodes
}
