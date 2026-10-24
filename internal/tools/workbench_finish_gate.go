package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
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
// reviewer's AI overview of its changes. Both read only — no model call — and
// run with the workbench's finish check on; a handover ask of this session
// passes both.

// finishGateBudget bounds the gate's git work (snapshot, base, tree compare).
const finishGateBudget = 30 * time.Second

// maxListedLeaves caps the open leaves a refusal lists.
const maxListedLeaves = 20

// finishGateExecutable is the binary the refusal's overview command names; a
// var for tests.
var finishGateExecutable = os.Executable

// ReviewSnapshot is a session folder as it stands, for the AI overview.
type ReviewSnapshot struct {
	Repo       *reviewdiff.Repo
	Tree, Base string
	// Empty: the tree is the base's — nothing to review.
	Empty bool
}

// SnapshotReviewSession snapshots session sessionID's review folder and finds
// its base (the merge-base with the default branch).
func SnapshotReviewSession(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64) (ReviewSnapshot, error) {
	repo, tree, err := snapshotSessionFolder(ctx, d, p, sessionID)
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
	return ReviewSnapshot{Repo: repo, Tree: tree, Base: base.SHA, Empty: same}, nil
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
	fmt.Fprintf(&b, "this session's ticket #%d still has %d open leaves — the work is the whole ticket, an order of parts is not a scope cut:", ticket, len(leaves))
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
// session's folder as it stands, every coverage item done. A folder outside
// git has no diff to check; any other git failure refuses.
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
	in, err := ReviewOverviewInput(gitCtx, d, p, session)
	if err != nil {
		return err
	}
	js, ok, err := d.ReviewOverviewJSON(p.ID, snap.Tree, snap.Base, reviewai.IntentHash(in.Intent, in.Notes))
	if err != nil {
		return err
	}
	if !ok {
		return &ValidationError{Msg: missingOverviewRefusal(p.ID, session)}
	}
	var ov reviewai.Overview
	if err := json.Unmarshal([]byte(js), &ov); err != nil {
		return fmt.Errorf("finish check: reading the cached overview: %w", err)
	}
	var open []string
	for _, c := range ov.Coverage {
		if c.Status != "done" {
			open = append(open, fmt.Sprintf("%d. [%s] %s", c.Index, c.Status, c.Item))
		}
	}
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
