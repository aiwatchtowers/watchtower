package catchup

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestParseCompose_TolerantOfFences(t *testing.T) {
	raw := "```json\n{\"tldr\":\"x\",\"topics\":[{\"title\":\"T\",\"narrative\":\"n\",\"priority\":\"high\",\"refs\":[\"digests#1\"]}]}\n```"
	res, err := parseCompose(raw)
	require.NoError(t, err)
	assert.Equal(t, "x", res.TLDR)
	require.Len(t, res.Topics, 1)
	assert.Equal(t, []string{"digests#1"}, res.Topics[0].Refs)
}

func TestValidateBody_DropsInventedRefsAndEmptyEntries(t *testing.T) {
	known := map[refKey]db.CatchupItem{
		{"digests", 1}: {Area: "digests", ID: 1, Title: "#eng"},
		{"inbox", 7}:   {Area: "inbox", ID: 7, Title: "mention"},
	}
	res := composeResult{
		Topics: []rawTopic{
			{Title: "ok", Narrative: "n", Priority: "urgent", Refs: []string{"digests#1", "digests#999", "garbage"}},
			{Title: "ghost", Narrative: "n", Priority: "low", Refs: []string{"tracks#5"}},
		},
		Decisions: []rawEntry{{Text: "d", Refs: []string{"decisions#2"}}},
		NeedsYou:  []rawNeed{{Text: "ping", Kind: "poke", Refs: []string{"inbox#7"}}},
	}
	body, rejected := validateBody(res, known)
	require.Len(t, body.Topics, 1)
	assert.Equal(t, "medium", body.Topics[0].Priority, "unknown priority → medium")
	assert.Equal(t, []db.CatchupRef{{Area: "digests", ID: 1, Label: "#eng"}}, body.Topics[0].Refs, "label filled from the gathered item")
	assert.Empty(t, body.Decisions, "entry with no valid refs is dropped")
	require.Len(t, body.NeedsYou, 1)
	assert.Equal(t, "mention", body.NeedsYou[0].Kind, "unknown kind → mention")
	assert.Equal(t, 4, rejected, "digests#999, garbage, tracks#5, decisions#2")
}

func TestBodyIsEmptyAndRoundTrip(t *testing.T) {
	assert.True(t, Body{}.IsEmpty())
	b := Body{Topics: []Topic{{Title: "t", Refs: []db.CatchupRef{{Area: "digests", ID: 1}}}}}
	assert.False(t, b.IsEmpty())
	raw, err := json.Marshal(b)
	require.NoError(t, err)
	assert.Contains(t, string(raw), `"needs_you":[]`, "arrays marshal as [] not null")
	var back Body
	require.NoError(t, json.Unmarshal(raw, &back))
	assert.Equal(t, b.Topics[0].Title, back.Topics[0].Title)
}

func TestParseRefTag(t *testing.T) {
	k, ok := parseRefTag("[inbox#12]")
	assert.True(t, ok)
	assert.Equal(t, refKey{"inbox", 12}, k)
	_, ok = parseRefTag("inbox#x")
	assert.False(t, ok)
	_, ok = parseRefTag("briefings#1")
	assert.False(t, ok, "not a recap area")
}
