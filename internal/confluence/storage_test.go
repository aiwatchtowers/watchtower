package confluence

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
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

// TestStorageCDATANoLeak is an explicit, narrower belt-and-suspenders pin
// alongside the golden exact-text check: no rendered section may ever
// contain the CDATA close delimiter or an HTML comment close delimiter,
// which is exactly what leaked into the output before escapeCDATASections
// (a CDATA body containing '>' was misparsed as a "bogus comment" ending at
// that '>', not at "]]>", so the literal "]]>" tail and stray "-->" markers
// from the resulting tag soup used to survive into the section text).
func TestStorageCDATANoLeak(t *testing.T) {
	raw, err := os.ReadFile("testdata/storage/cdata.xhtml")
	require.NoError(t, err)
	secs, _, _ := StorageToSections(string(raw), 1_000_000)
	require.NotEmpty(t, secs)
	for _, s := range secs {
		assert.NotContains(t, s.Text, "]]>")
		assert.NotContains(t, s.Text, "-->")
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

// A mention renders as the exact token internal/kb resolves at index time:
// kb does not import this package (controller ruling R3), so it matches the
// token with its own copy of this regexp (extMention in
// internal/kb/source_ext.go) — keep the two identical.
func TestMentionTokenMatchesKBPattern(t *testing.T) {
	kbPattern := regexp.MustCompile(`^@\[~([^\]]+)\]$`)
	sections, users, _ := StorageToSections(
		`<p><ac:link><ri:user ri:account-id="5b10:abc-123" /></ac:link></p>`, 1000)
	require.Len(t, sections, 1)
	require.Equal(t, []string{"5b10:abc-123"}, users)
	m := kbPattern.FindStringSubmatch(strings.TrimSpace(sections[0].Text))
	require.NotNil(t, m, "token %q must match kb's mention pattern", sections[0].Text)
	assert.Equal(t, "5b10:abc-123", m[1])
}
