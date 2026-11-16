package inboxfeed

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/blocks"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/db"
	"watchtower/internal/slack"
	"watchtower/internal/tools"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// ApproveWaitCap is how long an approve or retry over the socket waits for
// its tool before it answers status "applying" (spec §2.1).
const ApproveWaitCap = 120 * time.Second

// ActDeps are what inbox.act needs at call time. A missing one answers
// unsupported for the verbs that need it, before anything is written.
type ActDeps struct {
	// Registry decides and applies approvals and records the proposals of
	// a target press, a track's make_task and a Reply.
	Registry *tools.Registry
	// RunNow queues a run of automation id now (the automation_run kind's
	// function) and returns the run; a *CannotRunError is a refusal.
	RunNow func(ctx context.Context, automationID int64) (int64, error)
	// Wake asks the automation executor to poll now (a reply press, the
	// reminder approval hook).
	Wake func()
	// Background runs fn off the call: over the hub an approve answers
	// after the decision and its tool runs here.
	Background func(fn func())
	// Clock is the time the stuck rule reads; nil means the call's Now.
	Clock func() time.Time
}

// CannotRunError is RunNow's refusal of an automation that cannot run now
// (off, unconfirmed, no Run Now): nothing was queued.
type CannotRunError struct{ Reason string }

func (e *CannotRunError) Error() string { return e.Reason }

// manualResolveReason is the resolved_reason of the owner's Resolve, as
// `watchtower inbox resolve` writes it.
const manualResolveReason = "Manually resolved"

// RegisterAct registers inbox.act, the Inbox's one write command.
func RegisterAct(r *tower.Registry, deps ActDeps) {
	tower.Register(r, "inbox.act", func(ctx context.Context, c *tower.Ctx, req api.ActRequest) (api.ActResult, error) {
		a := actor{deps: deps, c: c, req: req}
		res, err := a.act(ctx)
		return res, faultOf(req, err)
	}, tower.Spec{ChangeTables: ChangeTables, IdempotentFor: ActIdempotent, GrantFor: ActGrant})
}

// ActIdempotent is inbox.act's Spec.IdempotentFor: every verb is a guarded
// write but approve, retry, run_now and press. A press is a Reply's or a
// target's, which the params cannot tell apart; the Reply's queues a run, so
// every press is non-idempotent (a target press is guarded by its one open
// proposal either way).
func ActIdempotent(params json.RawMessage) (bool, error) {
	req, err := decodeAct(params)
	if err != nil {
		return false, err
	}
	switch req.Verb {
	case api.ActRunNow, api.ActPress:
		return false, nil
	case api.ActApproval:
		v := req.Params.ApprovalVerb
		return v != api.ApprovalApprove && v != api.ApprovalRetry, nil
	default:
		return true, nil
	}
}

// ActGrant is inbox.act's Spec.GrantFor (ask #1349): permissions for approve
// and retry, typing for reply_propose and a press with text, none otherwise.
func ActGrant(params json.RawMessage) (string, error) {
	req, err := decodeAct(params)
	if err != nil {
		return "", err
	}
	switch req.Verb {
	case api.ActApproval:
		if v := req.Params.ApprovalVerb; v == api.ApprovalApprove || v == api.ApprovalRetry {
			return "permissions", nil
		}
	case api.ActReplyPropose:
		return "typing", nil
	case api.ActPress:
		if strings.TrimSpace(req.Params.Text) != "" {
			return "typing", nil
		}
	default:
	}
	return "", nil
}

func decodeAct(params json.RawMessage) (api.ActRequest, error) {
	var req api.ActRequest
	if len(params) > 0 {
		if err := json.Unmarshal(params, &req); err != nil {
			return req, fmt.Errorf("inboxfeed: read the inbox.act params: %w", err)
		}
	}
	return req, nil
}

// actor runs one inbox.act call.
type actor struct {
	deps ActDeps
	c    *tower.Ctx
	req  api.ActRequest
}

func (a actor) refuse(code api.RefusalCode, reason string) error { return refuse(a.req, code, reason) }

func (a actor) unsupported() error { return a.refuse(api.CodeUnsupported, "") }

func (a actor) now() time.Time {
	if a.deps.Clock != nil {
		return a.deps.Clock()
	}
	return a.c.Now()
}

// already is a guarded no-op's answer.
var already = api.ActResult{Already: true}

