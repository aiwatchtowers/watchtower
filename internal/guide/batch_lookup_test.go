package guide

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedNamespacedLowDataUsers seeds low-data (batch tier) users under the
// given namespaced ids, the shape every multi-account install stores.
func seedNamespacedLowDataUsers(t *testing.T, database *db.DB, userIDs ...string) (float64, float64) {
	t.Helper()
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"}))
	seedChannel(t, database, "1:C1", "general")
	now := time.Now()
	from := float64(now.Add(-7 * 24 * time.Hour).Unix())
	to := float64(now.Unix())
	base := from + 86400
	for u, id := range userIDs {
		seedUser(t, database, id, fmt.Sprintf("user%d", u))
		for i := range 4 {
			seedMessage(t, database, "1:C1", fmt.Sprintf("%.6f", base+float64((u*10+i)*60)), id, "msg")
		}
	}
	seedDigestWithSituations(t, database, "1:C1", from, to, `[]`,
		`[{"topic":"Topic X","type":"collaboration","participants":[{"user_id":"1:U9","role":"lead"}],"dynamic":"unrelated","outcome":"done","red_flags":[],"observations":[],"message_refs":[]}]`)
	return from, to
}

// The prompt carries namespaced ids but its JSON example a bare one; a
// model echoing the bare id must still land its card on the right user
// instead of silently falling back.
func TestPipeline_BatchResultMatchesBareUserID(t *testing.T) {
	database := testDB(t)
	from, to := seedNamespacedLowDataUsers(t, database, "1:U1", "1:U2")
	cfg := testConfig()
	cfg.AI.Workers = 1

	gen := &recordingGenerator{batchResponse: batchCardJSON("U1", "1:U2")}
	_, err := New(database, cfg, gen, testLogger()).RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, "active", cardStatus(t, database, "1:U1"), "bare echo resolves")
	assert.Equal(t, "active", cardStatus(t, database, "1:U2"), "exact echo resolves")
}

// A bare id two accounts share is ambiguous: neither user gets the card.
func TestPipeline_BatchResultSharedRawIDIsNotGuessed(t *testing.T) {
	database := testDB(t)
	from, to := seedNamespacedLowDataUsers(t, database, "1:U1", "2:U1")
	cfg := testConfig()
	cfg.AI.Workers = 1

	gen := &recordingGenerator{batchResponse: batchCardJSON("U1")}
	_, err := New(database, cfg, gen, testLogger()).RunForWindow(context.Background(), from, to)
	require.Error(t, err, "no AI card was produced")
	assert.Equal(t, "insufficient_data", cardStatus(t, database, "1:U1"))
	assert.Equal(t, "insufficient_data", cardStatus(t, database, "2:U1"))
}

func TestNewBatchResultLookup_EmptyInputs(t *testing.T) {
	lookup := newBatchResultLookup(nil, nil)
	_, ok := lookup("1:U1")
	assert.False(t, ok)
	_, ok = lookup("")
	assert.False(t, ok)
}
