package watchman

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLabel_ParsesFlags(t *testing.T) {
	g := &labelGen{reply: func(int) string {
		return `[{"category": "scope", "decision": true, "parked": false}, {"category": "", "decision": false, "parked": true}]`
	}}
	got, err := NewLLMLabeler(g, nil).Label(context.Background(), []LabelItem{{Situation: "a", NeedCategory: true}, {Situation: "b"}})
	require.NoError(t, err)
	assert.Equal(t, []Label{
		{Category: CategoryScope, Decision: wmBool(true), Parked: wmBool(false)},
		{Decision: wmBool(false), Parked: wmBool(true)},
	}, got)
	assert.Contains(t, g.users[0], `"need_category":true`, "the model sees which items need a category")
}

func TestLabel_MissingFlagsAreNil(t *testing.T) {
	g := &labelGen{reply: func(int) string { return `[{"category":"design"}]` }}
	got, err := NewLLMLabeler(g, nil).Label(context.Background(), []LabelItem{{Situation: "a", NeedCategory: true}})
	require.NoError(t, err)
	assert.Equal(t, []Label{{Category: CategoryDesign}}, got)
}

// The v1 reply shape (an array of strings) cannot carry the flags: the
// batch comes back unlabelled, as any wrong-shaped reply.
func TestLabel_OldArrayOfStringsIsUnlabelled(t *testing.T) {
	g := &labelGen{reply: func(int) string { return `["scope", "design"]` }}
	got, err := NewLLMLabeler(g, nil).Label(context.Background(), []LabelItem{{Situation: "a", NeedCategory: true}, {Situation: "b", NeedCategory: true}})
	require.NoError(t, err)
	assert.Equal(t, []Label{{}, {}}, got)
}
