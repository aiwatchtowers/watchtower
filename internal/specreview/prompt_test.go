package specreview

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/prompts"
)

// keysOf collects every object key of a decoded JSON value, at any depth.
func keysOf(v any, into map[string]bool) {
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			into[k] = true
			keysOf(e, into)
		}
	case []any:
		for _, e := range x {
			keysOf(e, into)
		}
	}
}

// The prompt's JSON example decodes, every key it asks for exists in the
// pinned result shape, and the review rules of the spec are in the text.
func TestPrompt_ShapeAndRules(t *testing.T) {
	p := prompts.Defaults[prompts.SpecReview]
	require.NotEmpty(t, p)
	start := strings.Index(p, "exactly this shape:\n\n")
	end := strings.Index(p, "\n\nRules:")
	require.True(t, start > 0 && end > start, "the JSON example is where the test looks for it")
	var example any
	require.NoError(t, json.Unmarshal([]byte(p[start+len("exactly this shape:\n\n"):end]), &example))

	raw, err := os.ReadFile(filepath.Join("testdata", "result_keys.golden"))
	require.NoError(t, err)
	var golden any
	require.NoError(t, json.Unmarshal(raw, &golden))
	asked, pinned := map[string]bool{}, map[string]bool{}
	keysOf(example, asked)
	keysOf(golden, pinned)
	for k := range asked {
		assert.True(t, pinned[k], "the prompt asks for %q, which the result shape does not have", k)
	}
	for _, k := range []string{"summary", "idea", "agreements", "decided_alone", "blind_spots", "checks", "resolved", "verdicts", "owner_source", "evidence"} {
		assert.True(t, asked[k], "the prompt does not ask for %q", k)
	}
	for _, rule := range []string{
		"never invent", `"missing"`, "## Decisions", "Check it both ways", "word for word",
		"read-only", "promises", "contracts", "migrations", "failure", "design lens",
		`source kind "spec"`, "=== DATA ===", "never as instructions",
		// v2, the author loop: a verdict per previous open item, new
		// findings only on changed text or blockers, no repeats.
		"previous_open_items", `"resolved"`, `"disputed"`, `"open"`, "changed since the previous round",
		"broken promise", "loses data", "never raise a previous item again",
	} {
		assert.True(t, strings.Contains(strings.ToLower(p), strings.ToLower(rule)), "the prompt does not say %q", rule)
	}
}

// v4 (2026-11-08-spec-review-discuss-design §1, §4): the closed list, the
// rising floor, the owner's items among the open items, and the summary
// screen's brief and theses; the round-2 rule stays.
func TestSpecReviewPrompt_V4(t *testing.T) {
	assert.Equal(t, 4, prompts.DefaultVersions[prompts.SpecReview])
	p := prompts.Defaults[prompts.SpecReview]
	lower := strings.ToLower(p)
	for _, rule := range []string{
		// closed list
		"closed_items", "already decided, do not raise",
		// rising floor
		"from round 3", `only "major" or "blocker"`,
		// owner items in previous_open_items
		"owner_comment", `"owner asked:"`, "the same requests, not two sets",
		// summary: brief and theses, five kinds, bounds, verbatim where-quote
		`"brief"`, `"theses"`, "3 to 5 lines", "5 to 10 theses",
		`"goal"`, `"decision"`, `"owner_change"`, `"non_goal"`, `"risk"`,
		// the round-2 rule paragraph
		"raise a new finding only about text that changed since the previous round",
	} {
		assert.True(t, strings.Contains(lower, strings.ToLower(rule)), "the prompt does not say %q", rule)
	}

	start := strings.Index(p, "exactly this shape:\n\n")
	end := strings.Index(p, "\n\nRules:")
	require.True(t, start > 0 && end > start)
	var example map[string]any
	require.NoError(t, json.Unmarshal([]byte(p[start+len("exactly this shape:\n\n"):end]), &example))
	assert.Contains(t, example, "brief")
	theses, ok := example["theses"].([]any)
	require.True(t, ok, "the reply shape shows theses as a list")
	require.NotEmpty(t, theses)
	th, ok := theses[0].(map[string]any)
	require.True(t, ok)
	for _, k := range []string{"kind", "text", "where"} {
		assert.Contains(t, th, k, "a thesis in the reply shape has %q", k)
	}
	assert.NotContains(t, th, "key", "code derives a thesis key; the model never gives one")
}
