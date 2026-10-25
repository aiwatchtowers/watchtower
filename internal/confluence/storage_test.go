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

	"watchtower/internal/extsync"
)

var update = flag.Bool("update", false, "rewrite golden files")

func TestStorageToSectionsGolden(t *testing.T) {
	files, _ := filepath.Glob("testdata/storage/*.xhtml")
	require.NotEmpty(t, files)
	for _, f := range files {
		t.Run(filepath.Base(f), func(t *testing.T) {
			raw, err := os.ReadFile(f)
			require.NoError(t, err)
			secs, users, keys, _ := StorageToSections(string(raw), 1_000_000)
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
	secs, _, _, _ := StorageToSections(string(raw), 1_000_000)
	require.NotEmpty(t, secs)
	for _, s := range secs {
		assert.NotContains(t, s.Text, "]]>")
		assert.NotContains(t, s.Text, "-->")
	}
}

func TestStorageCap(t *testing.T) {
	var b strings.Builder
	for i := range 3000 {
		fmt.Fprintf(&b, "<p>paragraph %d with some words in it</p>", i)
	}
	secs, _, _, _ := StorageToSections(b.String(), 5000)
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
	sections, users, _, _ := StorageToSections(
		`<p><ac:link><ri:user ri:account-id="5b10:abc-123" /></ac:link></p>`, 1000)
	require.Len(t, sections, 1)
	require.Equal(t, []string{"5b10:abc-123"}, users)
	m := kbPattern.FindStringSubmatch(strings.TrimSpace(sections[0].Text))
	require.NotNil(t, m, "token %q must match kb's mention pattern", sections[0].Text)
	assert.Equal(t, "5b10:abc-123", m[1])
}

// TestStorageDateLozenge pins that a Confluence date lozenge renders its
// datetime attribute, and that the rest of the surrounding phrase survives:
// <time /> is not a void element in HTML5, so left un-rewritten by
// normalizeSelfClosing it stays open and swallows everything after it as
// its own children, losing both the date and the following text.
func TestStorageDateLozenge(t *testing.T) {
	sections, _, _, err := StorageToSections(`<p>Due <time datetime="2026-09-01" /> ship it.</p>`, 1000)
	require.NoError(t, err)
	require.Len(t, sections, 1)
	assert.Equal(t, "Due 2026-09-01 ship it.", sections[0].Text)
}

// TestStorageStatusMacroLabel pins that a body-less status-lozenge macro
// (ac:parameter children only, no ac:rich-text-body/ac:plain-text-body)
// renders its title parameter instead of an empty string.
func TestStorageStatusMacroLabel(t *testing.T) {
	sections, _, _, err := StorageToSections(
		`<p>State: <ac:structured-macro ac:name="status">`+
			`<ac:parameter ac:name="colour">Green</ac:parameter>`+
			`<ac:parameter ac:name="title">DONE</ac:parameter>`+
			`</ac:structured-macro></p>`, 1000)
	require.NoError(t, err)
	require.Len(t, sections, 1)
	assert.Equal(t, "State: DONE", sections[0].Text)
}

// TestStorageFallbackScansJiraKeys pins that a document too deep for the
// tree builder still links its plain-text Jira mentions: the fallback path
// used to return jiraKeys=nil unconditionally, so a page like this would
// silently drop out of doc_links even though its raw text names a key.
func TestStorageFallbackScansJiraKeys(t *testing.T) {
	body := strings.Repeat("<div>", 600) + "See PROJ-42 for details"
	sections, users, keys, err := StorageToSections(body, maxBodyRunes)
	require.Error(t, err, "600 levels of nesting must overflow the tree builder's 512-node stack")
	require.Len(t, sections, 1)
	assert.Contains(t, sections[0].Text, "PROJ-42")
	assert.Nil(t, users, "the fallback strip parses no ac:link/ri:user element, so it can never find a mention")
	assert.Equal(t, []string{"PROJ-42"}, keys)
}

// TestStorageMedia pins what a page records: its attachment and external
// images and its public links, each anchored at its enclosing heading; an
// external image or link Fetchable refuses (a signed URL, the synced
// Atlassian site, mailto, an in-page anchor) and another page's attachment
// are never recorded.
func TestStorageMedia(t *testing.T) {
	raw, err := os.ReadFile("testdata/storage/media.xhtml")
	require.NoError(t, err)
	got := StorageMedia(string(raw))
	assert.Equal(t, []extsync.MediaRef{
		{Kind: "link", Locator: "url:https://example.com/guide", URL: "https://example.com/guide?utm_source=x"},
		{Kind: "image", Locator: "att:chart.png", Name: "chart.png"},
		{Kind: "image", Locator: "url:https://images.example.org/diagram.png", URL: "https://images.example.org/diagram.png", Anchor: "Release-plan"},
		{Kind: "link", Locator: "url:https://docs.example.net/spec", URL: "https://docs.example.net/spec", Anchor: "Release-plan"},
		{Kind: "image", Locator: "att:table shot.png", Name: "table shot.png", Anchor: "Release-plan"},
	}, got)

	// One image named twice records once, at its first place.
	twice := StorageMedia(`<p><ac:image><ri:attachment ri:filename="a.png" /></ac:image></p>` +
		`<h1>Later</h1><p><ac:image><ri:attachment ri:filename="a.png" /></ac:image></p>`)
	assert.Equal(t, []extsync.MediaRef{{Kind: "image", Locator: "att:a.png", Name: "a.png"}}, twice)

	// An image inside a heading belongs to that heading's section.
	inHeading := StorageMedia(`<p>x</p><h2>Shot <ac:image><ri:attachment ri:filename="h.png" /></ac:image></h2>`)
	assert.Equal(t, []extsync.MediaRef{{Kind: "image", Locator: "att:h.png", Name: "h.png", Anchor: "Shot"}}, inHeading)
}

// TestStorageToSections_Unchanged pins that recording media changed no
// text: every fixture (media.xhtml's golden was written before the media
// walk existed) still converts byte-identically, through StorageToSections
// and through the one walk the fetcher runs for text and media together.
func TestStorageToSections_Unchanged(t *testing.T) {
	files, _ := filepath.Glob("testdata/storage/*.xhtml")
	require.NotEmpty(t, files)
	for _, f := range files {
		t.Run(filepath.Base(f), func(t *testing.T) {
			raw, err := os.ReadFile(f)
			require.NoError(t, err)
			want, err := os.ReadFile(strings.TrimSuffix(f, ".xhtml") + ".golden.json")
			require.NoError(t, err)
			var golden struct {
				Sections []extsync.Section `json:"sections"`
			}
			require.NoError(t, json.Unmarshal(want, &golden))
			wantJSON, err := json.Marshal(golden.Sections)
			require.NoError(t, err)

			secs, _, _, _ := StorageToSections(string(raw), 1_000_000)
			gotJSON, err := json.Marshal(secs)
			require.NoError(t, err)
			assert.Equal(t, string(wantJSON), string(gotJSON))

			conv := convertStorage(string(raw), 1_000_000)
			walkJSON, err := json.Marshal(conv.sections)
			require.NoError(t, err)
			assert.Equal(t, string(wantJSON), string(walkJSON))
		})
	}
}

// A ref whose section the body cap cut off is anchored at the page (no
// anchor): an anchor always names a stored section.
func TestStorageMedia_AnchorOnlyAtKeptSections(t *testing.T) {
	body := `<h2>Kept</h2><p>short <ac:image><ri:attachment ri:filename="k.png" /></ac:image></p>` +
		`<h2>Cut</h2><p>` + strings.Repeat("long text ", 50) + `<a href="https://example.com/c">c</a></p>`
	r := convertStorage(body, 10) // "Kept\nshort" fits; "Cut" is dropped whole
	require.Equal(t, "[truncated]", r.sections[len(r.sections)-1].Text)
	assert.Equal(t, []extsync.MediaRef{
		{Kind: "image", Locator: "att:k.png", Name: "k.png", Anchor: "Kept"},
		{Kind: "link", Locator: "url:https://example.com/c", URL: "https://example.com/c"},
	}, r.media)
}
