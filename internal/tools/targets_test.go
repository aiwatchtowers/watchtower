package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestCreateTarget_ValidateRejectsBadInput(t *testing.T) {
	database := openDB(t)
	tool := NewCreateTarget()
	cases := map[string]string{
		"empty text":    `{"text":"  ","reason":"r"}`,
		"unknown field": `{"text":"x","reason":"r","bogus":1}`,
		"bad priority":  `{"text":"x","reason":"r","priority":"urgent"}`,
		"bad due":       `{"text":"x","reason":"r","due":"tomorrow"}`,
		"long text":     `{"text":"` + string(make([]byte, 201)) + `","reason":"r"}`,
	}
	for name, raw := range cases {
		err := tool.Validate(context.Background(), database, json.RawMessage(raw))
		var verr *ValidationError
		assert.ErrorAs(t, err, &verr, name)
	}
	assert.NoError(t, tool.Validate(context.Background(), database,
		json.RawMessage(`{"text":"Call Vasya","reason":"r","due":"2026-09-05T16:00","priority":"high"}`)))
	assert.NoError(t, tool.Validate(context.Background(), database,
		json.RawMessage(`{"text":"Renew cert","reason":"r","due":"2026-09-12"}`)))
}

func TestCreateTarget_ExecuteMatchesRemindShape(t *testing.T) {
	database := openDB(t)
	tool := NewCreateTarget()
	out, err := tool.Execute(context.Background(), database, Call{
		ActionID: 42,
		Args:     json.RawMessage(`{"text":"Call Vasya","intent":"agree the date","reason":"r","due":"2026-09-05T16:00","priority":"high"}`),
	})
	require.NoError(t, err)
	res := out.(map[string]any)
	id := res["target_id"].(int64)

	row, err := database.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "Call Vasya", row.Text)
	assert.Equal(t, "agree the date", row.Intent)
	assert.Equal(t, "day", row.Level)
	assert.Equal(t, "todo", row.Status)
	assert.Equal(t, "high", row.Priority)
	assert.Equal(t, "mine", row.Ownership)
	assert.Equal(t, "2026-09-05T16:00", row.DueDate)
	assert.Equal(t, "chat", row.SourceType)
	assert.Equal(t, "42", row.SourceID)
	assert.Equal(t, row.PeriodStart, row.PeriodEnd)
}

func TestCreateTarget_Registration(t *testing.T) {
	tool := NewCreateTarget()
	assert.Equal(t, "create_target", tool.Name)
	assert.Equal(t, AccessWrite, tool.Access)
	assert.False(t, tool.External)
	assert.Equal(t, []string{"main"}, tool.Surfaces)
	require.NotNil(t, tool.InputSchema)
	_ = db.Target{} // keeps the import honest if GetTarget's name changes
}
