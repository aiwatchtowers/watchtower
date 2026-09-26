package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBriefContext_ExecuteEchoesSummary(t *testing.T) {
	d := openDB(t)
	tool := NewBriefContext()
	args := json.RawMessage(`{"summary":"Vendor wants a call Friday.","reason":"owner asked for a brief"}`)
	if err := tool.Validate(context.Background(), d, args); err != nil {
		t.Fatalf("validate: %v", err)
	}
	res, err := tool.Execute(context.Background(), d, Call{ActionID: 1, Args: args})
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	if res.(map[string]any)["summary"] != "Vendor wants a call Friday." {
		t.Fatalf("summary not echoed: %v", res)
	}
}

func TestBriefContext_ValidateRejectsBadInput(t *testing.T) {
	d := openDB(t)
	tool := NewBriefContext()
	cases := map[string]string{
		"empty summary": `{"summary":"  ","reason":"r"}`,
		"unknown field": `{"summary":"x","reason":"r","bogus":1}`,
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

func TestBriefContext_Registration(t *testing.T) {
	tool := NewBriefContext()
	assert.Equal(t, "brief_context", tool.Name)
	assert.Equal(t, AccessWrite, tool.Access)
	assert.False(t, tool.External)
	assert.Equal(t, []string{"reaction"}, tool.Surfaces, "reaction-path only")
	require.NotNil(t, tool.InputSchema)
}