// act dispatches the verb table (spec §4.3); a target/verb pair outside it
// is unsupported.
func (a actor) act(ctx context.Context) (api.ActResult, error) {
	kind, num, date, err := ParseCardID(a.req.Target)
	if err != nil {
		return api.ActResult{}, a.unsupported()
	}
	p := a.req.Params
	switch a.req.Verb {
	case api.ActRead:
		return a.read(ctx, kind, num, date)
	case api.ActDone, api.ActDismiss:
		if kind != KindOutput {
			return api.ActResult{}, a.unsupported()
		}
		return a.closeOutput(ctx, num)
	case api.ActPress:
		if kind != KindOutput || p.Index == nil {
			return api.ActResult{}, a.unsupported()
		}
		return a.press(ctx, num, *p.Index)
	case api.ActRunNow:
		if kind != KindOutput {
			return api.ActResult{}, a.unsupported()
		}
		return a.runNow(ctx, num)
	case api.ActRef:
		return a.ref(ctx)
	case api.ActReplyPropose:
		return a.replyPropose(ctx, kind, num)
	case api.ActApproval:
		if kind != KindAction {
			return api.ActResult{}, a.unsupported()
		}
		return a.approval(ctx, num)
	}
	return api.ActResult{}, a.unsupported()
}

// write runs fn in the call's one write transaction (tower.Ctx.Write).
func (a actor) write(ctx context.Context, fn func(tx *sql.Tx) (api.ActResult, error)) (api.ActResult, error) {
	out, err := a.c.Write(ctx, func(tx *sql.Tx) (any, error) { return fn(tx) })
	if err != nil {
		return api.ActResult{}, err
	}
	return out.(api.ActResult), nil
}

// --- read ---

func (a actor) read(ctx context.Context, kind string, num int64, date string) (api.ActResult, error) {
	if a.req.Params.RefKind == api.RefInboxItem {
		return a.readInboxItem(ctx, a.req.Params.RefID)
	}
	switch kind {
	case KindOutput:
		return a.stampOutput(ctx, num, db.MarkOutputReadTx)
	case KindBrief:
		return a.write(ctx, func(tx *sql.Tx) (api.ActResult, error) {
			ids, err := intColumn(tx, `SELECT id FROM briefings WHERE date = ? AND read_at IS NULL ORDER BY id`, date)
			if err != nil || len(ids) == 0 {
				// Read already, or today's placeholder: nothing to mark.
				return already, err
			}
			return api.ActResult{}, db.MarkBriefingReadTx(tx, ids)
		})
	case KindReminder, KindNotice:
		// Opening a reminder or a built-in notice writes nothing (the Mac's
		// openingWrite).
		return already, nil
	}
	return api.ActResult{}, a.unsupported()
}

func (a actor) readInboxItem(ctx context.Context, id int64) (api.ActResult, error) {
	return a.write(ctx, func(tx *sql.Tx) (api.ActResult, error) {
		var readAt sql.NullString
		err := tx.QueryRow(`SELECT read_at FROM inbox_items WHERE id = ?`, id).Scan(&readAt)
		if errors.Is(err, sql.ErrNoRows) {
			return api.ActResult{}, a.refuse(api.CodeNotFound, "")
		}
		if err != nil {
			return api.ActResult{}, err
		}
		if readAt.String != "" {
			return already, nil
		}
		return api.ActResult{}, db.MarkInboxItemReadTx(tx, int(id))
	})
}

// --- an output's read, done and dismiss ---

type outputStamp func(tx *sql.Tx, id int64, contentHash string, now time.Time) (bool, error)

func (a actor) closeOutput(ctx context.Context, id int64) (api.ActResult, error) {
	if a.req.Verb == api.ActDone {
		return a.stampOutput(ctx, id, db.MarkOutputDoneTx)
	}
	return a.stampOutput(ctx, id, db.DismissOutputTx)
}

