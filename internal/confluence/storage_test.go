package confluence

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var update = flag.Bool("update", false, "rewrite golden files")

func TestStorageToSectionsGolden(t *testing.T) {
	files, _ := filepath.Glob("testdata/storage/*.xhtml")
	require.NotEmpty(t, files)
	for _, f := range files {
		t.Run(filepath.Base(f), func(t *testing.T) {
			raw, err := os.ReadFile(f)
			require.NoError(t, err)
			secs, users, keys := StorageToSections(string(raw), 1_000_000)
			got, err := json.MarshalIndent(map[string]any{"sections": secs, "userIDs": users, "jiraKeys": keys}, "", "  ")
			require.NoError(t, err)
			golden := strings.TrimSuffix(f, ".xhtml") + ".golden.json"
			if *update {
				require.NoError(t, os.WriteFile(golden, got, 0o644))
			}
			want, err := os.ReadFile(golden)
			require.NoError(t, err)
			assert.JSONEq(t, string(want), string(got))
		})
	}
}

func TestStorageCap(t *testing.T) {
	var b strings.Builder
	for i := 0; i < 3000; i++ {
		fmt.Fprintf(&b, "<p>paragraph %d with some words in it</p>", i)
	}
	secs, _, _ := StorageToSections(b.String(), 5000)
	total := 0
	for _, s := range secs {
		total += utf8.RuneCountInString(s.Text)
	}
	assert.LessOrEqual(t, total, 5000+len("[truncated]"))
	assert.Equal(t, "[truncated]", secs[len(secs)-1].Text)
}

func TestHeadingAnchor(t *testing.T) {
	assert.Equal(t, "Release-plan", HeadingAnchor("Release plan"))
	assert.Equal(t, "План-релиза", HeadingAnchor(" План  релиза "))
	assert.Equal(t, "Q3-goals", HeadingAnchor("Q3: goals!"))
}
