package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestRemindMe_ExecuteInsertsReminderWithRef(t *testing.T) {
	d := openDB(t)
	tool := NewRemindMe()
	args := json.RawMessage(`{"remind_at":"2999-01-01T09:00:00Z","note":"follow up","reason":"owner asked"}`)
	if err := tool.Validate(context.Background(), d, args); err != nil {
		t.Fatalf("validate: %v", err)
	}
	res, err := tool.Execute(context.Background(), d, Call{ActionID: 3, Args: args,
		Binding: Binding{Surface: "reaction", ContextType: "reaction", ContextID: "C9@123.45"}})
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	if res.(map[string]any)["reminder_id"] == nil {
		t.Fatalf("expected reminder_id, got %v", res)
	}
	due, err := d.ListDueReminders("3000-01-01T00:00:00Z")
	require.NoError(t, err)
	if len(due) != 1 || due[0].MessageRef != "C9@123.45" {
		t.Fatalf("reminder should carry the reacted ref, got %+v", due)
	}
}

func TestRemindMe_ValidateRejectsBadInput(t *testing.T) {
	d := openDB(t)
	tool := NewRemindMe()
	cases := map[string]string{
		"empty remind_at": `{"remind_at":"  ","reason":"r"}`,
		"unknown field":   `{"remind_at":"2999-01-01T09:00:00Z","reason":"r","bogus":1}`,
	}
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			err := tool.Validate(context.Background(), d, json.RawMessage(args))
			require.Error(t, err)
			var ve *ValidationError
			assert.ErrorAs(t, err, &ve)
		})
	}
}

func TestRemindMe_Registration(t *testing.T) {
	tool := NewRemindMe()
	assert.Equal(t, "remind_me", tool.Name)
	assert.Equal(t, AccessWrite, tool.Access)
	assert.False(t, tool.External)
	assert.Empty(t, tool.Surfaces)
	require.NotNil(t, tool.InputSchema)
}