// stampOutput writes one hash-guarded mark and, when it changed nothing,
// says why: not there, changed since drawn, already marked, or closed.
func (a actor) stampOutput(ctx context.Context, id int64, stamp outputStamp) (api.ActResult, error) {
	return a.write(ctx, func(tx *sql.Tx) (api.ActResult, error) {
		hash := a.req.Params.ContentHash
		ok, err := stamp(tx, id, hash, a.c.Now())
		if err != nil || ok {
			return api.ActResult{}, err
		}
		var kind, rowHash string
		var read, done, dismissed bool
		err = tx.QueryRow(`SELECT kind, content_hash, read_at IS NOT NULL, done_at IS NOT NULL, dismissed_at IS NOT NULL
			FROM automation_outputs WHERE id = ?`, id).Scan(&kind, &rowHash, &read, &done, &dismissed)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && kind != "inbox") {
			return api.ActResult{}, a.refuse(api.CodeNotFound, "")
		}
		if err != nil {
			return api.ActResult{}, err
		}
		if rowHash != hash {
			return api.ActResult{}, a.refuse(api.CodeChanged, "")
		}
		switch a.req.Verb {
		case api.ActRead:
			// Read, or closed: a closed card has nothing left to read.
			return already, nil
		case api.ActDone:
			if done {
				return already, nil
			}
		case api.ActDismiss:
			if dismissed {
				return already, nil
			}
		default:
		}
		return api.ActResult{}, a.refuse(api.CodeChanged, reasonClosed)
	})
}

// --- press ---

// press is a card button's press: a Reply queues the automation's reply run
// (PressInboxOutputAction), a target proposes its create_target row.
func (a actor) press(ctx context.Context, outputID int64, index int) (api.ActResult, error) {
	o, err := a.c.DB.GetAutomationOutput(outputID)
	if errors.Is(err, db.ErrOutputNotFound) || (err == nil && o.Kind != "inbox") {
		return api.ActResult{}, a.refuse(api.CodeNotFound, "")
	}
	if err != nil {
		return api.ActResult{}, err
	}
	if a.req.Params.ContentHash != o.ContentHash {
		return api.ActResult{}, a.refuse(api.CodeChanged, "")
	}
	actions, err := db.FlattenStoredInboxActions(o.Actions, o.BlocksJSON)
	if err != nil {
		return api.ActResult{}, err
	}
	if index < 0 || index >= len(actions) {
		return api.ActResult{}, a.refuse(api.CodeChanged, "")
	}
	switch act := actions[index]; act.Kind {
	case db.InboxActionReply:
		return a.pressReply(ctx, o, index)
	case "target":
		return a.pressTarget(ctx, o, index, act)
	}
	return api.ActResult{}, a.unsupported()
}

func (a actor) pressReply(ctx context.Context, o *db.AutomationOutput, index int) (api.ActResult, error) {
	if strings.TrimSpace(a.req.Params.Text) != "" {
		// A reply run carries no typed text: refused, never dropped silently.
		return api.ActResult{}, a.unsupported()
	}
	if o.PressedAt != nil {
		return api.ActResult{Already: true, RunID: o.PressedRunID}, nil
	}
	auto, err := a.c.DB.GetAutomation(o.AutomationID)
	if err != nil {
		return api.ActResult{}, err
	}
	if err := automations.RequireInboxReply(a.c.DB, auto); err != nil {
		return api.ActResult{}, a.refuse(api.CodeUnsupported, "this card's automation no longer takes its buttons.")
	}
	res, err := a.write(ctx, func(tx *sql.Tx) (api.ActResult, error) {
		runID, err := db.PressInboxOutputActionTx(tx, o.ID, index, a.req.Params.ContentHash, a.c.Now())
		var pressed *db.AlreadyPressedError
		switch {
		case errors.As(err, &pressed):
			return api.ActResult{Already: true, RunID: pressed.RunID}, nil
		case errors.Is(err, db.ErrOutputNotFound):
			return api.ActResult{}, a.refuse(api.CodeNotFound, "")
		case errors.Is(err, db.ErrOutputChanged):
			return api.ActResult{}, a.refuse(api.CodeChanged, "")
		case errors.Is(err, db.ErrOutputClosed):
			return api.ActResult{}, a.refuse(api.CodeChanged, reasonClosed)
		case errors.Is(err, db.ErrNotAReplyAction):
			return api.ActResult{}, a.refuse(api.CodeChanged, "")
		case errors.Is(err, db.ErrOutputAutomationNotRunnable):
			return api.ActResult{}, a.refuse(api.CodeUnsupported, "this card's automation can't run now.")
		case err != nil:
			return api.ActResult{}, err
		}
		return api.ActResult{RunID: runID}, nil
	})
	if err == nil && !res.Already && a.deps.Wake != nil {
		a.deps.Wake()
	}
	return res, err
}

