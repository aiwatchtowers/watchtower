package builtin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// NeedsApprovalID is the built-in whose runs the approval trigger queues.
const NeedsApprovalID = "needs-approval"

// SweepRef is the ref phaseApprovalSweep fires with: no one approval
// changed, the artifacts drifted from the open approvals.
const SweepRef = "sweep"

// Fire queues a run of the needs-approval built-in for an approval that
// changed (ref = action:<id> | reminder:<id> | sweep) and then calls wake —
// AUTO-09: it only queues. The run is trigger 'event' with event_json
// {cycles, events: [{"type": "approval", "ref": ref}], count, truncated}; a
// run already queued takes the ref through MergeQueuedAutomationRunEvents
// (at most automations.MaxEventsPerRun events, then truncated), so a burst
// of changes is one run. The run's cycles list carries the refs, so a ref
// already in the queued run merges as a no-op. An action ref whose row can
// never be an approval (db.ActionCanBeApproval: a workbench audit row, an
// Inbox button's one-press row, a missing row) queues nothing. A built-in that is not
// indexed, not runnable (off, unconfirmed, a parse error) or stopped by the
// daemon (AUTO-08) queues nothing and returns nil. wake may be nil.
func Fire(d *db.DB, ref string, wake func()) error {
	if kind, id, err := db.ParseApprovalRef(ref); err == nil && kind == db.ApprovalKindAction {
		// A workbench's direct-apply audit row or an Inbox button's
		// one-press row is never an approval, whatever its status.
		if ok, err := d.ActionCanBeApproval(id); err != nil || !ok {
			return err
		}
	}
	a, err := d.GetBuiltinAutomation(NeedsApprovalID)
	if errors.Is(err, db.ErrAutomationNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if !a.Runnable() || a.DisabledReason != "" {
		return nil
	}
	event, err := json.Marshal(automations.Event{Type: automations.ApprovalEvent, Fields: map[string]any{"ref": ref}})
	if err != nil {
		return err
	}
	events := []json.RawMessage{event}
	payload, err := json.Marshal(db.AutomationEventPayload{Cycles: []string{ref}, Events: events, Count: 1})
	if err != nil {
		return fmt.Errorf("encoding the approval event: %w", err)
	}
	req := db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerEvent, EventJSON: string(payload), Now: time.Now()}
	for range 2 {
		runID, coalesced, err := d.EnqueueAutomationRun(req)
		if err != nil {
			return err
		}
		merged := !coalesced
		if coalesced {
			if merged, err = d.MergeQueuedAutomationRunEvents(runID, ref, events, 1, automations.MaxEventsPerRun); err != nil {
				return err
			}
		}
		if merged {
			if wake != nil {
				wake()
			}
			return nil
		}
		// The queued run was claimed between the enqueue and the merge:
		// enqueue once more, a new run then carries the ref.
	}
	return errors.New("the queued run was claimed before each merge")
}

// ApprovalHook is the function a process sets with db.SetApprovalHook: Fire
// for the ref, its error logged through logf as "approval hook: …" with the
// ref only (FILES-01) and never returned — the approval's change stands, and
// the daemon's sweep redraws.
func ApprovalHook(d *db.DB, wake func(), logf func(format string, args ...any)) func(ref string) {
	return func(ref string) {
		if err := Fire(d, ref, wake); err != nil {
			logf("approval hook: %s: %v", ref, err)
		}
	}
}

// SweepApprovals compares the open approvals with the needs-approval
// built-in's artifacts and fires once (SweepRef) when they disagree: an open
// approval without an artifact written after its last change (a reminder
// that came due among them) or an artifact of a closed or deleted approval.
// It only reads; a built-in that is not indexed or not runnable, or that has
// a run queued, running or waiting (that run redraws), is not compared.
// fired reports whether it fired.
func SweepApprovals(ctx context.Context, d *db.DB, now time.Time, wake func()) (fired bool, err error) {
	a, err := d.GetBuiltinAutomation(NeedsApprovalID)
	if errors.Is(err, db.ErrAutomationNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !a.Runnable() || a.DisabledReason != "" {
		return false, nil
	}
	if busy, err := d.HasUnfinishedAutomationRun(a.ID); err != nil || busy {
		return false, err
	}
	drift, err := d.ApprovalDriftOf(ctx, a.ID, now, automations.MaxOutputsPerRun)
	if err != nil || !drift.Any() {
		return false, err
	}
	if err := Fire(d, SweepRef, wake); err != nil {
		return false, err
	}
	return true, nil
}
