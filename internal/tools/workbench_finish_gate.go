package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/gitbin"
	"watchtower/internal/reviewai"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/workbenchmethod"
)

// The finish_session gates (spec 2026-10-24-finish-whole-ticket, PROJ-14): a
// session finishes the whole ticket it was started for, checked against the
// reviewer's AI overview of its changes. Neither calls the model or writes the
// database (the snapshot writes only git objects, as annotate_changes does);
// both run with the workbench's finish check on, and a handover ask of this
// session passes both.

// finishGateBudget bounds the gate's git work (snapshot, base, tree compare);
// a var for tests.
var finishGateBudget = 30 * time.Second

// maxListedLeaves caps the open leaves a refusal lists.
const maxListedLeaves = 20

// finishGateExecutable is the binary the refusal's overview command names; a
// var for tests.
var finishGateExecutable = os.Executable

// ReviewSnapshot is a session folder as it stands, for the AI overview.
type ReviewSnapshot struct {
	Repo *reviewdiff.Repo
	// Folder is the snapshot folder's root (ReviewSessionFolder).
	Folder     string
	Tree, Base string
	// Empty: the tree is the base's — nothing to review.
	Empty bool
}

// SnapshotReviewSession snapshots session sessionID's review folder and finds
// its base (the merge-base with the default branch).
func SnapshotReviewSession(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64) (ReviewSnapshot, error) {
	folder, err := ReviewSessionFolder(ctx, d, p, sessionID)
	if err != nil {
		return ReviewSnapshot{}, err
	}
	repo, err := reviewdiff.Open(folder, nil)
	if err != nil {
		return ReviewSnapshot{}, err
	}
	tree, err := repo.Snapshot(ctx)
	if err != nil {
		return ReviewSnapshot{}, err
	}
	base, err := repo.Base(ctx)
	if err != nil {
		return ReviewSnapshot{}, err
	}
	same, err := repo.SameTree(ctx, base.SHA, tree)
	if err != nil {
		return ReviewSnapshot{}, err
	}
	return ReviewSnapshot{Repo: repo, Folder: folder, Tree: tree, Base: base.SHA, Empty: same}, nil
}

// checkFinishGates runs both gates for session on workbench p; a refusal is
// a *ValidationError naming what is open and the next step.
func checkFinishGates(ctx context.Context, d *db.DB, p *db.Workbench, session int64, a finishSessionArgs) error {
	if !workbenchmethod.ResolveSession(d, p.ID, session).FinishOn() {
		return nil // the owner turned the finish check off; a read failure resolves to on
	}
	ticket, err := finishTicket(d, session, a)
	if err != nil {
		return err
	}
	handover, err := checkHandoverAsk(d, p.ID, session, ticket, a.HandoverAskID)
	if err != nil {
		return err
	}
	if ticket != 0 && !handover {
		leaves, err := d.OpenTicketLeaves(p.ID, ticket)
		if err != nil {
			return err
		}
		if len(leaves) > 0 {
			return &ValidationError{Msg: openLeavesRefusal(ticket, leaves)}
		}
	}
	if handover {
		return nil // the owner reads what is left in the ask
	}
	return checkOverviewGate(ctx, d, p, session)
}

// finishTicket is the session's launch target, else the call's target_id
// (0 = none).
func finishTicket(d *db.DB, session int64, a finishSessionArgs) (int64, error) {
	ticket, err := d.SessionTicket(session)
	if err != nil || ticket != 0 {
		return ticket, err
	}
	return a.TargetID, nil
}

// checkHandoverAsk: no id is no handover; an id must name an ask of this
// workbench filed by this session, not withdrawn, about the ticket's subtree
// when there is a ticket.
func checkHandoverAsk(d *db.DB, workbenchID, session, ticket, askID int64) (bool, error) {
	if askID == 0 {
		return false, nil
	}
	ask, err := d.GetOwnerAsk(workbenchID, askID)
	if errors.Is(err, db.ErrAskNotFound) {
		return false, &ValidationError{Msg: fmt.Sprintf("handover_ask_id: no ask with id %d in this workbench", askID)}
	}
	if err != nil {
		return false, err
	}
	switch {
	case !ask.SessionID.Valid || ask.SessionID.Int64 != session:
		return false, &ValidationError{Msg: fmt.Sprintf("handover_ask_id: ask #%d was not filed by this session", askID)}
	case ask.Status == "withdrawn":
		return false, &ValidationError{Msg: fmt.Sprintf("handover_ask_id: ask #%d is withdrawn", askID)}
	case ticket == 0:
		return true, nil
	case !ask.TargetID.Valid:
		return false, &ValidationError{Msg: fmt.Sprintf("handover_ask_id: ask #%d names no target; file it about #%d or one of its sub-targets", askID, ticket)}
	}
	in, err := d.InTicketSubtree(workbenchID, ticket, ask.TargetID.Int64)
	if err != nil {
		return false, err
	}
	if !in {
		return false, &ValidationError{Msg: fmt.Sprintf("handover_ask_id: ask #%d is about #%d, outside this session's ticket #%d",
			askID, ask.TargetID.Int64, ticket)}
	}
	return true, nil
}

