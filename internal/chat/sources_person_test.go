package chat

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// TestPersonSource_StillReadsUserID (#1769, A24): get_person's new output
// (the card minus the dropped fields) still feeds the chat's person source
// chip through its UserID key.
func TestPersonSource_StillReadsUserID(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	require.NoError(t, d.UpsertUser(db.User{ID: "1:UDANA", Name: "dana"}))
	_, err = d.UpsertPeopleCard(db.PeopleCard{UserID: "1:UDANA", Summary: "Leads payments", Status: "active", PeriodFrom: 1, PeriodTo: 2})
	require.NoError(t, err)
	reg := tools.New(d)
	require.NoError(t, reg.Register(tools.NewGetPerson()))
	out, err := reg.CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"1:UDANA"}`), tools.Binding{})
	require.NoError(t, err)
	raw, err := json.Marshal(out)
	require.NoError(t, err)

	summary, sources := personSource(raw)
	assert.Equal(t, "Opened person 1:UDANA", summary)
	assert.Equal(t, []Source{{Kind: "person", Title: "1:UDANA", Ref: "person:1:UDANA"}}, sources)
}
