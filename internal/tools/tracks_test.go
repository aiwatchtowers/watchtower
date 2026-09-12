package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreateTrack_ValidateRejectsBadInput(t *testing.T) {
	database := openDB(t)
	tool := NewCreateTrack()
	cases := map[string]string{
		"empty text":    `{"text":"  ","reason":"r"}`,
		"unknown field": `{"text":"x","reason":"r","bogus":1}`,
		"long text":     `{"text":"` + strings.Repeat("x", 201) + `","reason":"r"}`,
	}
	for name, raw := range cases {
		err := tool.Validate(context.Background(), database, json.RawMessage(raw))
		var verr *ValidationError
		assert.ErrorAs(t, err, &verr, name)
	}
	assert.NoError(t, tool.Validate(context.Background(), database,
		json.RawMessage(`{"text":"Watch the billing migration","context":"rollout risk","reason":"r"}`)))
	// Verify exactly 200 runes passes (including multi-byte Unicode)
	assert.NoError(t, tool.Validate(context.Background(), database,
		json.RawMessage(`{"text":"`+strings.Repeat("я", 200)+`","reason":"r"}`)))
}

func TestCreateTrack_ExecuteCreatesCustomTrack(t *testing.T) {
	database := openDB(t)
	tool := NewCreateTrack()
	args := json.RawMessage(`{"text":"Watch the billing migration","context":"rollout risk","reason":"owner asked to track"}`)
	if err := tool.Validate(context.Background(), database, args); err != nil {
		t.Fatalf("validate: %v", err)
	}
	res, err := tool.Execute(context.Background(), database, Call{ActionID: 7, Args: args})
	require.NoError(t, err)
	m := res.(map[string]any)
	if m["track_id"] == nil {
		t.Fatalf("expected track_id, got %v", m)
	}

	row, err := database.GetTrackByID(int(m["track_id"].(int64)))
	require.NoError(t, err)
	assert.Equal(t, "Watch the billing migration", row.Text)
	assert.Equal(t, "rollout risk", row.Context)
	assert.Equal(t, "custom", row.Origin)
	assert.True(t, row.Enabled)
}

func TestCreateTrack_Registration(t *testing.T) {
	tool := NewCreateTrack()
	assert.Equal(t, "create_track", tool.Name)
	assert.Equal(t, AccessWrite, tool.Access)
	assert.False(t, tool.External)
	assert.Empty(t, tool.Surfaces)
	require.NotNil(t, tool.InputSchema)
}
