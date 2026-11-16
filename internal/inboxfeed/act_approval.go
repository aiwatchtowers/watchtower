package inboxfeed

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tools"
	"watchtower/internal/tower/api"
)

// The approval verb on a native approval card (a<agent_actions.id>): the
// owner's decision through the tools registry, pinned to the args the card
// drew (AGENT-07). Approve and retry decide in one short write of their own
// and run the tool afterwards, outside any transaction: over the socket the
// call waits for it up to ApproveWaitCap, over the hub Background runs it and
// the call answers after the decision.

// The ActResult.Status values.
const (
	statusApplying = "applying"
	statusApplied  = "applied"
	statusFailed   = "failed"
)

// interruptedApply is the error a stuck target row's reclaim records, as
// `actions apply --force` does.
const interruptedApply = "reclaimed after an interrupted apply"

func (a actor) approval(ctx context.Context, id int64) (api.ActResult, error) {
	reg := a.deps.Registry
	if reg == nil {
		return api.ActResult{}, a.refuse(api.CodeUnsupported, reasonNoService)
	}
	hub := a.c.Origin.Transport == "hub"
	switch v := a.req.Params.ApprovalVerb; v {
	case api.ApprovalApprove, api.ApprovalRetry:
		if hub && len(a.req.Params.Patch) > 0 {
			// The Mac's Edit… only: the phone approves what it drew.
			return api.ActResult{}, a.refuse(api.CodeNotPermitted, "")
		}
		if hub && a.deps.Background == nil {
			return api.ActResult{}, a.refuse(api.CodeUnsupported, reasonNoService)
		}
		if v == api.ApprovalApprove {
			return a.approve(ctx, reg, id, hub)
		}
		return a.retry(ctx, reg, id, hub)
	case api.ApprovalReject:
		return a.reject(reg, id)
	case api.ApprovalDismiss:
		return a.dismissCall(reg, id)
	}
	return api.ActResult{}, a.unsupported()
}

// row reads action id; not there is not_found.
func (a actor) row(id int64) (*db.AgentAction, error) {
	row, err := a.c.DB.GetAgentAction(id)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, a.refuse(api.CodeNotFound, "")
	}
	return row, nil
}

func (a actor) approve(ctx context.Context, reg *tools.Registry, id int64, hub bool) (api.ActResult, error) {
	row, err := a.row(id)
	if err != nil {
		return api.ActResult{}, err
	}
	if row.Status != "pending" {
		return a.decided(row)
	}
	ok, err := reg.ApproveSeen(ctx, id, a.req.Params.Patch, a.req.Params.ArgsSHA256)
	var v *tools.ValidationError
	switch {
	case errors.Is(err, tools.ErrArgsChanged):
		return api.ActResult{}, a.refuse(api.CodeArgsChanged, "")
	case errors.Is(err, tools.ErrNotFound):
		return api.ActResult{}, a.refuse(api.CodeNotFound, "")
	case errors.As(err, &v):
		return api.ActResult{}, a.refuse(api.CodeChanged, lowerFirst(v.Msg))
	case err != nil:
		return api.ActResult{}, err
	case !ok:
		// Another decision got there first.
		if row, err = a.row(id); err != nil {
			return api.ActResult{}, err
		}
		return a.decided(row)
	}
	if t, known := reg.Get(row.Tool); known && t.AppliedBySession {
		// Its chat session claims it (mayApplyHere): approved, run there.
		return api.ActResult{Status: statusApplying}, nil
	}
	return a.runTool(ctx, reg, id, hub), nil
}

// decided answers a decision on a row that is no longer pending: approved
// or run already (already, with its state), else rejected or dismissed
// under the card (changed).
func (a actor) decided(row *db.AgentAction) (api.ActResult, error) {
	switch row.Status {
	case "approved", "executing", "applied", "failed":
		return api.ActResult{Already: true, Status: actionStatus(row), Error: row.Error}, nil
	}
	return api.ActResult{}, a.refuse(api.CodeChanged, "")
}

// retry re-runs a failed (or approved) row; a stuck target row's executing
// claim is reclaimed first, as its Try again does on the Mac (actions apply
// --force). An older row of a button whose newer proposal is open is never
// retried (AGENT-05).
func (a actor) retry(ctx context.Context, reg *tools.Registry, id int64, hub bool) (api.ActResult, error) {
	row, err := a.row(id)
	if err != nil {
		return api.ActResult{}, err
	}
	newer, err := a.c.DB.NewerOpenButtonProposal(row)
	if err != nil {
		return api.ActResult{}, err
	}
	if newer != 0 {
		return api.ActResult{}, a.refuse(api.CodeChanged, "")
	}
	if t, known := reg.Get(row.Tool); known && t.AppliedBySession {
		return api.ActResult{}, a.refuse(api.CodeUnsupported, "it runs only in its chat on the Mac.")
	}
	switch row.Status {
	case "approved", "failed":
	case "executing":
		if !a.stuck(row) {
			return api.ActResult{Already: true, Status: statusApplying}, nil
		}
		ok, err := a.c.DB.TransitionAgentAction(id, []string{"executing"}, "failed", "", interruptedApply)
		if err != nil {
			return api.ActResult{}, err
		}
		if !ok {
			return api.ActResult{}, a.refuse(api.CodeChanged, "")
		}
	case "applied":
		return api.ActResult{Already: true, Status: statusApplied}, nil
	default:
		return api.ActResult{}, a.refuse(api.CodeChanged, "")
	}
	return a.runTool(ctx, reg, id, hub), nil
}

