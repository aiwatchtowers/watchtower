package tracks

import (
	"context"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// The model sees namespaced channel ids but may echo the bare form, invent
// one, or echo a raw id two accounts share. Only a result that resolves to a
// batch entry is stored, under that entry's namespaced id; the rest are
// dropped without failing the batch.
func TestGenerateBatchTracks_ResolvesModelChannelIDAgainstBatch(t *testing.T) {
	database := testDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test"}))
	_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U1"})
	require.NoError(t, err)

	entries := []digestEntry{
		{channelID: "1:C1", channelName: "backend"},
		{channelID: "1:C2", channelName: "frontend"},
		{channelID: "1:C7", channelName: "shared-a"},
		{channelID: "2:C7", channelName: "shared-b"},
	}
	resp := `[
	 {"channel_id":"C1","items":[{"text":"Bare echo","context":"c","category":"task","ownership":"mine","priority":"medium"}]},
	 {"channel_id":"1:C2","items":[{"text":"Exact echo","context":"c","category":"task","ownership":"mine","priority":"medium"}]},
	 {"channel_id":"C9","items":[{"text":"Invented channel","context":"c","category":"task","ownership":"mine","priority":"medium"}]},
	 {"channel_id":"C7","items":[{"text":"Ambiguous raw","context":"c","category":"task","ownership":"mine","priority":"medium"}]}
	]`
	pipe := New(database, testConfig(), &routingMockGenerator{individualResponse: resp, batchResponse: resp}, log.Default())

	now := time.Now()
	stored, err := pipe.generateBatchTracks(context.Background(), entries, "U1", "alice",
		float64(now.Add(-time.Hour).Unix()), float64(now.Unix()))
	require.NoError(t, err)
	assert.Equal(t, 2, stored)

	tracks, err := database.GetAllActiveTracks()
	require.NoError(t, err)
	got := map[string]string{}
	for _, tr := range tracks {
		got[tr.Text] = tr.ChannelIDs
	}
	assert.Equal(t, map[string]string{
		"Bare echo":  `["1:C1"]`,
		"Exact echo": `["1:C2"]`,
	}, got)
}

func TestNewBatchChannelResolver_EmptyBatchResolvesNothing(t *testing.T) {
	resolve := newBatchChannelResolver(nil)
	_, ok := resolve("C1")
	assert.False(t, ok)
	_, ok = resolve("")
	assert.False(t, ok)
}
