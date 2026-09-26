package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

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

type createIdeaArgs struct {
	Title   string `json:"title,omitempty" jsonschema:"a short idea title"`
	Essence string `json:"essence" jsonschema:"the idea in one or two sentences"`
	Reason  string `json:"reason" jsonschema:"one sentence for the owner"`
}

// NewCreateIdea builds the create_idea write tool: an owner-authored idea
// (status='active', source='owner') in the ideas registry, the Go twin of
// Swift IdeaQueries.createManual via db.CreateManualIdea.
func NewCreateIdea() *Tool {
	schema, err := jsonschema.For[createIdeaArgs](nil)
	if err != nil {
		panic("create_idea schema: " + err.Error())
	}
	return &Tool{
		Name:        "create_idea",
		Description: "Capture an idea in the ideas registry.",
		InputSchema: schema,
		Access:      AccessWrite,
		// Reaction-path only (REACT-02 threads the reacted message ref through
		// Call.Binding): mounting it in the main/target chat would let a chat
		// turn create work outside its mandate with no message to bind to.
		Surfaces: []string{"reaction"},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a createIdeaArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Essence) == "" {
				return &ValidationError{Msg: "essence is required"}
			}
			return nil
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a createIdeaArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_idea args: %w", err)
			}
			id, err := d.CreateManualIdea("idea", strings.TrimSpace(a.Title), strings.TrimSpace(a.Essence))
			if err != nil {
				return nil, fmt.Errorf("creating idea: %w", err)
			}
			return map[string]any{"idea_id": id}, nil
		},
	}
}
