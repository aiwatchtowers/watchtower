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
	case api.ApprovalApprove, api.ApprovalRetry, api.ApprovalDismiss:
		// `actions approve|apply|dismiss` are AGENT-07 gestures.
		if err := a.ownerGesture(ctx); err != nil {
			return api.ActResult{}, err
		}
	default:
	}
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
	return a.runTool(ctx, reg, row, hub), nil
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
	row, res, run, err := RetryAction(a.c.DB, reg, id, a.now())
	if err != nil {
		return api.ActResult{}, a.refusal(err)
	}
	if !run {
		return res, nil
	}
	return a.runTool(ctx, reg, row, hub), nil
}

// refusal maps a RetryAction or DismissAction refusal onto inbox.act's
// sentence; any other error passes through.
func (a actor) refusal(err error) error {
	var r *ActionRefusal
	if errors.As(err, &r) {
		return a.refuse(r.Code, r.Reason)
	}
	return err
}

// ActionRefusal is RetryAction's and DismissAction's refusal: the inbox.act
// refusal code and its narrower reason ("" = the code's own).
type ActionRefusal struct {
	Code   api.RefusalCode
	Reason string
}

func (r *ActionRefusal) Error() string { return string(r.Code) + ": " + r.Reason }

// reasonSessionOnly refuses a Retry of a session-applied call.
const reasonSessionOnly = "it runs only in its chat on the Mac."

// RetryAction is the one retry rule of an approval row for the owner,
// shared by inbox.act's approval retry and the hub's chat_action_answer
// retry (mobile Inbox spec §12.9): a failed or approved row is ready to run
// (run true: the caller applies it, Registry.Apply claims it, so two retries
// never both run the tool); a stuck Inbox target row's executing claim is
// reclaimed first; executing (not stuck) or applied is already, with its
// state; an older row of a button whose newer proposal is open, a rejected
// row and a session-applied call are refused (*ActionRefusal). A missing
// row is refused not_found.
func RetryAction(d *db.DB, reg *tools.Registry, id int64, now time.Time) (*db.AgentAction, api.ActResult, bool, error) {
	row, err := d.GetAgentAction(id)
	if err != nil {
		return nil, api.ActResult{}, false, err
	}
	if row == nil {
		return nil, api.ActResult{}, false, &ActionRefusal{Code: api.CodeNotFound}
	}
	newer, err := d.NewerOpenButtonProposal(row)
	if err != nil {
		return nil, api.ActResult{}, false, err
	}
	if newer != 0 {
		return nil, api.ActResult{}, false, &ActionRefusal{Code: api.CodeChanged}
	}
	if t, known := reg.Get(row.Tool); known && t.AppliedBySession {
		return nil, api.ActResult{}, false, &ActionRefusal{Code: api.CodeUnsupported, Reason: reasonSessionOnly}
	}
	switch row.Status {
	case "approved", "failed":
	case "executing":
		if !stuck(row, now) {
			return row, api.ActResult{Already: true, Status: statusApplying}, false, nil
		}
		ok, err := d.TransitionAgentAction(id, []string{"executing"}, "failed", "", interruptedApply)
		if err != nil {
			return nil, api.ActResult{}, false, err
		}
		if !ok {
			return nil, api.ActResult{}, false, &ActionRefusal{Code: api.CodeChanged}
		}
	case "applied":
		return row, api.ActResult{Already: true, Status: statusApplied}, false, nil
	default:
		return nil, api.ActResult{}, false, &ActionRefusal{Code: api.CodeChanged}
	}
	return row, api.ActResult{}, true, nil
}

// stuck is an Inbox target button's row executing past targetStuckAfter
// since its decision: the state the card offers Try again for.
func stuck(row *db.AgentAction, now time.Time) bool {
	if row.ContextType != db.InboxButtonContextType {
		return false
	}
	decided, err := time.Parse(time.RFC3339Nano, row.DecidedAt)
	return err == nil && now.Sub(decided) >= targetStuckAfter
}

// runTool applies row id (Apply claims it, so two applies never both run
// it) outside any transaction. Over the hub it runs in Background and the
// call answers applying; over the socket the call waits up to
// ApproveWaitCap and answers the row's state, or applying when the tool
// is still running.
//
// An applied create_track's watch starts here only over the socket (the
// signed Desktop's press): from the hub the tool applies, and the answer's
// note says the watch starts from the Mac (ask #1349: turning automations on
// stays on the Mac).
func (a actor) runTool(ctx context.Context, reg *tools.Registry, row *db.AgentAction, hub bool) api.ActResult {
	id := row.ID
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
		if hub {
			return res
		}
		if err := a.startWatchingIfTrack(runCtx, row); err != nil {
			res.Error = notWatchedPrefix + err.Error()
		}
		return res
	}
	if hub {
		a.deps.Background(func() { logOutcome(id, apply(), "") })
		res := api.ActResult{Status: statusApplying}
		if row.Tool == "create_track" {
			res.Note = noteWatchOnMac
		}
		return res
	}
	done := make(chan api.ActResult, 1)
	go func() { done <- apply() }()
	timer := time.NewTimer(ApproveWaitCap)
	defer timer.Stop()
	select {
	case res := <-done:
		return res
	case <-timer.C:
		// The answer has gone: the outcome is logged when it comes. The row
		// itself carries applied or failed with its error to the next feed;
		// a watch that did not start leaves its track unwatched, which the
		// Mac's track card shows with Start Watching.
		go func() { logOutcome(id, <-done, " after the 120 s wait") }()
		return api.ActResult{Status: statusApplying}
	}
}

// logOutcome logs an approve's outcome that no answer carries: a failure or
// a watch that did not start (its class, not its args).
func logOutcome(id int64, res api.ActResult, when string) {
	if res.Error != "" || res.Status == statusFailed {
		log.Printf("inbox.act: action %d finished%s: %s: %s", id, when, res.Status, res.Error)
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
	res, err := DismissAction(a.c.DB, reg, id)
	if err != nil {
		return api.ActResult{}, a.refusal(err)
	}
	return res, nil
}

// DismissAction is the one dismiss rule of an approval row for the owner,
// shared by inbox.act's approval dismiss and the hub's chat_action_answer
// dismiss (mobile Inbox spec §12.9): only a session call whose outcome is
// unknown (Registry.DismissSessionCall); a row already dismissed answers
// already and writes nothing; any other row is refused changed, a missing
// one not_found (*ActionRefusal).
func DismissAction(d *db.DB, reg *tools.Registry, id int64) (api.ActResult, error) {
	row, err := d.GetAgentAction(id)
	if err != nil {
		return api.ActResult{}, err
	}
	if row == nil {
		return api.ActResult{}, &ActionRefusal{Code: api.CodeNotFound}
	}
	if row.DismissedAt != "" {
		return already, nil
	}
	err = reg.DismissSessionCall(id)
	switch {
	case errors.Is(err, tools.ErrNotFound):
		return api.ActResult{}, &ActionRefusal{Code: api.CodeNotFound}
	case errors.Is(err, tools.ErrBadTransition):
		return api.ActResult{}, &ActionRefusal{Code: api.CodeChanged}
	}
	return api.ActResult{}, err
}