// pressTarget is InboxTargetPress: one pending create_target proposal in
// the button's context, which the owner approves in its approval card.
func (a actor) pressTarget(ctx context.Context, o *db.AutomationOutput, index int, act db.InboxAction) (api.ActResult, error) {
	if a.deps.Registry == nil {
		return api.ActResult{}, a.refuse(api.CodeUnsupported, reasonNoService)
	}
	if act.Target == nil || act.Target.Title == "" {
		return api.ActResult{}, a.unsupported()
	}
	auto, err := a.c.DB.GetAutomation(o.AutomationID)
	if err != nil {
		return api.ActResult{}, err
	}
	cardTitle := o.Title
	if cardTitle == "" {
		cardTitle = "Automation output"
	}
	args := map[string]any{
		"text":   act.Target.Title,
		"reason": "From the Inbox card “" + cardTitle + "” of " + auto.Name,
	}
	if act.Target.Intent != "" {
		args["intent"] = act.Target.Intent
	}
	if act.Target.Parent != 0 {
		args["parent_id"] = act.Target.Parent
	}
	raw, err := json.Marshal(args)
	if err != nil {
		return api.ActResult{}, err
	}
	ctxID := fmt.Sprintf("%d:%d:%s", o.ID, index, blocks.ActionHash(act))
	_, err = a.deps.Registry.Propose(ctx, "create_target", raw, tools.Binding{
		Surface: tools.InboxSurface, ContextType: db.InboxButtonContextType, ContextID: ctxID,
	})
	var open *db.ErrButtonHasOpenProposal
	var exists *db.ErrButtonTaskExists
	if errors.As(err, &open) || errors.As(err, &exists) {
		return already, nil
	}
	var v *tools.ValidationError
	if errors.As(err, &v) {
		return api.ActResult{}, a.refuse(api.CodeChanged, lowerFirst(v.Msg))
	}
	return api.ActResult{}, err
}

// --- run_now ---

func (a actor) runNow(ctx context.Context, outputID int64) (api.ActResult, error) {
	if a.deps.RunNow == nil {
		return api.ActResult{}, a.refuse(api.CodeUnsupported, reasonNoService)
	}
	var automationID int64
	err := a.c.DB.QueryRowContext(ctx, `SELECT automation_id FROM automation_outputs WHERE id = ? AND kind = 'inbox'`,
		outputID).Scan(&automationID)
	if errors.Is(err, sql.ErrNoRows) {
		return api.ActResult{}, a.refuse(api.CodeNotFound, "")
	}
	if err != nil {
		return api.ActResult{}, err
	}
	runID, err := a.deps.RunNow(ctx, automationID)
	var cannot *CannotRunError
	if errors.As(err, &cannot) {
		return api.ActResult{}, a.refuse(api.CodeUnsupported, sentenceCase(cannot.Reason))
	}
	if err != nil {
		return api.ActResult{}, err
	}
	return api.ActResult{RunID: runID}, nil
}

// --- ref ---

func (a actor) ref(ctx context.Context) (api.ActResult, error) {
	p := a.req.Params
	if p.RefID <= 0 {
		return api.ActResult{}, a.unsupported()
	}
	switch p.RefKind {
	case api.RefInboxItem:
		return a.refInboxItem(ctx, p.RefID)
	case api.RefTrack:
		return a.refTrack(ctx, p.RefID)
	case api.RefIdea:
		return a.refIdea(ctx, p.RefID)
	case api.RefReminder:
		return a.refReminder(ctx, p.RefID)
	case api.RefPlanItem:
		return a.refPlanItem(ctx, p.RefID)
	default:
		return api.ActResult{}, a.unsupported()
	}
}

