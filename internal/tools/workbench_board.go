package tools

import (
	"context"
	"encoding/json"
	"fmt"

	"watchtower/internal/db"
)

// ---- workbench_board ---------------------------------------------------

// boardNodeView is one target of the board answer. An open target, or a
// closed one with open work under it, carries every field; a closed target
// with nothing open under it (listed only on request) carries its id, text,
// status and since when only.
type boardNodeView struct {
	ID             int      `json:"id"`
	Text           string   `json:"text"`
	Intent         string   `json:"intent,omitempty"`
	Status         string   `json:"status"`
	Priority       string   `json:"priority,omitempty"`
	Progress       *float64 `json:"progress,omitempty"`
	StatusSince    string   `json:"status_since,omitempty"` // when it entered its current status (UTC)
	Branch         string   `json:"branch,omitempty"`       // the git branch carrying the work (PROJ-07)
	PR             string   `json:"pr,omitempty"`           // the pull request, a number or URL
	NewForAgent    int      `json:"comments_new_for_agent,omitempty"`
	UnreadForOwner int      `json:"comments_unread_for_owner,omitempty"`
	Archived       bool     `json:"archived,omitempty"` // listed with include_archived only (PROJ-15)
	// ClosedChildren and ArchivedChildren count the direct children left out
	// of Children: closed with nothing open under them, and archived.
	ClosedChildren   int             `json:"closed_children,omitempty"`
	ArchivedChildren int             `json:"archived_children,omitempty"`
	Children         []boardNodeView `json:"children,omitempty"`
}

type workbenchBoardView struct {
	WorkbenchID int64           `json:"workbench_id"`
	Targets     []boardNodeView `json:"targets"`
	Closed      int             `json:"closed,omitempty"` // closed targets left out, at every depth
	Archived    int             `json:"archived"`         // archived targets on the board, listed or not
}

type workbenchBoardArgs struct {
	IncludeClosed   bool `json:"include_closed,omitempty" jsonschema:"also list the closed (done/dismissed) targets with nothing open under them, as id, text, status and since only"`
	IncludeArchived bool `json:"include_archived,omitempty" jsonschema:"also list the archived targets (closed long enough ago, or archived with Archive Now); implies include_closed"`
}

// NewWorkbenchBoard returns the bound workbench's target tree with comment
// counters: open work and the closed targets above it by default (owner
// decision A of the 2026-10-04 board archive spec), archived subtrees left
// out (PROJ-15).
func NewWorkbenchBoard() *Tool {
	return &Tool{
		Name: WorkbenchBoardTool,
		Description: "The workbench board: the target tree (ids, status and since when, priority, progress, comment counters; " +
			"siblings sorted by priority, then status). Read it before changing the board. By default it lists open work " +
			"and the closed targets above it; other closed targets are counted (closed_children per target, closed in " +
			"total) and archived ones too (archived_children, archived). include_closed lists the closed ones briefly, " +
			"include_archived the archived ones as well; get_target #id reads any target.",
		InputSchema: mustSchema[workbenchBoardArgs](WorkbenchBoardTool),
		Access:      AccessRead,
		Surfaces:    workbenchSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a workbenchBoardArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			p, err := workbenchOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			board, err := d.GetWorkbenchBoard(p.ID)
			if err != nil {
				return nil, fmt.Errorf("loading board: %w", err)
			}
			return buildBoardView(p.ID, board, a), nil
		},
	}
}

// buildBoardView shapes the full board (GetWorkbenchBoard) into the answer a
// asks for. Pure.
func buildBoardView(workbenchID int64, board []db.BoardNode, a workbenchBoardArgs) workbenchBoardView {
	nodes := board
	if !a.IncludeArchived {
		nodes = db.WithoutArchived(board)
	}
	b := boardViewer{withClosed: a.IncludeClosed || a.IncludeArchived}
	targets := b.views(nodes)
	return workbenchBoardView{WorkbenchID: workbenchID, Targets: targets, Closed: b.omitted, Archived: db.CountArchived(board)}
}

// boardViewer turns board nodes into views; without withClosed it leaves
// out every closed subtree with nothing open in it and counts its targets in
// omitted.
type boardViewer struct {
	withClosed bool
	omitted    int
}

func (b *boardViewer) views(nodes []db.BoardNode) []boardNodeView {
	out := make([]boardNodeView, 0, len(nodes))
	for _, n := range nodes {
		switch {
		case hasOpenWork(n):
			out = append(out, b.openView(n))
		case b.withClosed:
			out = append(out, closedView(n))
		default:
			b.omitted += subtreeSize(n)
		}
	}
	return out
}

func (b *boardViewer) openView(n db.BoardNode) boardNodeView {
	t := n.Target
	progress := t.Progress
	children := b.views(n.Children)
	return boardNodeView{
		ID: t.ID, Text: t.Text, Intent: t.Intent, Status: t.Status, Priority: t.Priority, Progress: &progress,
		StatusSince: n.StatusSince, Branch: t.Branch, PR: t.PR, NewForAgent: n.NewForAgent, UnreadForOwner: n.UnreadForOwner,
		Archived: n.Archived, ClosedChildren: len(n.Children) - len(children), ArchivedChildren: n.ArchivedChildren,
		Children: children,
	}
}

// closedView is the brief form of a closed target with nothing open under
// it; its children are closed too.
func closedView(n db.BoardNode) boardNodeView {
	children := make([]boardNodeView, 0, len(n.Children))
	for _, c := range n.Children {
		children = append(children, closedView(c))
	}
	return boardNodeView{ID: n.Target.ID, Text: n.Target.Text, Status: n.Target.Status, StatusSince: n.StatusSince,
		Archived: n.Archived, ArchivedChildren: n.ArchivedChildren, Children: children}
}

// hasOpenWork reports whether n or a target under it is neither done nor
// dismissed.
func hasOpenWork(n db.BoardNode) bool {
	if !closedStatus(n.Target.Status) {
		return true
	}
	for _, c := range n.Children {
		if hasOpenWork(c) {
			return true
		}
	}
	return false
}

func closedStatus(status string) bool { return status == "done" || status == "dismissed" }

func subtreeSize(n db.BoardNode) int {
	size := 1
	for _, c := range n.Children {
		size += subtreeSize(c)
	}
	return size
}
