package handlers

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestNudgeTableMatchesTheSharedFixture pins NudgeTable to the phone's effect
// table: the `action_effect_kinds` section of the shared contract fixture is
// read by the Kit's ActionEffectKinds test too, so a new handler nudge fails
// one side until both change (relay client Phase 4, latency samples).
func TestNudgeTableMatchesTheSharedFixture(t *testing.T) {
	raw, err := os.ReadFile("../../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f struct {
		ActionEffectKinds []struct {
			ActionKind string   `json:"action_kind"`
			SliceKinds []string `json:"slice_kinds"`
		} `json:"action_effect_kinds"`
	}
	require.NoError(t, json.Unmarshal(raw, &f))
	require.NotEmpty(t, f.ActionEffectKinds, "the fixture has an action_effect_kinds section")

	fixture := map[string][]string{}
	for _, c := range f.ActionEffectKinds {
		_, dup := fixture[c.ActionKind]
		require.False(t, dup, "%s listed twice", c.ActionKind)
		fixture[c.ActionKind] = c.SliceKinds
	}
	table := map[string][]string{}
	for kind, nudged := range NudgeTable {
		for _, s := range nudged {
			table[kind] = append(table[kind], string(s))
		}
	}
	require.Equal(t, table, fixture)
}
