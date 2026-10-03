package sessionreport

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

// boardEntry is one target of a workbench board, flattened.
type boardEntry struct {
	target   db.Target
	parent   int64   // 0 = top level
	children []int64 // in board order
	since    string  // when it entered its current status; "" = no history
	order    int     // position in board order
}

func (e *boardEntry) id() int64 { return int64(e.target.ID) }

func (e *boardEntry) leaf() bool { return len(e.children) == 0 }

// counted reports whether e counts at all: a dismissed target counts in no
// number of the report.
func (e *boardEntry) counted() bool { return e.target.Status != "dismissed" }

// board is a workbench board in board order: depth first, siblings in the
// board's sibling order, so the report lists targets the way the Board shows
// them.
type board struct {
	byID  map[int64]*boardEntry
	order []int64
}

func loadBoard(d *db.DB, projectID int64) (*board, error) {
	nodes, err := d.GetWorkbenchBoard(projectID)
	if err != nil {
		return nil, fmt.Errorf("reading workbench %d board: %w", projectID, err)
	}
	b := &board{byID: map[int64]*boardEntry{}}
	b.add(nodes, 0)
	return b, nil
}

func (b *board) add(level []db.BoardNode, parent int64) {
	for _, n := range level {
		e := &boardEntry{target: n.Target, parent: parent, since: n.StatusSince, order: len(b.order)}
		b.byID[e.id()] = e
		b.order = append(b.order, e.id())
		if parent != 0 {
			b.byID[parent].children = append(b.byID[parent].children, e.id())
		}
		b.add(n.Children, e.id())
	}
}

// walk calls fn on target id and every target under it, in board order. An
// id that is not on the board is skipped.
func (b *board) walk(id int64, fn func(*boardEntry)) {
	e, ok := b.byID[id]
	if !ok {
		return
	}
	fn(e)
	for _, c := range e.children {
		b.walk(c, fn)
	}
}

// leavesUnder is the counted leaves of target id's whole subtree (id itself
// when it is a leaf), in board order.
func (b *board) leavesUnder(id int64) []*boardEntry {
	var out []*boardEntry
	b.walk(id, func(e *boardEntry) {
		if e.leaf() && e.counted() {
			out = append(out, e)
		}
	})
	return out
}

// hasSubParents reports whether target id has a child with children of its
// own; false for an id not on the board.
func (b *board) hasSubParents(id int64) bool {
	e, ok := b.byID[id]
	return ok && slices.ContainsFunc(e.children, func(c int64) bool { return !b.byID[c].leaf() })
}

// hasDoneWork reports whether e is done or has a done leaf under it.
func (b *board) hasDoneWork(e *boardEntry) bool {
	if e.target.Status == "done" {
		return true
	}
	return slices.ContainsFunc(b.leavesUnder(e.id()), func(l *boardEntry) bool { return l.target.Status == "done" })
}

// scope is a session's targets (spec Part 3): the session's own target
// subtree, the targets its agent linked, and the subtrees of linked targets
// that have children.
type scope struct {
	b       *board
	in      map[int64]bool
	session int64 // the session's own target; 0 = none
}

func newScope(b *board, sessionTarget sql.NullInt64, linked []int64) scope {
	s := scope{b: b, in: map[int64]bool{}}
	roots := slices.Clone(linked)
	if sessionTarget.Valid {
		roots = append(roots, sessionTarget.Int64)
		s.session = sessionTarget.Int64
	}
	for _, r := range roots {
		b.walk(r, func(e *boardEntry) { s.in[e.id()] = true })
	}
	return s
}

// targets is the counted in-scope targets, parents included, in board order.
func (s scope) targets() []*boardEntry {
	var out []*boardEntry
	for _, id := range s.b.order {
		if e := s.b.byID[id]; s.in[id] && e.counted() {
			out = append(out, e)
		}
	}
	return out
}

// leaves is the counted in-scope leaves, in board order.
func (s scope) leaves() []*boardEntry {
	var out []*boardEntry
	for _, e := range s.targets() {
		if e.leaf() {
			out = append(out, e)
		}
	}
	return out
}

func (s scope) progress() Progress {
	var p Progress
	for _, e := range s.leaves() {
		p.Total++
		if e.target.Status == "done" {
			p.Done++
		}
	}
	return p
}

// refs is the PR-cache keys of the in-scope targets' PRs and branches, in
// board order of first appearance.
func (s scope) refs() []string {
	var out []string
	for _, e := range s.targets() {
		if p := strings.TrimSpace(e.target.PR); p != "" {
			if ref, _ := prRef(p); !slices.Contains(out, ref) {
				out = append(out, ref)
			}
		}
		if br := strings.TrimSpace(e.target.Branch); br != "" && !slices.Contains(out, branchRef(br)) {
			out = append(out, branchRef(br))
		}
	}
	return out
}

