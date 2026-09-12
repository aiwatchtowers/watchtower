package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

type remindMeArgs struct {
	RemindAt string `json:"remind_at" jsonschema:"ISO-8601 UTC time to resurface this, e.g. 2026-09-07T09:00:00Z"`
	Note     string `json:"note,omitempty" jsonschema:"a short note about what to follow up on"`
	Reason   string `json:"reason" jsonschema:"one sentence for the owner"`
}

// NewRemindMe builds the remind_me write tool: parks the reacted message
// (its ref threaded through Call.Binding.ContextID, REACT-02) to resurface
// at a chosen time.
func NewRemindMe() *Tool {
	schema, err := jsonschema.For[remindMeArgs](nil)
	if err != nil {
		panic("remind_me schema: " + err.Error())
	}
	return &Tool{
		Name:        "remind_me",
		Description: "Park a message to resurface in the inbox at a chosen time.",
		InputSchema: schema,
		Access:      AccessWrite,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a remindMeArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.RemindAt) == "" {
				return &ValidationError{Msg: "remind_at is required"}
			}
			return nil
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a remindMeArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding remind_me args: %w", err)
			}
			id, err := d.InsertReminder(db.Reminder{
				MessageRef: call.Binding.ContextID,
				Note:       strings.TrimSpace(a.Note),
				RemindAt:   strings.TrimSpace(a.RemindAt),
			})
			if err != nil {
				return nil, fmt.Errorf("creating reminder: %w", err)
			}
			return map[string]any{"reminder_id": id}, nil
		},
	}
}
