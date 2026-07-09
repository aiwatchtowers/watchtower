package inbox

import (
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/prompts"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestPipeline_SetPromptStore_Assigns(t *testing.T) {
	p := &Pipeline{}
	store := &prompts.Store{}
	p.SetPromptStore(store)
	assert.Same(t, store, p.promptStore)
}

func TestPipeline_AccumulatedUsage_ZeroByDefault(t *testing.T) {
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
	d, p, _ := newTriagePipeline(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U3", Name: "bob", DisplayName: "Bob Brown"}))
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "ask <@U3> about the rollout")
	insertMessage(t, d, "C1", "100.2", "U2", "any update?")

	ctx := p.loadContext("C1", "100.2", "")
	assert.Contains(t, ctx, "ask @Bob Brown about the rollout")
}

func TestPipeline_AccumulatedUsage_AfterUpdate(t *testing.T) {
	p := &Pipeline{
		totalInputTokens:  10,
		totalOutputTokens: 20,
		totalAPITokens:    30,
	}
	in, out, cost, total := p.AccumulatedUsage()
	assert.Equal(t, 10, in)
	assert.Equal(t, 20, out)
	assert.Equal(t, float64(0), cost)
	assert.Equal(t, 30, total)
}
