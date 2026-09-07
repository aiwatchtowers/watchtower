package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreateIdea_ValidateRejectsBadInput(t *testing.T) {
	database := openDB(t)
	tool := NewCreateIdea()
	cases := map[string]string{
		"empty essence": `{"essence":"  ","reason":"r"}`,
		"unknown field": `{"essence":"x","reason":"r","bogus":1}`,
	}
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			err := tool.Validate(context.Background(), database, json.RawMessage(args))
			require.Error(t, err)
			var ve *ValidationError
			assert.ErrorAs(t, err, &ve)
		})
	}
}

func TestCreateIdea_ExecuteCreatesActiveOwnerIdea(t *testing.T) {
	database := openDB(t)
	tool := NewCreateIdea()
	args := json.RawMessage(`{"title":"Ship the strip","essence":"inbox as an action queue","reason":"owner asked"}`)
	if err := tool.Validate(context.Background(), database, args); err != nil {
		t.Fatalf("validate: %v", err)
	}
	res, err := tool.Execute(context.Background(), database, Call{ActionID: 7, Args: args})
	require.NoError(t, err)
	m := res.(map[string]any)
	if m["idea_id"] == nil {
		t.Fatalf("expected idea_id, got %v", m)
	}

	got, err := database.GetIdea(m["idea_id"].(int64))
	require.NoError(t, err)
	assert.Equal(t, "Ship the strip", got.Title)
	assert.Equal(t, "inbox as an action queue", got.Essence)
	assert.Equal(t, "active", got.Status)
	assert.Equal(t, "owner", got.Source)
}

func TestCreateIdea_Registration(t *testing.T) {
	tool := NewCreateIdea()
	assert.Equal(t, "create_idea", tool.Name)
	assert.Equal(t, AccessWrite, tool.Access)
	assert.False(t, tool.External)
	assert.Empty(t, tool.Surfaces)
	require.NotNil(t, tool.InputSchema)
}
