package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"watchtower/internal/db"
)

// applyTrackActionArgs is the whole input: the event names its own change
// (track_events.proposed_action), so nothing about the change is passed in.
type applyTrackActionArgs struct {
	EventID int `json:"event_id" jsonschema:"the track event whose proposed change to apply"`
}

// storedTrackActionArgs is what Normalize persists: the event plus the
// fixed reason every proposal row carries (admitProposal requires one).
type storedTrackActionArgs struct {
	EventID int    `json:"event_id"`
	Reason  string `json:"reason"`
}

// trackActionReason is the stored reason: a fact about the press, never text
// taken from the event (whose words came from synced content).
const trackActionReason = "The owner applied the change this track event proposes, from the Inbox."

// trackStatuses is the status set of the custom-track prompt grammar
// (prompts track.custom_scan): the only values an update_status may carry.
var trackStatuses = []string{"todo", "in_progress", "blocked", "done", "dismissed", "snoozed"}

// trackChange is a track event's proposed_action in the prompt grammar:
// update_status / update_progress / update_notes / add_sub_item. Its reason
// key is not read.
type trackChange struct {
	Type     string `json:"type"`
	Status   string `json:"status"`
	Progress *int   `json:"progress"`
	Note     string `json:"note"`
	Text     string `json:"text"`
}

// trackAction is one event's change, resolved against its linked target.
type trackAction struct {
	eventID  int
	targetID int
	change   trackChange
}

var errTrackActionAlreadyApplied = &ValidationError{Msg: "This change was already applied."}

// NewApplyTrackAction builds apply_track_action, the owner's Apply press on a
// custom track event's proposed target change (spec
// 2026-10-22-inbox-built-in-automations-design §6.2, gap 17). It lives on the
// inbox surface only — no MCP server, chat or tool loop mounts it — and is
// AlwaysAsk: `watchtower actions propose --approve` proposes and approves it
// in the owner's one press, and Apply's claim runs it once (AGENT-05). The
// event's own claim (pending → applied) is taken in the same transaction as
// the target write, so a second press never writes the change twice.
func NewApplyTrackAction() *Tool {
	return &Tool{
		Name: "apply_track_action",
		Description: "Owner only: apply the change a custom track's event proposes to the task the track is " +
			"linked to. Pressed in the Watchtower Inbox; never offered to a model.",
		InputSchema: mustSchema[applyTrackActionArgs]("apply_track_action"),
		Access:      AccessWrite,
		AlwaysAsk:   true,
		Surfaces:    []string{InboxSurface},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a applyTrackActionArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			e, err := readTrackEvent(d, a.EventID)
			if err != nil {
				return err
			}
			if err := trackEventStatusRefusal(e); err != nil {
				return err
			}
			_, err = resolveTrackAction(d, e)
			return err
		},
		Normalize: func(_ context.Context, _ *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a applyTrackActionArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return nil, fmt.Errorf("decoding apply_track_action args: %w", err)
			}
			return json.Marshal(storedTrackActionArgs{EventID: a.EventID, Reason: trackActionReason})
		},
		Execute: executeTrackAction,
	}
}

