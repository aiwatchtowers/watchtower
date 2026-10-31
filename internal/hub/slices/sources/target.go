package sources

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
)

// The board window (WorkbenchTargetWindow) and the target slice's caps.
const (
	maxOpenTargets     = 2000
	maxArchivedTargets = 500
	archivedDays       = 90
	maxSessionIDs      = 20
	maxTargetText      = 300
	maxIntent          = 4000
	maxPR              = 120
	maxWorkOnPrompt    = 1000
)

// targetWindow is WorkbenchTargetWindow: which board targets the hub
// publishes (mobile POC spec §4.3), one definition for the target, comment
// and workbench sources. Per workbench: every non-archived target, ≤ 2000,
// newest updated_at first; plus the archived ones whose last close is in
// the last 90 days, ≤ 500, newest close first. Board targets only
// (project_id IS NOT NULL, PROJ-01); the archive verdict is the
// workbench_target_archive view's (PROJ-15). An archived target's last close
// is its subtree's newest close, so a group is never older than its
// children, and on equal close times the larger subtree ranks first: an
// archived child's parent_id always names a published group.
type targetWindow struct {
	published      map[int64]bool // target id → archived
	more           map[int64]int  // workbench id → board targets left out
	doneUnarchived map[int64]int  // workbench id → done targets not archived
}

func loadTargetWindow(ctx context.Context, tx *sql.Tx, now time.Time) (targetWindow, error) {
	cutoff := now.Add(-archivedDays * 24 * time.Hour)
	rows, err := tx.QueryContext(ctx, `
WITH RECURSIVE
node(id, parent_id, project_id, closed_at) AS (
    SELECT t.id, t.parent_id, t.project_id,
           julianday(COALESCE((SELECT MAX(h.changed_at) FROM target_status_history h WHERE h.target_id = t.id),
                              t.updated_at))
    FROM targets t
    WHERE t.project_id IS NOT NULL
),
up(ancestor, parent_id, project_id, descendant, closed_at) AS (
    SELECT id, parent_id, project_id, id, closed_at FROM node
    UNION
    SELECT a.id, a.parent_id, up.project_id, up.descendant, up.closed_at
    FROM up JOIN targets a ON a.id = up.parent_id AND a.project_id = up.project_id
),
subtree AS (
    SELECT ancestor AS id, MAX(closed_at) AS closed_at, COUNT(*) AS size FROM up GROUP BY ancestor
),
board AS (
    SELECT t.id, t.project_id, t.status, julianday(t.updated_at) AS updated, a.archived,
           s.closed_at, s.size
    FROM targets t
    JOIN workbench_target_archive a ON a.target_id = t.id
    JOIN subtree s ON s.id = t.id
    WHERE t.project_id IS NOT NULL
)
SELECT id, project_id, status, archived,
       ROW_NUMBER() OVER (
           PARTITION BY project_id, archived
           ORDER BY CASE WHEN archived THEN closed_at ELSE updated END DESC,
                    CASE WHEN archived THEN size ELSE 0 END DESC,
                    id DESC
       ) AS rank
FROM board
WHERE archived = 0 OR closed_at >= julianday(?)`, sqliteDate(cutoff))
	if err != nil {
		return targetWindow{}, fmt.Errorf("reading the board window: %w", err)
	}
	defer rows.Close()
	w := targetWindow{published: map[int64]bool{}, more: map[int64]int{}, doneUnarchived: map[int64]int{}}
	for rows.Next() {
		var (
			id, project int64
			status      string
			archived    bool
			rank        int
		)
		if err := rows.Scan(&id, &project, &status, &archived, &rank); err != nil {
			return targetWindow{}, fmt.Errorf("reading the board window: %w", err)
		}
		if !archived && status == "done" {
			w.doneUnarchived[project]++
		}
		limit := maxOpenTargets
		if archived {
			limit = maxArchivedTargets
		}
		if rank <= limit {
			w.published[id] = archived
		} else {
			w.more[project]++
		}
	}
	if err := rows.Err(); err != nil {
		return targetWindow{}, fmt.Errorf("reading the board window: %w", err)
	}
	return w, nil
}

// WorkbenchTargets is the `workbench_target` slice (mobile POC spec §4.3),
// record `workbench_target-<targets.id>`: the published workbenches' board
// targets inside the board window, with the tree, the comment counters and
// the archive flag, resolved and capped. Wire shape: the Kit mirror
// WatchtowerKit.WorkbenchTarget. now (nil = time.Now) is the window's clock.
func WorkbenchTargets(d *db.DB, now func() time.Time) hubslices.Source {
	if now == nil {
		now = time.Now
	}
	return &targetSource{d: d, now: now}
}

