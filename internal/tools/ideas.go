package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

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