// prRef is the PR-cache key of a target's pr value (a number, #number or a
// pull request URL) and the number, when one can be read. A value that holds
// no number keys by its text, so it still shows (as unknown) in the report.
func prRef(raw string) (string, sql.NullInt64) {
	s := strings.TrimPrefix(strings.TrimSpace(raw), "#")
	digits := s
	if i := strings.LastIndex(s, "/pull/"); i >= 0 {
		digits = s[i+len("/pull/"):]
		if j := strings.IndexFunc(digits, func(r rune) bool { return r < '0' || r > '9' }); j >= 0 {
			digits = digits[:j]
		}
	}
	if n, err := strconv.ParseInt(digits, 10, 64); err == nil && n > 0 {
		return "pr:" + strconv.FormatInt(n, 10), sql.NullInt64{Int64: n, Valid: true}
	}
	return "pr:" + s, sql.NullInt64{}
}

func branchRef(branch string) string { return "branch:" + branch }

// SessionRefs is the PR-cache keys ('pr:<n>' | 'branch:<name>') of the PRs
// and branches session sessionID's in-scope targets carry: the refs a refresh
// of its report checks.
func SessionRefs(ctx context.Context, d *db.DB, projectID, sessionID int64) ([]string, error) {
	_, sc, err := loadScope(ctx, d, projectID, sessionID)
	if err != nil {
		return nil, err
	}
	return sc.refs(), nil
}

// loadScope reads session sessionID of workbench projectID and its scope. A
// missing session, or one of another workbench, is
// db.ErrTerminalSessionNotFound.
func loadScope(ctx context.Context, d *db.DB, projectID, sessionID int64) (Session, scope, error) {
	sess, target, err := loadSession(ctx, d, projectID, sessionID)
	if err != nil {
		return Session{}, scope{}, err
	}
	b, err := loadBoard(d, projectID)
	if err != nil {
		return Session{}, scope{}, err
	}
	linked, err := d.SessionLinkedTargets(sessionID)
	if err != nil {
		return Session{}, scope{}, err
	}
	return sess, newScope(b, target, linked), nil
}

func loadSession(ctx context.Context, d *db.DB, projectID, sessionID int64) (Session, sql.NullInt64, error) {
	var s Session
	var workbench, target sql.NullInt64
	var state, stateAt, finishedAt sql.NullString
	err := d.QueryRowContext(ctx, `SELECT id, project_id, title, target_id, kind, created_at, last_active_at,
		agent_state, agent_state_at, finished_at, finish_summary
		FROM terminal_sessions WHERE id = ?`, sessionID).
		Scan(&s.ID, &workbench, &s.Title, &target, &s.Kind, &s.CreatedAt, &s.LastActiveAt,
			&state, &stateAt, &finishedAt, &s.FinishSummary)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && workbench.Int64 != projectID) {
		return Session{}, sql.NullInt64{}, fmt.Errorf("session %d of workbench %d: %w",
			sessionID, projectID, db.ErrTerminalSessionNotFound)
	}
	if err != nil {
		return Session{}, sql.NullInt64{}, fmt.Errorf("reading terminal session %d: %w", sessionID, err)
	}
	s.TargetID = nullableInt(target)
	s.AgentState, s.AgentStateAt, s.FinishedAt = state.String, stateAt.String, finishedAt.String
	return s, target, nil
}

// workbenchLinks is the linked target ids of every session of workbench
// projectID, by session.
func workbenchLinks(ctx context.Context, d *db.DB, projectID int64) (map[int64][]int64, error) {
	rows, err := d.QueryContext(ctx, `SELECT l.session_id, l.target_id FROM terminal_session_targets l
		JOIN terminal_sessions s ON s.id = l.session_id
		WHERE s.project_id = ? ORDER BY l.session_id, l.target_id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading workbench %d session targets: %w", projectID, err)
	}
	defer rows.Close()
	out := map[int64][]int64{}
	for rows.Next() {
		var sessionID, targetID int64
		if err := rows.Scan(&sessionID, &targetID); err != nil {
			return nil, fmt.Errorf("reading workbench %d session targets: %w", projectID, err)
		}
		out[sessionID] = append(out[sessionID], targetID)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading workbench %d session targets: %w", projectID, err)
	}
	return out, nil
}

func nullableInt(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	return &v.Int64
}
