package cmd

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestConfluenceExtractPDFTextHelper: the hidden helper command prints the
// parse result the extractor reads, and needs no config.
func TestConfluenceExtractPDFTextHelper(t *testing.T) {
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs([]string{"extract-pdf-text", filepath.Join("..", "internal", "extract", "testdata", "sample.pdf")})
	t.Cleanup(func() { rootCmd.SetArgs(nil) })
	require.NoError(t, rootCmd.Execute())

	var res struct {
		OK    bool `json:"ok"`
		Pages []struct {
			Index int    `json:"index"`
			Text  string `json:"text"`
		} `json:"pages"`
	}
	require.NoError(t, json.Unmarshal(out.Bytes(), &res), out.String())
	assert.True(t, res.OK)
	require.Len(t, res.Pages, 1)
	assert.Equal(t, "Quarterly report: revenue grew twelve percent", res.Pages[0].Text)
	assert.True(t, extractPDFTextCmd.Hidden)
}
