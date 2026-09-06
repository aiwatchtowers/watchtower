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

func seedIdea(t *testing.T, d *db.DB, idea db.Idea, quote string) int64 {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	id, err := d.CreateIdeaTx(tx, idea)
	require.NoError(t, err)
	if quote != "" {
		require.NoError(t, d.InsertIdeaMentionTx(tx, db.IdeaMention{
			IdeaID: id, Source: "slack", Ref: "C1:123.456", Quote: quote, Author: "U1", SaidAt: "2026-06-01T00:00:00Z",
		}))
	}
	require.NoError(t, tx.Commit())
	return id
}

func ideasRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewListIdeas()))
	require.NoError(t, reg.Register(NewGetIdea()))
	return reg
}

// list_ideas filters by kind: a matching idea is returned, a non-matching one
// excluded.
func TestListIdeas_FiltersByKind(t *testing.T) {
	d := openDB(t)
	seedIdea(t, d, db.Idea{Kind: "idea", Title: "Ship dark mode", Status: "proposed", Source: "mined"}, "")
	seedIdea(t, d, db.Idea{Kind: "decision", Title: "Use SQLite", Status: "active", Source: "mined"}, "")

	got := callReadString(t, ideasRegistry(t, d), "list_ideas", `{"kind":"idea"}`)
	assert.Contains(t, got, "Ship dark mode")
	assert.NotContains(t, got, "Use SQLite", "kind filter must exclude the decision")
}

func TestListIdeas_RejectsInvalidKind(t *testing.T) {
	_, err := ideasRegistry(t, openDB(t)).CallRead(context.Background(), "list_ideas", json.RawMessage(`{"kind":"bogus"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "bogus")
}

// get_idea returns the idea and its mentions in one call.
func TestGetIdea_IncludesMentions(t *testing.T) {
	d := openDB(t)
	id := seedIdea(t, d, db.Idea{Kind: "idea", Title: "Ship dark mode", Status: "proposed", Source: "mined"}, "please add dark mode")

	got := callReadString(t, ideasRegistry(t, d), "get_idea", `{"id":`+strconv.FormatInt(id, 10)+`}`)
	assert.Contains(t, got, "Ship dark mode")
	assert.Contains(t, got, "please add dark mode")
}

func TestGetIdea_NotFound(t *testing.T) {
	_, err := ideasRegistry(t, openDB(t)).CallRead(context.Background(), "get_idea", json.RawMessage(`{"id":999999}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}
