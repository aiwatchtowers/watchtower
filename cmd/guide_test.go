package cmd

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func runGuide(t *testing.T, args ...string) string {
	t.Helper()
	var out bytes.Buffer
	guideCmd.SetOut(&out)
	t.Cleanup(func() {
		guideCmd.SetOut(nil)
		guideSearchLimit = 5
	})
	c, rest, err := guideCmd.Find(args)
	require.NoError(t, err)
	require.NoError(t, c.ParseFlags(rest))
	c.SetOut(&out)
	t.Cleanup(func() { c.SetOut(nil) })
	require.NoError(t, c.RunE(c, c.Flags().Args()))
	return out.String()
}

func TestGuideIndexJSONKeys(t *testing.T) {
	out := runGuide(t, "index", "--json")
	var got map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	assert.Len(t, got, 4)
	for _, k := range []string{"version", "base_url", "catalog", "sections"} {
		assert.Contains(t, got, k)
	}
	assert.Equal(t, Version, got["version"])
	assert.Regexp(t, `/blob/v`+Version+`/docs/guide/$`, got["base_url"])
	secs, ok := got["sections"].([]any)
	require.True(t, ok)
	require.NotEmpty(t, secs)
	sec := secs[0].(map[string]any)
	assert.Len(t, sec, 6)
	for _, k := range []string{"page", "page_title", "heading", "anchor", "level", "text"} {
		assert.Contains(t, sec, k)
	}
}

func TestGuideSearchLimit(t *testing.T) {
	out := runGuide(t, "search", "--json", "--limit", "2", "slack")
	var got struct {
		Sections []map[string]any `json:"sections"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	assert.NotEmpty(t, got.Sections)
	assert.LessOrEqual(t, len(got.Sections), 2)
}

func TestGuideCatalog(t *testing.T) {
	assert.NotEmpty(t, runGuide(t, "catalog"))
}