type targetSource struct {
	d   *db.DB
	now func() time.Time
}

func (s *targetSource) Kind() hubslices.Kind { return "workbench_target" }

type targetPayload struct {
	ID                  int64      `json:"id"`
	WorkbenchID         int64      `json:"workbench_id"`
	ParentID            *int64     `json:"parent_id,omitempty"`
	Text                string     `json:"text"`
	TextClipped         *bool      `json:"text_clipped,omitempty"`
	Intent              string     `json:"intent"`
	IntentClipped       *bool      `json:"intent_clipped,omitempty"`
	Status              string     `json:"status"`
	Priority            string     `json:"priority"`
	Progress            float64    `json:"progress"`
	Branch              string     `json:"branch"`
	BranchClipped       *bool      `json:"branch_clipped,omitempty"`
	PR                  string     `json:"pr"`
	PRClipped           *bool      `json:"pr_clipped,omitempty"`
	Archived            bool       `json:"archived"`
	Column              *string    `json:"column,omitempty"`
	ChildrenCount       int        `json:"children_count"`
	OpenComments        int        `json:"open_comments"`
	UnreadForOwner      int        `json:"unread_for_owner"`
	OpenAsks            int        `json:"open_asks"`
	SessionIDs          []int64    `json:"session_ids"`
	SessionIDsMore      *int       `json:"session_ids_more,omitempty"`
	LastStatusAt        *wire.Time `json:"last_status_at,omitempty"`
	LastStatusActor     *string    `json:"last_status_actor,omitempty"`
	WorkOnPrompt        string     `json:"work_on_prompt"`
	WorkOnPromptClipped *bool      `json:"work_on_prompt_clipped,omitempty"`
	CreatedAt           wire.Time  `json:"created_at"`
	UpdatedAt           wire.Time  `json:"updated_at"`
}

// boardTarget is one targets row of a board with its comment counters.
type boardTarget struct {
	id, project                      int64
	parent, column                   sql.NullInt64
	text, intent, status, priority   string
	branch, pr, createdAt, updatedAt string
	progress                         float64
	openComments, unreadForOwner     int
}

func (s *targetSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	var items []hubslices.Item
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		refs, err := publishedRefs(ctx, tx)
		if err != nil || len(refs) == 0 {
			return err
		}
		window, err := loadTargetWindow(ctx, tx, s.now())
		if err != nil {
			return err
		}
		facts, err := loadTargetFacts(ctx, tx)
		if err != nil {
			return err
		}
		for _, wb := range refs {
			cols, err := boardColumns(ctx, tx, wb.id)
			if err != nil {
				return err
			}
			targets, err := boardTargets(ctx, tx, wb.id)
			if err != nil {
				return err
			}
			for _, n := range boardForest(targets) {
				archived, ok := window.published[n.t.id]
				if !ok {
					continue
				}
				b, err := wire.Marshal(targetPayloadOf(n, wb.id, archived, cols, facts))
				if err != nil {
					return err
				}
				items = append(items, hubslices.Item{ID: strconv.FormatInt(n.t.id, 10), Payload: b})
			}
		}
		return nil
	})
	return items, err
}

func targetPayloadOf(n boardNode, workbenchID int64, archived bool, cols db.BoardColumns, f targetFacts) targetPayload {
	t := n.t
	record := "workbench_target-" + strconv.FormatInt(t.id, 10)
	text, textClipped := clipText(t.text, maxTargetText)
	intent, intentClipped := clipText(t.intent, maxIntent)
	branch, branchClipped := clipText(t.branch, maxBranch)
	pr, prClipped := clipText(t.pr, maxPR)
	sessions, sessionsMore := clipList(f.sessions[t.id], maxSessionIDs)
	if sessions == nil {
		sessions = []int64{}
	}
	prompt, promptClipped := clipText(workOnTargetPrompt(t.id), maxWorkOnPrompt)
	p := targetPayload{
		ID: t.id, WorkbenchID: workbenchID, ParentID: n.parent,
		Text: text, TextClipped: textClipped,
		Intent: intent, IntentClipped: intentClipped,
		Status: t.status, Priority: t.priority, Progress: t.progress,
		Branch: branch, BranchClipped: branchClipped,
		PR: pr, PRClipped: prClipped,
		Archived:       archived,
		ChildrenCount:  n.children,
		OpenComments:   t.openComments,
		UnreadForOwner: t.unreadForOwner,
		OpenAsks:       f.openAsks[t.id],
		SessionIDs:     sessions, SessionIDsMore: sessionsMore,
		WorkOnPrompt: prompt, WorkOnPromptClipped: promptClipped,
		CreatedAt: requiredDate(t.createdAt, "created_at", record),
		UpdatedAt: requiredDate(t.updatedAt, "updated_at", record),
	}
	if n.children == 0 {
		var stored *int64
		if t.column.Valid {
			stored = &t.column.Int64
		}
		if title, ok := effectiveColumn(t.status, stored, cols); ok {
			p.Column = &title
		}
	}
	if last, ok := f.lastStatus[t.id]; ok {
		p.LastStatusAt = parseDate(last.at)
		actor := last.actor
		p.LastStatusActor = &actor
	}
	return p
}

