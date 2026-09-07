package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

type briefContextArgs struct {
	Summary string `json:"summary" jsonschema:"a concise summary of the message and its thread"`
	Reason  string `json:"reason" jsonschema:"one sentence for the owner"`
}

// NewBriefContext builds the brief_context write tool: no side effects
// beyond its own agent_actions row — the reaction composer already produced
// the summary; Execute just echoes it back so the strip card can render it.
func NewBriefContext() *Tool {
	schema, err := jsonschema.For[briefContextArgs](nil)
	if err != nil {
		panic("brief_context schema: " + err.Error())
	}
	return &Tool{
		Name:        "brief_context",
		Description: "Summarise the reacted message and its thread into a card (no side effects).",
		InputSchema: schema,
		Access:      AccessWrite, // registry write tool (records an action row); no external effect
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a briefContextArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Summary) == "" {
				return &ValidationError{Msg: "summary is required"}
			}
			return nil
		},
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			var a briefContextArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding brief_context args: %w", err)
			}
			return map[string]any{"summary": a.Summary}, nil
		},
	}
}
