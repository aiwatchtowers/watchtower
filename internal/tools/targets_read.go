package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"watchtower/internal/db"
)

type listTargetsArgs struct {
	Status    string `json:"status,omitempty" jsonschema:"filter by status: todo|in_progress|in_review|blocked|done|dismissed|snoozed (in_review: workbench targets only)"`
	Priority  string `json:"priority,omitempty" jsonschema:"filter by priority: high|medium|low"`
	Level     string `json:"level,omitempty" jsonschema:"filter by level: quarter|month|week|day|custom"`
	Ownership string `json:"ownership,omitempty" jsonschema:"filter by ownership: mine|delegated|watching"`
	Limit     int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getTargetArgs struct {
	ID int `json:"id" jsonschema:"target id"`
}

// NewListTargets lists the owner's targets, optionally filtered by status,
// priority, level, or ownership.
func NewListTargets() *Tool {
	return &Tool{
		Name:        "list_targets",
		Description: "List the user's personal action items (targets), optionally filtered by status, priority, level, or ownership.",
		InputSchema: mustSchema[listTargetsArgs]("list_targets"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listTargetsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if err := firstErr(
				validateEnum("status", a.Status, "todo", "in_progress", "in_review", "blocked", "done", "dismissed", "snoozed"),
				validateEnum("priority", a.Priority, "high", "medium", "low"),
				validateEnum("level", a.Level, "quarter", "month", "week", "day", "custom"),
				validateEnum("ownership", a.Ownership, "mine", "delegated", "watching"),
			); err != nil {
				return nil, err
			}
			targets, err := d.GetTargets(db.TargetFilter{
				Status: a.Status, Priority: a.Priority, Level: a.Level, Ownership: a.Ownership,
				Limit: listLimit(a.Limit),
				// GetTargets excludes done/dismissed unless IncludeDone is set;
				// without this, filtering by status=done/dismissed returns [].
				IncludeDone: a.Status == "done" || a.Status == "dismissed",
				// 0 (every non-workbench session) excludes workbench targets
				// (PROJ-01); a workbench session sees only its own board.
				WorkbenchID: call.Binding.WorkbenchID,
			})
			if err != nil {
				return nil, fmt.Errorf("listing targets: %w", err)
			}
			if targets == nil {
				targets = []db.Target{}
			}
			return targets, nil
		},
	}
}

// workbenchTargetView is get_target's answer in a workbench session: the target
// plus its newest status changes, oldest first, and its attached images.
type workbenchTargetView struct {
	*db.Target
	StatusHistory []db.TargetStatusChange   `json:"status_history"`
	Images        []db.WorkbenchTargetImage `json:"images"`
}

// NewGetTarget fetches one target by id, including sub-items, notes, and metadata.
func NewGetTarget() *Tool {
	return &Tool{
		Name: "get_target",
		Description: "Get a single target by id, including sub-items, notes, and metadata; a workbench " +
			"target also carries its status_history (newest 50 changes, oldest first) and its attached images " +
			"(id, file_name, mime, size, path of Watchtower's stored copy — read that path to look at one).",
		InputSchema: mustSchema[getTargetArgs]("get_target"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getTargetArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			target, err := d.GetTargetByID(a.ID)
			if err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					return nil, fmt.Errorf("no target with id %d", a.ID)
				}
				return nil, fmt.Errorf("getting target: %w", err)
			}
			// A target outside the session's scope reads as missing: a workbench
			// target never reaches a non-workbench session (PROJ-01), and a
			// workbench session sees only its own workbench's targets (DEV-06).
			if target.WorkbenchID.Int64 != call.Binding.WorkbenchID {
				return nil, fmt.Errorf("no target with id %d", a.ID)
			}
			if call.Binding.WorkbenchID == 0 {
				return target, nil
			}
			// A workbench target also carries its status history (PROJ-06).
			history, err := d.GetTargetStatusHistory(int64(target.ID), db.MaxStatusHistory)
			if err != nil {
				return nil, err
			}
			images, err := d.ListWorkbenchTargetImages(int64(target.ID))
			if err != nil {
				return nil, err
			}
			return workbenchTargetView{Target: target, StatusHistory: history, Images: images}, nil
		},
	}
}