// workOnTargetPrompt is TerminalLaunch.workOnTargetPrompt: the first prompt
// of a Work on It session on a target.
func workOnTargetPrompt(id int64) string {
	return "Work on target #" + strconv.FormatInt(id, 10) + " using the " + devpack.WorkbenchSkillName + " skill."
}

// effectiveColumn is BoardColumnLayout.effectiveColumn's title: the defined
// column a card of status stored in column shows in — the stored one when
// it is one of its status's columns, else the status's first; none for a
// hidden status or one without defined columns.
func effectiveColumn(status string, column *int64, cols db.BoardColumns) (string, bool) {
	if cols.IsHidden(status) {
		return "", false
	}
	first, found := "", false
	for _, c := range cols.Columns {
		if c.Status != status {
			continue
		}
		if column != nil && c.ID == *column {
			return c.Title, true
		}
		if !found {
			first, found = c.Title, true
		}
	}
	return first, found
}

// boardColumns is WorkbenchQueries.boardColumns (Go's GetBoardColumns, read
// inside the source's transaction): the columns in status order, then
// position; an undecodable hidden-status setting fails the read rather than
// reading as nothing hidden.
func boardColumns(ctx context.Context, tx *sql.Tx, workbenchID int64) (db.BoardColumns, error) {
	var hidden sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT board_hidden_statuses FROM projects WHERE id = ?`, workbenchID).Scan(&hidden); err != nil {
		return db.BoardColumns{}, fmt.Errorf("reading workbench %d hidden statuses: %w", workbenchID, err)
	}
	var out db.BoardColumns
	if hidden.Valid {
		var stored []string
		if err := json.Unmarshal([]byte(hidden.String), &stored); err != nil {
			return db.BoardColumns{}, fmt.Errorf("parsing workbench %d hidden statuses: %w", workbenchID, err)
		}
		for _, s := range db.HideableStatuses {
			if slices.Contains(stored, s) {
				out.Hidden = append(out.Hidden, s)
			}
		}
	}
	rows, err := tx.QueryContext(ctx, `
SELECT id, status, title FROM workbench_board_columns WHERE project_id = ?
ORDER BY CASE status WHEN 'todo' THEN 0 WHEN 'in_progress' THEN 1 WHEN 'in_review' THEN 2
    WHEN 'blocked' THEN 3 WHEN 'done' THEN 4 ELSE 5 END, position, id`, workbenchID)
	if err != nil {
		return db.BoardColumns{}, fmt.Errorf("reading workbench %d board columns: %w", workbenchID, err)
	}
	defer rows.Close()
	for rows.Next() {
		var c db.BoardColumn
		if err := rows.Scan(&c.ID, &c.Status, &c.Title); err != nil {
			return db.BoardColumns{}, fmt.Errorf("reading workbench %d board columns: %w", workbenchID, err)
		}
		out.Columns = append(out.Columns, c)
	}
	if err := rows.Err(); err != nil {
		return db.BoardColumns{}, fmt.Errorf("reading workbench %d board columns: %w", workbenchID, err)
	}
	return out, nil
}

// boardTargets reads workbench workbenchID's targets with the board
// counters (WorkbenchQueries.boardCounters): open owner roots and unread
// agent comments per target.
func boardTargets(ctx context.Context, tx *sql.Tx, workbenchID int64) ([]boardTarget, error) {
	rows, err := tx.QueryContext(ctx, `
SELECT t.id, t.project_id, t.parent_id, t.board_column_id, t.text, t.intent, t.status, t.priority,
       t.branch, t.pr, t.created_at, t.updated_at, t.progress,
       COALESCE(c.open_count, 0), COALESCE(c.unread_count, 0)
FROM targets t
LEFT JOIN (
    SELECT target_id,
           SUM(parent_id IS NULL AND status = 'open' AND author = 'owner') AS open_count,
           SUM(author = 'agent' AND read_at = '') AS unread_count
    FROM project_comments WHERE project_id = ?1 AND target_id IS NOT NULL
    GROUP BY target_id
) c ON c.target_id = t.id
WHERE t.project_id = ?1
ORDER BY t.id`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading workbench %d targets: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []boardTarget
	for rows.Next() {
		var t boardTarget
		if err := rows.Scan(&t.id, &t.project, &t.parent, &t.column, &t.text, &t.intent, &t.status, &t.priority,
			&t.branch, &t.pr, &t.createdAt, &t.updatedAt, &t.progress, &t.openComments, &t.unreadForOwner); err != nil {
			return nil, fmt.Errorf("reading workbench %d targets: %w", workbenchID, err)
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading workbench %d targets: %w", workbenchID, err)
	}
	return out, nil
}

// boardNode is a target placed in its board's tree: its parent on the same
// board (nil at the top, and for an orphan whose parent is elsewhere) and
// its child count.
type boardNode struct {
	t        boardTarget
	parent   *int64
	children int
}

// boardForest is WorkbenchQueries.board's tree, flattened: every target
// reachable from the board's roots (a parent cycle, which no writer can
// create, is never reached), with its in-board parent and child count.
func boardForest(targets []boardTarget) []boardNode {
	onBoard := make(map[int64]bool, len(targets))
	for _, t := range targets {
		onBoard[t.id] = true
	}
	children := map[int64][]boardTarget{}
	var stack []boardNode
	for _, t := range targets {
		if t.parent.Valid && onBoard[t.parent.Int64] {
			children[t.parent.Int64] = append(children[t.parent.Int64], t)
		} else {
			stack = append(stack, boardNode{t: t})
		}
	}
	out := make([]boardNode, 0, len(targets))
	for len(stack) > 0 {
		n := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		kids := children[n.t.id]
		n.children = len(kids)
		out = append(out, n)
		for _, c := range kids {
			parent := n.t.id
			stack = append(stack, boardNode{t: c, parent: &parent})
		}
	}
	return out
}

// targetFacts are per-target facts the board does not carry, read once for
// all boards (the Swift TargetFacts).
type targetFacts struct {
	openAsks   map[int64]int
	sessions   map[int64][]int64 // agent sessions, the most recently active first
	lastStatus map[int64]statusMove
}

type statusMove struct{ at, actor string }

func loadTargetFacts(ctx context.Context, tx *sql.Tx) (targetFacts, error) {
	f := targetFacts{openAsks: map[int64]int{}, sessions: map[int64][]int64{}, lastStatus: map[int64]statusMove{}}
	err := scanRows(ctx, tx, `
SELECT target_id, COUNT(*) FROM owner_asks a
WHERE status = 'open' AND `+askVisible+` AND target_id IS NOT NULL GROUP BY target_id`, nil,
		func(r *sql.Rows) error {
			var id int64
			var n int
			if err := r.Scan(&id, &n); err != nil {
				return err
			}
			f.openAsks[id] = n
			return nil
		})
	if err != nil {
		return f, fmt.Errorf("reading target asks: %w", err)
	}
	err = scanRows(ctx, tx, `
SELECT link.target_id, s.id
FROM (
    SELECT id AS session_id, target_id FROM terminal_sessions WHERE target_id IS NOT NULL
    UNION
    SELECT session_id, target_id FROM terminal_session_targets
) AS link
JOIN terminal_sessions s ON s.id = link.session_id
WHERE s.kind IN ('claude','codex') AND s.project_id IS NOT NULL
ORDER BY link.target_id, s.last_active_at DESC, s.id DESC`, nil, func(r *sql.Rows) error {
		var target, session int64
		if err := r.Scan(&target, &session); err != nil {
			return err
		}
		f.sessions[target] = append(f.sessions[target], session)
		return nil
	})
	if err != nil {
		return f, fmt.Errorf("reading target sessions: %w", err)
	}
	err = scanRows(ctx, tx, `
SELECT h.target_id, h.changed_at, h.actor FROM target_status_history h
JOIN (SELECT target_id, MAX(id) AS id FROM target_status_history GROUP BY target_id) newest
  ON newest.id = h.id`, nil, func(r *sql.Rows) error {
		var id int64
		var m statusMove
		if err := r.Scan(&id, &m.at, &m.actor); err != nil {
			return err
		}
		f.lastStatus[id] = m
		return nil
	})
	if err != nil {
		return f, fmt.Errorf("reading target status history: %w", err)
	}
	return f, nil
}

// scanRows runs query and calls each for every row.
func scanRows(ctx context.Context, tx *sql.Tx, query string, args []any, each func(*sql.Rows) error) error {
	rows, err := tx.QueryContext(ctx, query, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := each(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}
