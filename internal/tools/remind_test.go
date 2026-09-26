package tools

import (
	"context"
	"encoding/json"
	"testing"
	"time"

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
		"empty remind_at":   `{"remind_at":"  ","reason":"r"}`,
		"unknown field":     `{"remind_at":"2999-01-01T09:00:00Z","reason":"r","bogus":1}`,
		"natural language":  `{"remind_at":"tomorrow morning","reason":"r"}`,
		"date without time": `{"remind_at":"2999-01-01","reason":"r"}`,
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
	assert.Equal(t, []string{"reaction"}, tool.Surfaces, "reaction-path only")
	require.NotNil(t, tool.InputSchema)
}

// The due readers compare remind_at as TEXT against a UTC "Z" now, so every
// accepted shape must land in the store as UTC: an offset is converted, an
// owner-local wall-clock time is interpreted in the owner's zone.
func TestRemindMe_NormalizesRemindAtToUTC(t *testing.T) {
	d := openDB(t)
	tool := NewRemindMe()

	execute := func(remindAt string) string {
		args := json.RawMessage(`{"remind_at":"` + remindAt + `","reason":"r"}`)
		require.NoError(t, tool.Validate(context.Background(), d, args))
		res, err := tool.Execute(context.Background(), d, Call{ActionID: 1, Args: args,
			Binding: Binding{Surface: "reaction", ContextType: "reaction", ContextID: "C1@1.0"}})
		require.NoError(t, err)
		due, err := d.ListDueReminders("3000-01-01T00:00:00Z")
		require.NoError(t, err)
		for _, r := range due {
			if r.ID == res.(map[string]any)["reminder_id"].(int64) {
				return r.RemindAt
			}
		}
		t.Fatalf("reminder not found among due rows: %+v", due)
		return ""
	}

	assert.Equal(t, "2999-01-01T07:00:00Z", execute("2999-01-01T09:00:00+02:00"), "offset converted to UTC")
	assert.Equal(t, "2999-01-01T09:00:00Z", execute("2999-01-01T09:00:00Z"), "UTC kept as is")

	local, err := time.ParseInLocation("2006-01-02T15:04", "2999-01-01T09:00", time.Local)
	require.NoError(t, err)
	assert.Equal(t, local.UTC().Format("2006-01-02T15:04:05Z"), execute("2999-01-01T09:00"), "owner-local wall clock interpreted in the owner's zone")
}

// A reminder with an offset that is already past in UTC is due right away —
// the TEXT comparison only works because the stored value is normalized.
func TestRemindMe_OffsetPastInUTCIsDue(t *testing.T) {
	d := openDB(t)
	tool := NewRemindMe()
	args := json.RawMessage(`{"remind_at":"2026-01-01T02:00:00+05:00","reason":"r"}`)
	require.NoError(t, tool.Validate(context.Background(), d, args))
	_, err := tool.Execute(context.Background(), d, Call{ActionID: 2, Args: args, Binding: Binding{ContextID: "C1@2.0"}})
	require.NoError(t, err)
	due, err := d.ListDueReminders("2026-01-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, due, 1, "2026-01-01T02:00+05:00 is 2025-12-31T21:00Z — already due at 2026-01-01T00:00Z")
}
