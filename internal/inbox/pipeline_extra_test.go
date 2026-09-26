package inbox

import (
	"log"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestPipeline_AccumulatedUsage_AlwaysZero pins the post-demolition contract:
// Run makes no AI call, so the usage the daemon and CLI report is always zero.
func TestPipeline_AccumulatedUsage_AlwaysZero(t *testing.T) {
	p := &Pipeline{}
	in, out, cost, total := p.AccumulatedUsage()
	assert.Equal(t, 0, in)
	assert.Equal(t, 0, out)
	assert.Equal(t, float64(0), cost)
	assert.Equal(t, 0, total)
}

func TestLoadContext_ResolvesMentionInMessageText(t *testing.T) {
	// Item context lines already resolve the author name; raw `<@U…>` mentions
	// inside the text must resolve too instead of being dropped.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	p := New(d, testConfig(), nil, log.Default())
	p.SetOwner(db.Owner{ID: "U1", SlackUserID: "U1", Email: "u1@test.com"})

	require.NoError(t, d.UpsertUser(db.User{ID: "U3", Name: "bob", DisplayName: "Bob Brown"}))
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "ask <@U3> about the rollout")
	insertMessage(t, d, "C1", "100.2", "U2", "any update?")

	ctx := p.loadContext("C1", "100.2", "")
	assert.Contains(t, ctx, "ask @Bob Brown about the rollout")
}