func (a actor) refInboxItem(ctx context.Context, id64 int64) (api.ActResult, error) {
	id, verb, until := int(id64), a.req.Params.RefVerb, a.req.Params.Until
	if verb != api.RefResolve && verb != api.RefDismiss && verb != api.RefSnooze {
		return api.ActResult{}, a.unsupported()
	}
	if verb == api.RefSnooze && until == "" {
		return api.ActResult{}, a.unsupported()
	}
	return a.write(ctx, func(tx *sql.Tx) (api.ActResult, error) {
		var status, snoozeUntil string
		err := tx.QueryRow(`SELECT status, snooze_until FROM inbox_items WHERE id = ?`, id).Scan(&status, &snoozeUntil)
		if errors.Is(err, sql.ErrNoRows) {
			return api.ActResult{}, a.refuse(api.CodeNotFound, "")
		}
		if err != nil {
			return api.ActResult{}, err
		}
		closed := status == "resolved" || status == "dismissed"
		switch verb {
		case api.RefResolve:
			if status == "resolved" {
				return already, nil
			}
			if closed {
				return api.ActResult{}, a.refuse(api.CodeChanged, reasonClosed)
			}
			return api.ActResult{}, db.ResolveInboxItemTx(tx, id, manualResolveReason)
		case api.RefDismiss:
			if status == "dismissed" {
				return already, nil
			}
			if closed {
				return api.ActResult{}, a.refuse(api.CodeChanged, reasonClosed)
			}
			return api.ActResult{}, db.DismissInboxItemTx(tx, id)
		default: // snooze
			if closed {
				return api.ActResult{}, a.refuse(api.CodeChanged, reasonClosed)
			}
			if status == "snoozed" && snoozeUntil == until {
				return already, nil
			}
			return api.ActResult{}, db.SnoozeInboxItemTx(tx, id, until)
		}
	})
}

func (a actor) refTrack(ctx context.Context, id64 int64) (api.ActResult, error) {
	id, verb := int(id64), a.req.Params.RefVerb
	if verb == api.RefMakeTask {
		return a.makeTask(ctx, id64)
	}
	if verb != api.RefDone && verb != api.RefStop && verb != api.RefRestore {
		return api.ActResult{}, a.unsupported()
	}
	return a.write(ctx, func(tx *sql.Tx) (api.ActResult, error) {
		var dismissedAt, origin string
		var read, hasUpdates, unreadEvents bool
		err := tx.QueryRow(`SELECT dismissed_at, origin, COALESCE(read_at, '') != '', has_updates != 0,
			EXISTS(SELECT 1 FROM track_events e WHERE e.track_id = tracks.id AND (e.read_at IS NULL OR e.read_at = ''))
			FROM tracks WHERE id = ?`, id).Scan(&dismissedAt, &origin, &read, &hasUpdates, &unreadEvents)
		if errors.Is(err, sql.ErrNoRows) {
			return api.ActResult{}, a.refuse(api.CodeNotFound, "")
		}
		if err != nil {
			return api.ActResult{}, err
		}
		switch verb {
		case api.RefDone:
			if read && !hasUpdates && !unreadEvents {
				return already, nil
			}
			return api.ActResult{}, db.MarkTrackDoneTx(tx, id)
		case api.RefStop:
			if origin == "custom" {
				// A custom track's Stop also turns its collection off
				// (CustomTrackControlling): on the Mac.
				return api.ActResult{}, a.refuse(api.CodeUnsupported, "a custom track is stopped on the Mac.")
			}
			if dismissedAt != "" {
				return already, nil
			}
			return api.ActResult{}, db.StopTrackTx(tx, []int{id})
		default: // restore
			if origin == "custom" {
				return api.ActResult{}, a.refuse(api.CodeUnsupported, "a custom track is restored on the Mac.")
			}
			if dismissedAt == "" {
				return already, nil
			}
			return api.ActResult{}, db.RestoreTrackTx(tx, id)
		}
	})
}

// makeTask is TrackActionPress: apply_track_action proposed on the inbox
// surface and approved and applied in the same press. ref_id names the track
// event whose proposed change it applies.
func (a actor) makeTask(ctx context.Context, eventID int64) (api.ActResult, error) {
	reg := a.deps.Registry
	if reg == nil {
		return api.ActResult{}, a.refuse(api.CodeUnsupported, reasonNoService)
	}
	ev := strconv.FormatInt(eventID, 10)
	rc, err := reg.Propose(ctx, "apply_track_action", json.RawMessage(`{"event_id":`+ev+`}`), tools.Binding{
		Surface: tools.InboxSurface, ContextType: "track_event", ContextID: ev,
	})
	if err != nil {
		return api.ActResult{}, a.toolRefusal(err)
	}
	if _, err := reg.ApproveSeen(ctx, rc.ActionID, nil, ""); err != nil {
		return api.ActResult{}, a.toolRefusal(err)
	}
	row, err := reg.Apply(ctx, rc.ActionID)
	if err != nil {
		return api.ActResult{}, a.toolRefusal(err)
	}
	return api.ActResult{Status: actionStatus(row), Error: row.Error}, nil
}

