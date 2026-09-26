package kb

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestNormalize_FoldsYo(t *testing.T) {
	assert.Equal(t, "Договоренность ее", Normalize("Договорённость её"))
	assert.Equal(t, "ЕЖ", Normalize("ЁЖ"))
}

func TestResolveSlackMarkup(t *testing.T) {
	names := map[string]string{"U1": "Anna"}
	lookup := func(id string) string { return names[id] }
	in := "hi <@U1>, see <#C9|general> and <https://x.io/a|the doc> or <https://y.io> <!here> <@U404>"
	got := ResolveSlackMarkup(in, lookup)
	assert.Equal(t, "hi @Anna, see #general and the doc (https://x.io/a) or https://y.io @here @U404", got)
}

func TestResolveSlackMarkup_LabelledMentionKeepsLabel(t *testing.T) {
	got := ResolveSlackMarkup("ping <@U2|Bob>", func(string) string { return "" })
	assert.Equal(t, "ping @Bob", got)
}

func TestResolveSlackMarkup_MailtoLinks(t *testing.T) {
	lookup := func(string) string { return "" }
	got := ResolveSlackMarkup("contact <mailto:jane@x.io|Jane Doe> for details", lookup)
	assert.Equal(t, "contact Jane Doe (jane@x.io) for details", got)

	got = ResolveSlackMarkup("reach <mailto:jane@x.io>", lookup)
	assert.Equal(t, "reach jane@x.io", got)
}

func TestJSONTexts(t *testing.T) {
	raw := `[{"text":"Split releases","by":"@v","message_ts":"1.2","importance":"medium"},` +
		`{"text":"Second","status":"open"}]`
	assert.Equal(t, []string{"Split releases", "Second"}, jsonTexts(raw))
	recap := `{"summary":"Sync","key_decisions":["A","B"],"action_items":[{"text":"do X","assignee":"@a"}],"n":3}`
	assert.Equal(t, []string{"Sync", "A", "B", "do X"}, jsonTexts(recap))
	assert.Nil(t, jsonTexts(""))
	assert.Nil(t, jsonTexts("null"))
	assert.Nil(t, jsonTexts("{not json"))
}

func TestParseTime(t *testing.T) {
	cases := map[string]string{
		"2026-04-20T09:37:38.027+0100": "2026-04-20T08:37:38Z",
		"2026-07-22T17:01:54Z":         "2026-07-22T17:01:54Z",
		"2026-09-11":                   "2026-09-11T00:00:00Z",
		"2026-09-11 10:00:00":          "2026-09-11T10:00:00Z",
	}
	for in, want := range cases {
		assert.Equal(t, want, parseTime(in).UTC().Truncate(time.Second).Format(time.RFC3339), in)
	}
	assert.True(t, parseTime("").IsZero())
	assert.True(t, parseTime("garbage").IsZero())
}