// executeTrackAction re-reads the event and its target, then in one
// transaction claims the event and makes the one target write. The claim, not
// the read, decides whether this press may write: a lost claim writes
// nothing and says why.
func executeTrackAction(_ context.Context, d *db.DB, call Call) (any, error) {
	var a storedTrackActionArgs
	if err := json.Unmarshal(call.Args, &a); err != nil {
		return nil, fmt.Errorf("decoding apply_track_action args: %w", err)
	}
	e, err := readTrackEvent(d, a.EventID)
	if err != nil {
		return nil, err
	}
	act, err := resolveTrackAction(d, e)
	if err != nil {
		return nil, err
	}
	var applied string
	claimed := false
	err = d.WithTx(func(tx *sql.Tx) error {
		ok, err := d.ClaimTrackEventActionTx(tx, act.eventID)
		if err != nil || !ok {
			return err
		}
		claimed = true
		applied, err = act.write(d, tx)
		if errors.Is(err, sql.ErrNoRows) {
			// The target went between the read and the write; the
			// rolled-back claim leaves the event pending.
			return errTrackTargetGone
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	if !claimed {
		return nil, lostClaimRefusal(d, act.eventID)
	}
	return map[string]any{"target_id": act.targetID, "applied": applied}, nil
}

// lostClaimRefusal says why an event's claim was lost: its status now, read
// after the rolled-back transaction.
func lostClaimRefusal(d *db.DB, eventID int) error {
	e, err := readTrackEvent(d, eventID)
	if err != nil {
		return err
	}
	if err := trackEventStatusRefusal(e); err != nil {
		return err
	}
	return errTrackActionAlreadyApplied
}

// write makes the change on the target inside tx and returns its summary.
func (a trackAction) write(d *db.DB, tx *sql.Tx) (string, error) {
	c := a.change
	switch c.Type {
	case "update_status":
		return "set status to " + c.Status, d.UpdateTargetStatusAsTx(tx, a.targetID, c.Status, db.ActorOwner)
	case "update_progress":
		return fmt.Sprintf("set progress to %d%%", *c.Progress), d.SetTargetProgressTx(tx, a.targetID, float64(*c.Progress)/100)
	case "update_notes":
		return "added a note", d.AppendTargetNoteTx(tx, a.targetID, strings.TrimSpace(c.Note),
			time.Now().UTC().Format(time.RFC3339))
	default: // add_sub_item: resolveTrackAction admits nothing else
		return "added a sub-item", d.AppendTargetSubItemTx(tx, a.targetID, strings.TrimSpace(c.Text))
	}
}

// errTrackTargetGone is the owner-facing refusal when the linked target is
// gone, at the read or inside the write's transaction.
var errTrackTargetGone = &ValidationError{Msg: "The task this track is linked to no longer exists."}

// readTrackEvent reads the event; a missing one is the owner-facing refusal.
func readTrackEvent(d *db.DB, id int) (*db.TrackEvent, error) {
	if id <= 0 {
		return nil, &ValidationError{Msg: "event_id is required"}
	}
	e, err := d.GetTrackEvent(id)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, &ValidationError{Msg: "This track event no longer exists."}
	}
	return e, err
}

// trackEventStatusRefusal refuses an event whose proposed change is not
// waiting: applied, dismissed, or never proposed.
func trackEventStatusRefusal(e *db.TrackEvent) error {
	switch {
	case e.ActionStatus == "applied":
		return errTrackActionAlreadyApplied
	case e.ActionStatus == "dismissed":
		return &ValidationError{Msg: "This change was dismissed."}
	case e.ActionStatus != "pending" || strings.TrimSpace(e.ProposedAction) == "":
		return &ValidationError{Msg: "This track event proposes no change."}
	}
	return nil
}

// resolveTrackAction checks the event's change against the prompt grammar and
// its track's link to a live target.
func resolveTrackAction(d *db.DB, e *db.TrackEvent) (trackAction, error) {
	if strings.TrimSpace(e.ProposedAction) == "" {
		return trackAction{}, &ValidationError{Msg: "This track event proposes no change."}
	}
	var c trackChange
	if err := json.Unmarshal([]byte(e.ProposedAction), &c); err != nil {
		return trackAction{}, &ValidationError{Msg: "This track event's proposed change can't be read."}
	}
	track, err := d.GetTrackByID(e.TrackID)
	if errors.Is(err, sql.ErrNoRows) {
		return trackAction{}, &ValidationError{Msg: "This track event no longer exists."}
	}
	if err != nil {
		return trackAction{}, err
	}
	if track.LinkedTargetID <= 0 {
		return trackAction{}, &ValidationError{Msg: "This track is not linked to a task."}
	}
	if _, err := d.GetTargetByID(track.LinkedTargetID); errors.Is(err, sql.ErrNoRows) {
		return trackAction{}, errTrackTargetGone
	} else if err != nil {
		return trackAction{}, err
	}
	if err := checkTrackChange(c); err != nil {
		return trackAction{}, err
	}
	return trackAction{eventID: e.ID, targetID: track.LinkedTargetID, change: c}, nil
}

// checkTrackChange admits only the prompt grammar's four kinds and values.
func checkTrackChange(c trackChange) error {
	switch c.Type {
	case "update_status":
		if !slices.Contains(trackStatuses, c.Status) {
			return &ValidationError{Msg: "The proposed status is not one a task can take here."}
		}
	case "update_progress":
		if c.Progress == nil || *c.Progress < 0 || *c.Progress > 100 {
			return &ValidationError{Msg: "The proposed progress must be between 0 and 100."}
		}
	case "update_notes":
		if strings.TrimSpace(c.Note) == "" {
			return &ValidationError{Msg: "The proposed note is empty."}
		}
	case "add_sub_item":
		if strings.TrimSpace(c.Text) == "" {
			return &ValidationError{Msg: "The proposed sub-item is empty."}
		}
	default:
		return &ValidationError{Msg: "This kind of change can't be applied from the Inbox."}
	}
	return nil
}
