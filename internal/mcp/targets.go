package mcp

import (
	"context"
	"database/sql"
	"errors"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listTargetsArgs struct {
	Status    string `json:"status,omitempty" jsonschema:"filter by status: todo|in_progress|blocked|done|dismissed|snoozed"`
	Priority  string `json:"priority,omitempty" jsonschema:"filter by priority: high|medium|low"`
	Level     string `json:"level,omitempty" jsonschema:"filter by level: quarter|month|week|day|custom"`
	Ownership string `json:"ownership,omitempty" jsonschema:"filter by ownership: mine|delegated|watching"`
	Limit     int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50)"`
}

type getTargetArgs struct {
	ID int `json:"id" jsonschema:"target id"`
}

func registerTargets(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_targets",
		Description: "List the user's personal action items (targets), optionally filtered by status, priority, level, or ownership.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listTargetsArgs) (*mcpsdk.CallToolResult, any, error) {
		targets, err := database.GetTargets(db.TargetFilter{
			Status:    args.Status,
			Priority:  args.Priority,
			Level:     args.Level,
			Ownership: args.Ownership,
			Limit:     listLimit(args.Limit),
			// GetTargets excludes done/dismissed unless IncludeDone is set; without
			// this, filtering by status=done/dismissed would always return [].
			IncludeDone: args.Status == "done" || args.Status == "dismissed",
		})
		if err != nil {
			return errResult("listing targets: " + err.Error()), nil, nil
		}
		return jsonListResult(targets)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_target",
		Description: "Get a single target by id, including sub-items, notes, and metadata.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getTargetArgs) (*mcpsdk.CallToolResult, any, error) {
		target, err := database.GetTargetByID(args.ID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return errResult("no target with id " + itoa(args.ID)), nil, nil
			}
			return errResult("getting target: " + err.Error()), nil, nil
		}
		return jsonResult(target)
	})
}
