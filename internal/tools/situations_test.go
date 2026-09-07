package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// list_situations defaults to open and returns the situation rows.
func TestListSituations_DefaultsToOpen(t *testing.T) {
	database := openDB(t)
	_, err := database.CreateSituation(db.DashboardSituation{Title: "Deploy broke", Status: "open", Priority: "high", Kind: "external"})
	require.NoError(t, err)
	_, err = database.CreateSituation(db.DashboardSituation{Title: "Old done thing", Status: "done"})
	require.NoError(t, err)

	reg := New(database)
	require.NoError(t, reg.Register(NewListSituations()))

	data, err := reg.CallRead(context.Background(), "list_situations", json.RawMessage(`{}`))
	require.NoError(t, err)
	b, _ := json.Marshal(data)
	assert.Contains(t, string(b), "Deploy broke")
	assert.Contains(t, string(b), `"status":"open"`)
	assert.NotContains(t, string(b), "Old done thing", "default status is open, done is excluded")
}

// get_situation returns the card plus its member signals.
func TestGetSituation_ReturnsDetail(t *testing.T) {
	database := openDB(t)
	id, err := database.CreateSituation(db.DashboardSituation{Title: "X", Status: "open", Summary: "the summary"})
	require.NoError(t, err)

	reg := New(database)
	require.NoError(t, reg.Register(NewGetSituation()))

	data, err := reg.CallRead(context.Background(), "get_situation", json.RawMessage(fmt.Sprintf(`{"id":%d}`, id)))
	require.NoError(t, err)
	b, _ := json.Marshal(data)
	assert.Contains(t, string(b), `"summary":"the summary"`)
	assert.Contains(t, string(b), `"signals":`)
}

// An unknown status is a model-facing ValidationError, not a silent empty list.
func TestListSituations_RejectsUnknownStatus(t *testing.T) {
	reg := New(openDB(t))
	require.NoError(t, reg.Register(NewListSituations()))

	_, err := reg.CallRead(context.Background(), "list_situations", json.RawMessage(`{"status":"in_progress"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
}

// An ill-formed since date is rejected, not concatenated into a malformed bound.
func TestListSituations_RejectsBadSince(t *testing.T) {
	reg := New(openDB(t))
	require.NoError(t, reg.Register(NewListSituations()))

	_, err := reg.CallRead(context.Background(), "list_situations", json.RawMessage(`{"since":"last week"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
}

// get_situation on a missing id returns an error the loop feeds back to the model.
func TestGetSituation_NotFound(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	require.NoError(t, reg.Register(NewGetSituation()))

	_, err := reg.CallRead(context.Background(), "get_situation", json.RawMessage(`{"id":999}`))
	assert.Error(t, err)
}