// toolRefusal maps a registry refusal: an already applied change is
// already, a gone event not_found, any other validation refusal changed
// with its own words.
func (a actor) toolRefusal(err error) error {
	var v *tools.ValidationError
	switch {
	case errors.As(err, &v):
		return a.refuse(api.CodeChanged, lowerFirst(v.Msg))
	case errors.Is(err, tools.ErrNotFound):
		return a.refuse(api.CodeNotFound, "")
	}
	return err
}

func (a actor) refIdea(ctx context.Context, id64 int64) (api.ActResult, error) {
	id, verb, until := int(id64), a.req.Params.RefVerb, a.req.Params.Until
	status := map[api.RefVerb]string{api.RefApprove: "active", api.RefReject: "rejected", api.RefNotNow: "not_now"}[verb]
	if status == "" {
		return api.ActResult{}, a.unsupported()
	}
	return a.write(ctx, func(tx *sql.Tx) (api.ActResult, error) {
		var cur, snooze string
		err := tx.QueryRow(`SELECT status, snooze_until FROM ideas WHERE id = ?`, id).Scan(&cur, &snooze)
		if errors.Is(err, sql.ErrNoRows) {
			return api.ActResult{}, a.refuse(api.CodeNotFound, "")
		}
		if err != nil {
			return api.ActResult{}, err
		}
		if cur == "merged" || cur == "superseded" {
			return api.ActResult{}, a.refuse(api.CodeChanged, reasonIdeaChanged)
		}
		if cur == status && (verb != api.RefNotNow || snooze == until) {
			return already, nil
		}
		if verb == api.RefNotNow {
			return api.ActResult{}, db.SnoozeIdeaTx(tx, id, &until)
		}
		return api.ActResult{}, db.SetIdeaVerdictTx(tx, id, status)
	})
}

// refReminder is a reminder's Done or Snooze through db.MarkReminderDone
// and db.SnoozeReminder, each one short write of its own: their approval
// hook runs after that commit (the Swift ReminderApprovalHook), so the
// reminder writes have no Tx form. A handle without a hook (no daemon) runs
// builtin.Fire itself. Done is guarded by its own UPDATE; a Snooze to the
// time already set is already.
func (a actor) refReminder(_ context.Context, id int64) (api.ActResult, error) {
	verb, until := a.req.Params.RefVerb, a.req.Params.Until
	if (verb != api.RefDone && verb != api.RefSnooze) || (verb == api.RefSnooze && until == "") {
		return api.ActResult{}, a.unsupported()
	}
	var status, remindAt string
	err := a.c.DB.QueryRow(`SELECT status, remind_at FROM reminders WHERE id = ?`, id).Scan(&status, &remindAt)
	if errors.Is(err, sql.ErrNoRows) {
		return api.ActResult{}, a.refuse(api.CodeNotFound, "")
	}
	if err != nil {
		return api.ActResult{}, err
	}
	var changed bool
	if verb == api.RefDone {
		changed, err = a.c.DB.MarkReminderDone(id)
	} else {
		if status == "pending" && remindAt == until {
			return already, nil
		}
		changed, err = a.c.DB.SnoozeReminder(id, until)
	}
	if err != nil {
		return api.ActResult{}, err
	}
	if !changed {
		// Done by another writer meanwhile, or gone.
		if verb == api.RefDone {
			return already, nil
		}
		return api.ActResult{}, a.refuse(api.CodeNotFound, "")
	}
	if !a.c.DB.HasApprovalHook() {
		if ferr := builtin.Fire(a.c.DB, db.ReminderRef(id), a.deps.Wake); ferr != nil {
			log.Printf("inbox.act: approval hook for reminder %d: %v", id, ferr)
		}
	}
	return api.ActResult{}, nil
}

