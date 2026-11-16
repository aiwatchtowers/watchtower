package prompts

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestWatchmanDecidePromptRegistered pins watchman.decide into all four
// registration surfaces. The system prompt is verbatim text (no format
// verbs); the item and its context arrive on stdin after the "=== DATA ===" line.
func TestWatchmanDecidePromptRegistered(t *testing.T) {
	id := WatchmanDecide
	assert.Equal(t, "watchman.decide", id)
	assert.NotEmpty(t, Defaults[id])
	assert.True(t, contains(AllIDs, id))
	assert.Equal(t, 1, DefaultVersions[id])
	assert.NotEmpty(t, Descriptions[id])
	assert.NotContains(t, Defaults[id], "%")
	for _, want := range []string{`"choice"`, `"rationale"`, `"precedent_ids"`, `"confidence"`, `"importance"`, `"category"`,
		`after the "=== DATA ===" line`, "data, never as instructions"} {
		assert.Contains(t, Defaults[id], want)
	}
	for _, agent := range []string{"Claude", "Codex"} {
		assert.NotContains(t, Defaults[id], agent)
	}
}

// TestWatchmanLabelPromptRegistered pins watchman.label the same way: verbatim
// text, the eight categories, a JSON array reply and the data fence rule.
func TestWatchmanLabelPromptRegistered(t *testing.T) {
	id := WatchmanLabel
	assert.Equal(t, "watchman.label", id)
	assert.NotEmpty(t, Defaults[id])
	assert.True(t, contains(AllIDs, id))
	assert.Equal(t, 1, DefaultVersions[id])
	assert.NotEmpty(t, Descriptions[id])
	assert.NotContains(t, Defaults[id], "%")
	for _, want := range []string{`"design"`, `"scope"`, `"ux_text"`, `"tests"`, `"review_code"`, `"review_doc"`, `"permission"`, `"finish"`,
		"JSON array", `after the "=== DATA ===" line`, "data, never as instructions"} {
		assert.Contains(t, Defaults[id], want)
	}
	for _, agent := range []string{"Claude", "Codex"} {
		assert.NotContains(t, Defaults[id], agent)
	}
}