// stuck is an Inbox target button's row executing past targetStuckAfter
// since its decision: the state the card offers Try again for.
func (a actor) stuck(row *db.AgentAction) bool {
	if row.ContextType != db.InboxButtonContextType {
		return false
	}
	decided, err := time.Parse(time.RFC3339Nano, row.DecidedAt)
	return err == nil && a.now().Sub(decided) >= targetStuckAfter
}

// runTool applies row id (Apply claims it, so two applies never both run
// it) outside any transaction. Over the hub it runs in Background and the
// call answers applying; over the socket the call waits up to
// ApproveWaitCap and answers the row's state, or applying when the tool
// is still running.
func (a actor) runTool(ctx context.Context, reg *tools.Registry, id int64, hub bool) api.ActResult {
	// The tool outlives the call: its context is not the call's.
	runCtx := context.WithoutCancel(ctx)
	apply := func() api.ActResult {
		row, err := reg.Apply(runCtx, id)
		if err != nil {
			log.Printf("inbox.act: applying action %d: %v", id, err)
			if row, err = a.c.DB.GetAgentAction(id); err != nil || row == nil {
				return api.ActResult{Status: statusApplying}
			}
		}
		res := api.ActResult{Status: actionStatus(row), Error: row.Error}
		if err := a.startWatchingIfTrack(runCtx, row); err != nil {
			res.Error = notWatchedPrefix + err.Error()
		}
		return res
	}
	if hub {
		a.deps.Background(func() {
			if res := apply(); res.Error != "" {
				log.Printf("inbox.act: action %d: %s", id, res.Error)
			}
		})
		return api.ActResult{Status: statusApplying}
	}
	done := make(chan api.ActResult, 1)
	go func() { done <- apply() }()
	timer := time.NewTimer(ApproveWaitCap)
	defer timer.Stop()
	select {
	case res := <-done:
		return res
	case <-timer.C:
		return api.ActResult{Status: statusApplying}
	}
}

// notWatchedPrefix leads the error of an approved create_track whose watch
// did not start (AgentActionFeed.notWatchedPrefix).
const notWatchedPrefix = "Approved, but the track is not watched yet: "

// startWatchingIfTrack is AgentActionFeed.startWatchingIfTrack: an applied
// create_track's track is watched now (`tracks start`, the C3 ruling: the
// tool only creates the row), after the row's own commit and outside any
// transaction. Any other row, or one that did not apply, starts nothing.
func (a actor) startWatchingIfTrack(ctx context.Context, row *db.AgentAction) error {
	if a.deps.StartWatch == nil || row.Tool != "create_track" || row.Status != "applied" {
		return nil
	}
	trackID := resultTrackID(row.ResultJSON)
	if trackID <= 0 {
		return nil // no track id in the result: the Mac starts nothing either
	}
	return a.deps.StartWatch(ctx, trackID)
}

// resultTrackID is a create_track result's track_id (a number or a numeric
// string, as AgentActionDestination reads it); 0 when there is none.
func resultTrackID(resultJSON string) int64 {
	var result map[string]json.RawMessage
	if json.Unmarshal([]byte(resultJSON), &result) != nil {
		return 0
	}
	id, _ := strconv.ParseInt(strings.Trim(string(result["track_id"]), `"`), 10, 64)
	return id
}

// actionStatus is a row's ActResult.Status: applied, failed, else applying.
func actionStatus(row *db.AgentAction) string {
	switch row.Status {
	case "applied":
		return statusApplied
	case "failed":
		return statusFailed
	}
	return statusApplying
}

func (a actor) reject(reg *tools.Registry, id int64) (api.ActResult, error) {
	ok, err := reg.Reject(id)
	if err != nil || ok {
		return api.ActResult{}, err
	}
	row, err := a.row(id)
	if err != nil {
		return api.ActResult{}, err
	}
	if row.Status == "rejected" {
		return already, nil
	}
	return api.ActResult{}, a.refuse(api.CodeChanged, "")
}

// dismissCall is Dismiss on a session call whose outcome is unknown
// (DismissSessionCall); a row already dismissed is already.
func (a actor) dismissCall(reg *tools.Registry, id int64) (api.ActResult, error) {
	row, err := a.row(id)
	if err != nil {
		return api.ActResult{}, err
	}
	if row.DismissedAt != "" {
		return already, nil
	}
	err = reg.DismissSessionCall(id)
	switch {
	case errors.Is(err, tools.ErrNotFound):
		return api.ActResult{}, a.refuse(api.CodeNotFound, "")
	case errors.Is(err, tools.ErrBadTransition):
		return api.ActResult{}, a.refuse(api.CodeChanged, "")
	}
	return api.ActResult{}, err
}
