package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

type createTrackArgs struct {
	Text    string `json:"text" jsonschema:"the track title / what to watch, at most 200 characters"`
	Context string `json:"context,omitempty" jsonschema:"why it matters / what to watch for"`
	Reason  string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// NewCreateTrack builds the create_track write tool: a new narrative track to
// watch a topic over time, in the owner manual-create shape
// (origin='custom', enabled=1) via db.CreateCustomTrack. Visible on every
// chat surface (no Surfaces restriction, unlike create_target).
func NewCreateTrack() *Tool {
	schema, err := jsonschema.For[createTrackArgs](nil)
	if err != nil {
		panic("create_track schema: " + err.Error())
	}
	return &Tool{
		Name: "create_track",
		Description: "Propose a new narrative track to watch a topic over time in the owner's Watchtower " +
			"tracks list. The owner approves it in the chat before it is created. Use it when the owner asks to " +
			"keep an eye on or follow something over time.",
		InputSchema: schema,
		Access:      AccessWrite,
		// Reaction-path only (REACT-02 threads the reacted message ref through
		// Call.Binding): mounting it in the main/target chat would let a chat
		// turn create work outside its mandate with no message to bind to.
		Surfaces: []string{"reaction"},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a createTrackArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			text := strings.TrimSpace(a.Text)
			switch {
			case text == "":
				return &ValidationError{Msg: "text is required"}
			case len([]rune(text)) > 200:
				return &ValidationError{Msg: "text must be at most 200 characters"}
			}
			return nil
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a createTrackArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_track args: %w", err)
			}
			id, err := d.CreateCustomTrack(db.Track{
				Text:    strings.TrimSpace(a.Text),
				Context: strings.TrimSpace(a.Context),
			})
			if err != nil {
				return nil, fmt.Errorf("creating track: %w", err)
			}
			return map[string]any{"track_id": id}, nil
		},
	}
}
