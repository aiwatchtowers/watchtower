package mcp

import (
	"context"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listIdeasArgs struct {
	Kind   string `json:"kind,omitempty" jsonschema:"filter by kind: idea, decision, or note"`
	Status string `json:"status,omitempty" jsonschema:"filter by status: proposed, active, rejected, not_now, converted, dropped, merged, superseded, or reversed"`
	Query  string `json:"query,omitempty" jsonschema:"substring match against title, essence, or mention quotes"`
	Limit  int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getIdeaArgs struct {
	ID int64 `json:"id" jsonschema:"idea id"`
}

// ideaWithMentions is the get_idea response shape: the idea plus every
// sighting recorded against it, so a caller does not need a second tool call.
type ideaWithMentions struct {
	Idea     db.Idea          `json:"idea"`
	Mentions []db.IdeaMention `json:"mentions"`
}

func registerIdeas(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_ideas",
		Description: "List ideas, decisions, and notes from the ideas registry, optionally filtered by kind, status, or a text query.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listIdeasArgs) (*mcpsdk.CallToolResult, any, error) {
		if msg := firstError(
			validateEnum("kind", args.Kind, "idea", "decision", "note"),
			validateEnum("status", args.Status, "proposed", "active", "rejected", "not_now",
				"converted", "dropped", "merged", "superseded", "reversed"),
		); msg != "" {
			return errResult(msg), nil, nil
		}
		ideas, err := database.ListIdeas(db.IdeaFilter{
			Kind:   args.Kind,
			Status: args.Status,
			Query:  args.Query,
			Limit:  listLimit(args.Limit),
		})
		if err != nil {
			return errResult("listing ideas: " + err.Error()), nil, nil
		}
		return jsonListResult(ideas)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_idea",
		Description: "Get a single idea by id, including every recorded mention.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getIdeaArgs) (*mcpsdk.CallToolResult, any, error) {
		idea, err := database.GetIdea(args.ID)
		if err != nil {
			return errResult("getting idea: " + err.Error()), nil, nil
		}
		if idea == nil {
			return errResult("idea not found"), nil, nil
		}
		mentions, err := database.ListIdeaMentions(args.ID)
		if err != nil {
			return errResult("listing idea mentions: " + err.Error()), nil, nil
		}
		return jsonResult(ideaWithMentions{Idea: *idea, Mentions: mentions})
	})
}
