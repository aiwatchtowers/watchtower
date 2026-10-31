package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
)

// AutomationRunHandler's messages, verbatim.
const (
	automationNotAllowedMessage = "This phone is not allowed to run automations. " +
		"On the Mac: Watchtower → Settings → Mobile → allow typing, then starting sessions."
	automationTimeoutMessage = "The Mac did not finish this in time — check the automation on the Mac"
)

// automationRun is `automation_run` (ask #692; entity the automation id,
// params {workbench_id, confirmed}): runs a workbench automation now, as
// `automations run <id>` does, under the start-sessions grant. The row is read
// fresh: a recipe that is gone, not on this workbench or not runnable is
// refused with the reason; one already running is applied with that run. A
// button recipe with confirm: true runs only with confirmed (the owner pressed
// Run in the phone's confirmation, AUTO-06). applied carries {run_id,
// coalesced}.
func (h *Handlers) automationRun(ctx context.Context, r actions.Request) actions.Outcome {
	return h.withTimeout(ctx, "automation_run", automationTimeoutMessage, func(context.Context) actions.Outcome {
		return h.applyAutomationRun(r)
	})
}

func (h *Handlers) applyAutomationRun(r actions.Request) actions.Outcome {
	automationID, okID := entityID(r)
	workbenchID, okWB := intParam(r, "workbench_id")
	if !okID || !okWB {
		return failed(reasonInvalidParams, "automation_run needs an automation id and a workbench_id")
	}
	confirmed := string(r.Action.Params["confirmed"]) == "true"
	device, linked, err := h.d.Store.Device(r.Device.String())
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	// HubSyncState.mayStartSessions: the owner's grant, typing and the
	// phone's own toggle.
	if !linked || !device.StartSessionsGranted || !device.TypingAllowed || !device.StartSessionsAllowed {
		return failed(reasonDeviceNotAllowed, automationNotAllowedMessage)
	}
	a, err := h.d.DB.GetAutomation(automationID)
	if errors.Is(err, db.ErrAutomationNotFound) || (err == nil && a.RemovedAt != nil) {
		return failed(reasonNotFound, "This automation no longer exists on the Mac")
	}
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if a.Scope != "workbench" || a.ProjectID != workbenchID {
		return failed(reasonNotOnBoard, "That automation is not on this workbench")
	}
	// QuickRunCatalog.state: a parse error first, then an active run, then
	// runnable, a confirmed but switched-off recipe, else unconfirmed.
	if a.ParseError != "" {
		return failed(reasonConflict, "This automation can't be read on the Mac")
	}
	active, err := h.activeRun(a.ID)
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if active != 0 {
		return applied(map[string]any{"run_id": active, "coalesced": true})
	}
	confirmedHash := a.ConfirmedHash != "" && a.ConfirmedHash == a.ApprovalHash
	switch {
	case confirmedHash && !a.Enabled:
		return failed(reasonConflict, "This automation is turned off on the Mac")
	case !confirmedHash:
		return failed(reasonConflict, "Confirm this automation on the Mac first")
	case asksFirst(a) && !confirmed:
		return failed(reasonConflict, "This automation asks before it runs — confirm it on the phone")
	}
	trigger := db.TriggerManual
	if a.TriggerKind == "button" {
		trigger = db.TriggerButton
	}
	runID, coalesced, err := h.d.DB.EnqueueAutomationRun(db.EnqueueRequest{
		AutomationID: a.ID, Trigger: trigger, Now: h.d.Clock(),
	})
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	h.wake()
	return applied(map[string]any{"run_id": runID, "coalesced": coalesced})
}

// activeRun is the automation's newest queued, running or waiting run; 0
// when none.
func (h *Handlers) activeRun(automationID int64) (int64, error) {
	var id sql.NullInt64
	err := h.d.DB.QueryRow(`SELECT MAX(id) FROM automation_runs
		WHERE automation_id = ? AND status IN ('queued','running','waiting')`, automationID).Scan(&id)
	return id.Int64, err
}

// asksFirst: a button recipe whose trigger says confirm: true.
func asksFirst(a *db.Automation) bool {
	if a.TriggerKind != "button" {
		return false
	}
	var spec struct {
		Button struct {
			Confirm bool `json:"confirm"`
		} `json:"button"`
	}
	return json.Unmarshal([]byte(a.TriggerSpec), &spec) == nil && spec.Button.Confirm
}