func openLeavesRefusal(ticket int64, leaves []db.OpenTicketLeaf) string {
	var b strings.Builder
	noun := "leaves"
	if len(leaves) == 1 {
		noun = "leaf"
	}
	fmt.Fprintf(&b, "this session's ticket #%d still has %d open %s — the work is the whole ticket, an order of parts is not a scope cut:",
		ticket, len(leaves), noun)
	for i, l := range leaves {
		if i == maxListedLeaves {
			fmt.Fprintf(&b, "\n… %d more", len(leaves)-maxListedLeaves)
			break
		}
		fmt.Fprintf(&b, "\n#%d [%s] %s", l.ID, l.Status, l.Text)
	}
	b.WriteString("\nFinish them, or file one ask_owner about the ticket that says why each is not needed now, " +
		"and call finish_session again with handover_ask_id")
	return b.String()
}

// checkOverviewGate is gate 2: with a diff, the cached overview of the
// session's folder as it stands, with a done coverage entry for every intent
// item. A folder outside git has no diff to check, nor has the workbench
// folder once the session left a worktree of its own (leftItsWorktree); any
// other git failure refuses.
func checkOverviewGate(ctx context.Context, d *db.DB, p *db.Workbench, session int64) error {
	gitCtx, cancel := context.WithTimeout(ctx, finishGateBudget)
	defer cancel()
	snap, err := SnapshotReviewSession(gitCtx, d, p, session)
	if errors.Is(err, reviewdiff.ErrNotRepository) || errors.Is(err, gitbin.ErrUnavailable) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("finish check: reading the session's changes: %w", err)
	}
	if snap.Empty {
		return nil
	}
	if left, err := leftItsWorktree(gitCtx, d, p, session, snap.Folder); err != nil || left {
		return err
	}
	in, err := ReviewOverviewInput(gitCtx, d, p, session)
	if err != nil {
		return fmt.Errorf("finish check: reading the session's intent: %w", err)
	}
	js, ok, err := d.ReviewOverviewJSON(p.ID, snap.Tree, snap.Base, reviewai.IntentHash(in.Intent, in.Notes))
	if err != nil {
		return fmt.Errorf("finish check: %w", err)
	}
	if !ok {
		return &ValidationError{Msg: missingOverviewRefusal(p.ID, session)}
	}
	var ov reviewai.Overview
	if err := json.Unmarshal([]byte(js), &ov); err != nil {
		return fmt.Errorf("finish check: reading the cached overview: %w", err)
	}
	open := uncoveredItems(in.Intent, ov.Coverage)
	if len(open) > 0 {
		return &ValidationError{Msg: "the reviewer's AI overview of your changes does not see all of the work done:\n" +
			strings.Join(open, "\n") + "\nFinish what is partial or not found, or file one ask_owner that says why it is " +
			"not needed (or why the reviewer is wrong), and call finish_session again with handover_ask_id"}
	}
	return nil
}

func missingOverviewRefusal(workbenchID, session int64) string {
	cmd := "watchtower workbench review overview --workbench " + fmt.Sprint(workbenchID) + " --session " + fmt.Sprint(session) + " --json"
	if bin, err := finishGateExecutable(); err == nil {
		cmd = devpack.ReviewOverviewCommand(bin, workbenchID, session)
	}
	return "your changes have no AI overview yet: annotate_changes first if you have notes, then run `" + cmd +
		"`, compare its coverage with your work, and call finish_session again. If the overview cannot be made, " +
		"file one ask_owner that says so and pass it as handover_ask_id"
}

// uncoveredItems lists every intent item without a done coverage entry: a
// partial or not_found one with its status, an item the overview left out as
// missing. A pass needs an affirmative done for each item, never only the
// absence of a bad one.
func uncoveredItems(intent []reviewai.IntentItem, coverage []reviewai.Coverage) []string {
	byIndex := map[int]reviewai.Coverage{}
	for _, c := range coverage {
		byIndex[c.Index] = c
	}
	var open []string
	for i, it := range intent {
		c, ok := byIndex[i+1]
		switch {
		case !ok:
			open = append(open, fmt.Sprintf("%d. [missing] %s", i+1, it.Text))
		case c.Status != "done":
			open = append(open, fmt.Sprintf("%d. [%s] %s", i+1, c.Status, c.Item))
		}
	}
	return open
}

// leftItsWorktree: the snapshot folder is the workbench folder, but the
// session worked in a worktree of its own — it was launched in one, or its
// agent recorded one — and has left it (the cleanup step). The workbench
// folder's diff is then not this session's work, possibly another live
// session's, so gate 2 does not judge it (v1 limit: the skill runs the check
// before leaving the worktree).
func leftItsWorktree(ctx context.Context, d *db.DB, p *db.Workbench, session int64, folder string) (bool, error) {
	main := realFolder(p.FolderPath)
	if realFolder(folder) != main {
		return false, nil
	}
	row, err := d.GetTerminalSession(session)
	if err != nil {
		return false, fmt.Errorf("finish check: %w", err)
	}
	if row.FolderPath != "" && realFolder(row.FolderPath) != main {
		return true, nil
	}
	worktrees, err := d.SessionWorktrees(ctx, session)
	if err != nil {
		return false, fmt.Errorf("finish check: %w", err)
	}
	for _, w := range worktrees {
		if realFolder(w.Root) != main {
			return true, nil
		}
	}
	return false, nil
}

// realFolder is path with symlinks resolved, or cleaned when it cannot be.
func realFolder(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return filepath.Clean(path)
}
