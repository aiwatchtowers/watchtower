package tools

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func targetsRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewListTargets()))
	require.NoError(t, reg.Register(NewGetTarget()))
	return reg
}

func seedTarget(t *testing.T, d *db.DB, text, status string) int {
	t.Helper()
	id, err := d.CreateTarget(db.Target{Text: text, Intent: "x", Level: "week", Status: status, Priority: "high", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	return int(id)
}

// list_targets filters by status: a matching target is returned, a non-matching
// one excluded.
func TestListTargets_FiltersByStatus(t *testing.T) {
	d := openDB(t)
	seedTarget(t, d, "Ship MCP server", "todo")
	seedTarget(t, d, "Unrelated in-progress item", "in_progress")

	got := callReadString(t, targetsRegistry(t, d), "list_targets", `{"status":"todo"}`)
	assert.Contains(t, got, "Ship MCP server")
	assert.NotContains(t, got, "Unrelated in-progress item", "status filter must exclude the in_progress target")
}

// Filtering by status=done returns done targets — GetTargets hides done rows
// unless IncludeDone is set, so a naive filter would return nothing.
func TestListTargets_ByDoneStatus(t *testing.T) {
	d := openDB(t)
	seedTarget(t, d, "Finished work", "done")

	got := callReadString(t, targetsRegistry(t, d), "list_targets", `{"status":"done"}`)
	assert.Contains(t, got, "Finished work")
}

// An empty result is a JSON array, not an error.
func TestListTargets_EmptyIsNotError(t *testing.T) {
	got := callReadString(t, targetsRegistry(t, openDB(t)), "list_targets", `{"status":"done"}`)
	assert.Equal(t, "[]", got)
}

func TestGetTarget_ReturnsTarget(t *testing.T) {
	d := openDB(t)
	id := seedTarget(t, d, "Ship MCP server", "todo")

	got := callReadString(t, targetsRegistry(t, d), "get_target", `{"id":`+strconv.Itoa(id)+`}`)
	assert.Contains(t, got, "Ship MCP server")
}

// A missing target is a friendly not-found error, not a raw sql error.
func TestGetTarget_NotFound(t *testing.T) {
	_, err := targetsRegistry(t, openDB(t)).CallRead(context.Background(), "get_target", json.RawMessage(`{"id":999}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no target with id 999")
	assert.NotContains(t, err.Error(), "sql: no rows")
}

func TestListTargets_RejectsInvalidEnums(t *testing.T) {
	reg := targetsRegistry(t, openDB(t))
	cases := []struct{ field, value, wantAllowed string }{
		{"status", "in-progress", "todo|in_progress|blocked|done|dismissed|snoozed"},
		{"priority", "urgent", "high|medium|low"},
		{"level", "year", "quarter|month|week|day|custom"},
		{"ownership", "theirs", "mine|delegated|watching"},
	}
	for _, c := range cases {
		_, err := reg.CallRead(context.Background(), "list_targets", json.RawMessage(`{"`+c.field+`":"`+c.value+`"}`))
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, "%s=%s", c.field, c.value)
		assert.Contains(t, verr.Msg, c.value)
		assert.Contains(t, verr.Msg, c.wantAllowed)
	}
}
