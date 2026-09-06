package tools

import (
	"context"
	"encoding/json"
	"fmt"

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

// ideaWithMentions is the get_idea response shape: the idea plus every sighting
// recorded against it, so a caller does not need a second tool call.
type ideaWithMentions struct {
	Idea     db.Idea          `json:"idea"`
	Mentions []db.IdeaMention `json:"mentions"`
}

var (
	ideaKinds    = []string{"idea", "decision", "note"}
	ideaStatuses = []string{"proposed", "active", "rejected", "not_now", "converted", "dropped", "merged", "superseded", "reversed"}
)

// NewListIdeas lists ideas/decisions/notes, optionally filtered by kind, status,
// or a text query.
func NewListIdeas() *Tool {
	return &Tool{
		Name:        "list_ideas",
		Description: "List ideas, decisions, and notes from the ideas registry, optionally filtered by kind, status, or a text query.",
		InputSchema: mustSchema[listIdeasArgs]("list_ideas"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listIdeasArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if err := firstErr(
				validateEnum("kind", a.Kind, ideaKinds...),
				validateEnum("status", a.Status, ideaStatuses...),
			); err != nil {
				return nil, err
			}
			ideas, err := d.ListIdeas(db.IdeaFilter{Kind: a.Kind, Status: a.Status, Query: a.Query, Limit: listLimit(a.Limit)})
			if err != nil {
				return nil, fmt.Errorf("listing ideas: %w", err)
			}
			if ideas == nil {
				ideas = []db.Idea{}
			}
			return ideas, nil
		},
	}
}

// NewGetIdea fetches one idea by id, including every recorded mention.
func NewGetIdea() *Tool {
	return &Tool{
		Name:        "get_idea",
		Description: "Get a single idea by id, including every recorded mention.",
		InputSchema: mustSchema[getIdeaArgs]("get_idea"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getIdeaArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			idea, err := d.GetIdea(a.ID)
			if err != nil {
				return nil, fmt.Errorf("getting idea: %w", err)
			}
			if idea == nil {
				return nil, fmt.Errorf("idea not found")
			}
			mentions, err := d.ListIdeaMentions(a.ID)
			if err != nil {
				return nil, fmt.Errorf("listing idea mentions: %w", err)
			}
			return ideaWithMentions{Idea: *idea, Mentions: mentions}, nil
		},
	}
}