func (a actor) refPlanItem(ctx context.Context, id int64) (api.ActResult, error) {
	status := map[api.RefVerb]string{api.RefCheck: "done", api.RefUncheck: "pending"}[a.req.Params.RefVerb]
	if status == "" {
		return api.ActResult{}, a.unsupported()
	}
	return a.write(ctx, func(tx *sql.Tx) (api.ActResult, error) {
		var cur, sourceType string
		var sourceID sql.NullString
		err := tx.QueryRow(`SELECT status, source_type, source_id FROM day_plan_items WHERE id = ?`, id).
			Scan(&cur, &sourceType, &sourceID)
		if errors.Is(err, sql.ErrNoRows) {
			return api.ActResult{}, a.refuse(api.CodeNotFound, "")
		}
		if err != nil {
			return api.ActResult{}, err
		}
		if cur == status {
			return already, nil
		}
		// DayPlanViewModel.setItemStatus: a task item cascades to its task;
		// a task deleted meanwhile leaves the item marked alone.
		cascade := false
		if sourceType == "task" && sourceID.Valid {
			if n, perr := strconv.ParseInt(sourceID.String, 10, 64); perr == nil {
				var one int
				err := tx.QueryRow(`SELECT 1 FROM targets WHERE id = ?`, n).Scan(&one)
				if err != nil && !errors.Is(err, sql.ErrNoRows) {
					return api.ActResult{}, err
				}
				cascade = err == nil
			}
		}
		return api.ActResult{}, db.SetPlanItemStatusTx(tx, id, status, cascade)
	})
}

// --- reply_propose ---

// replyPropose is a Reply from an inbox item's row (InboxReplyPolicy): one
// pending proposal of the item's reply tool, approved in Needs approval.
func (a actor) replyPropose(ctx context.Context, kind string, num int64) (api.ActResult, error) {
	p := a.req.Params
	text := strings.TrimSpace(p.Text)
	if p.RefKind != api.RefInboxItem || p.RefID <= 0 || text == "" {
		return api.ActResult{}, a.unsupported()
	}
	if a.deps.Registry == nil {
		return api.ActResult{}, a.refuse(api.CodeUnsupported, reasonNoService)
	}
	var trigger, permalink, channelID string
	err := a.c.DB.QueryRowContext(ctx, `SELECT trigger_type, permalink, channel_id FROM inbox_items WHERE id = ?`,
		p.RefID).Scan(&trigger, &permalink, &channelID)
	if errors.Is(err, sql.ErrNoRows) {
		return api.ActResult{}, a.refuse(api.CodeNotFound, "")
	}
	if err != nil {
		return api.ActResult{}, err
	}
	tool := replyTool(trigger, permalink, channelID)
	if tool == "" {
		return api.ActResult{}, a.unsupported()
	}
	host, err := a.replyHost(kind, num)
	if err != nil {
		return api.ActResult{}, err
	}
	args := map[string]any{"reason": "Reply from " + host}
	if tool == "send_slack_message" {
		args["channel"], args["text"] = permalink, text
		if account, _, ok := slack.SplitAccountID(channelID); ok {
			args["account_id"] = account
		}
	} else {
		args["key"], args["body"] = channelID, text
	}
	raw, err := json.Marshal(args)
	if err != nil {
		return api.ActResult{}, err
	}
	_, err = a.deps.Registry.Propose(ctx, tool, raw, tools.Binding{
		Surface: tools.InboxSurface, ContextType: db.InboxItemContextType, ContextID: strconv.FormatInt(p.RefID, 10),
	})
	var waiting *db.ErrReplyAlreadyWaiting
	if errors.As(err, &waiting) {
		return api.ActResult{}, a.refuse(api.CodeReplyWaiting, "")
	}
	var v *tools.ValidationError
	if errors.As(err, &v) {
		return api.ActResult{}, a.refuse(api.CodeChanged, lowerFirst(v.Msg))
	}
	return api.ActResult{}, err
}

// replyHost is what the row is on (InboxRefHooks.replyHost): an artifact's
// title, else the Messages entry.
func (a actor) replyHost(kind string, num int64) (string, error) {
	if kind != KindOutput {
		return "Messages", nil
	}
	var title string
	err := a.c.DB.QueryRow(`SELECT title FROM automation_outputs WHERE id = ?`, num).Scan(&title)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if title == "" {
		return "Automation output", nil
	}
	return title, nil
}

// --- helpers ---

func intColumn(tx *sql.Tx, query string, args ...any) ([]int, error) {
	rows, err := tx.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// lowerFirst makes a sentence a reason: its first letter lower case.
func lowerFirst(s string) string {
	if s == "" {
		return reasonChanged
	}
	return strings.ToLower(s[:1]) + s[1:]
}

// sentenceCase ends a reason with a full stop.
func sentenceCase(s string) string {
	s = lowerFirst(strings.TrimSpace(s))
	if !strings.HasSuffix(s, ".") {
		s += "."
	}
	return s
}
