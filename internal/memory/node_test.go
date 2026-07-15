package memory

import (
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// goldenNode is the canonical on-disk form of a fully-populated entity node.
// Render must reproduce it byte-for-byte.
const goldenNode = `---
id: ent_01ARZ3NDEKTSV4RRFFQ69G5FAV
type: entity
tier: long
status: active
aliases: ["billing-v2", "C0123ABC"]
refs:
  people_card: 42
  targets: [7, 13]
---
# Billing v2

## What

The billing revamp project.

## Links

- [[ep_01ARZ3NDEKTSV4RRFFQ69G5FB0|kickoff]]
- [[ent_01ARZ3NDEKTSV4RRFFQ69G5FB1]]
`

func TestParseNodeGolden(t *testing.T) {
	n, err := ParseNode([]byte(goldenNode))
	require.NoError(t, err)

	assert.Equal(t, "ent_01ARZ3NDEKTSV4RRFFQ69G5FAV", n.ID)
	assert.Equal(t, "entity", n.Type)
	assert.Equal(t, "long", n.Tier)
	assert.Equal(t, "active", n.Status)
	assert.Empty(t, n.RedirectTo)
	assert.Equal(t, "Billing v2", n.Title)
	assert.Equal(t, []string{"billing-v2", "C0123ABC"}, n.Aliases)
	assert.Equal(t, int64(42), n.Refs.PeopleCard)
	assert.Equal(t, []int64{7, 13}, n.Refs.Targets)
	assert.True(t, strings.HasPrefix(n.Body, "# Billing v2\n"), "body must start at the H1, got %q", n.Body)
}

func TestRenderGoldenRoundTrip(t *testing.T) {
	n, err := ParseNode([]byte(goldenNode))
	require.NoError(t, err)

	rendered := n.Render()
	assert.Equal(t, goldenNode, string(rendered))

	again, err := ParseNode(rendered)
	require.NoError(t, err)
	assert.Equal(t, n, again)
}

func TestRenderMinimalRoundTrip(t *testing.T) {
	n := Node{
		ID:     "ep_01ARZ3NDEKTSV4RRFFQ69G5FAV",
		Type:   "episode",
		Tier:   "short",
		Status: "active",
		Title:  "Kickoff",
		Body:   "# Kickoff\n\n## Story\n\nWe met and agreed on scope.\n",
	}

	again, err := ParseNode(n.Render())
	require.NoError(t, err)
	assert.Equal(t, n, again)
}

func TestRenderTombstoneRoundTrip(t *testing.T) {
	n := Node{
		ID:         "ent_01ARZ3NDEKTSV4RRFFQ69G5FA0",
		Type:       "entity",
		Tier:       "long",
		Status:     "tombstone",
		RedirectTo: "ent_01ARZ3NDEKTSV4RRFFQ69G5FA1",
		Title:      "Old name",
		Body:       "# Old name\n\nMerged into [[ent_01ARZ3NDEKTSV4RRFFQ69G5FA1]].\n",
	}

	raw := n.Render()
	assert.Contains(t, string(raw), "redirect_to: ent_01ARZ3NDEKTSV4RRFFQ69G5FA1\n")

	again, err := ParseNode(raw)
	require.NoError(t, err)
	assert.Equal(t, n, again)
}

func TestParseNodeTitleFromFirstH1(t *testing.T) {
	raw := "---\nid: ep_x\ntype: episode\ntier: short\nstatus: active\n---\nIntro line before heading.\n\n# The Real Title\n\n## Story\n\ntext\n"
	n, err := ParseNode([]byte(raw))
	require.NoError(t, err)
	assert.Equal(t, "The Real Title", n.Title)
}

func TestParseNodeNoH1(t *testing.T) {
	raw := "---\nid: ep_x\ntype: episode\ntier: short\nstatus: active\n---\nNo heading here.\n"
	n, err := ParseNode([]byte(raw))
	require.NoError(t, err)
	assert.Empty(t, n.Title)
}

func TestParseNodeRejectsInvalidFields(t *testing.T) {
	cases := []struct {
		name              string
		typ, tier, status string
	}{
		{"invalid type", "person", "long", "active"},
		{"invalid tier", "entity", "medium", "active"},
		{"invalid status", "entity", "long", "archived"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			doc := "---\nid: ent_x\ntype: " + tc.typ + "\ntier: " + tc.tier + "\nstatus: " + tc.status + "\n---\n# X\n"
			_, err := ParseNode([]byte(doc))
			require.Error(t, err)
		})
	}
}

func TestParseNodeRejectsUnknownKey(t *testing.T) {
	raw := "---\nid: ent_x\ntype: entity\ntier: long\nstatus: active\ncolor: blue\n---\n# X\n"
	_, err := ParseNode([]byte(raw))
	require.Error(t, err)
}

func TestParseNodeRejectsMissingID(t *testing.T) {
	raw := "---\ntype: entity\ntier: long\nstatus: active\n---\n# X\n"
	_, err := ParseNode([]byte(raw))
	require.Error(t, err)
}

func TestParseNodeRejectsMissingFrontmatter(t *testing.T) {
	_, err := ParseNode([]byte("# Just markdown\n"))
	require.Error(t, err)
}

func TestParseNodeRejectsRedirectOnNonTombstone(t *testing.T) {
	raw := "---\nid: ent_x\ntype: entity\ntier: long\nstatus: active\nredirect_to: ent_y\n---\n# X\n"
	_, err := ParseNode([]byte(raw))
	require.Error(t, err)
}

func TestLinks(t *testing.T) {
	n := Node{Body: "# T\n\nSee [[ep_a|the kickoff]] and [[ent_b]].\n\n- [[sum_c|Q3 rollup]]\n"}
	links := n.Links()
	assert.Equal(t, []Link{
		{ID: "ep_a", Label: "the kickoff"},
		{ID: "ent_b"},
		{ID: "sum_c", Label: "Q3 rollup"},
	}, links)
}

func TestLinksNone(t *testing.T) {
	n := Node{Body: "# T\n\nNo links, not even [single] brackets.\n"}
	assert.Empty(t, n.Links())
}

func TestNewIDPrefixes(t *testing.T) {
	cases := map[string]string{
		"entity":  "ent_",
		"episode": "ep_",
		"rollup":  "sum_",
		"belief":  "bel_",
	}
	for kind, prefix := range cases {
		id := NewID(kind)
		assert.True(t, strings.HasPrefix(id, prefix), "NewID(%q) = %q, want prefix %q", kind, id, prefix)
		ulid := strings.TrimPrefix(id, prefix)
		assert.Len(t, ulid, 26)
		for _, c := range ulid {
			assert.Contains(t, crockfordAlphabet, string(c))
		}
	}
}

func TestNewIDUnknownKindPanics(t *testing.T) {
	require.Panics(t, func() { NewID("widget") })
}

func TestULIDSortable(t *testing.T) {
	t1 := time.Date(2026, 7, 15, 10, 0, 0, 0, time.UTC)
	t2 := t1.Add(time.Millisecond)
	for i := 0; i < 100; i++ {
		a, b := newULID(t1), newULID(t2)
		require.Less(t, a, b, "ULID at earlier ms must sort before later ms")
	}
}

func TestULIDUnique(t *testing.T) {
	seen := make(map[string]bool)
	for i := 0; i < 1000; i++ {
		id := NewID("entity")
		require.False(t, seen[id], "duplicate ID %q", id)
		seen[id] = true
	}
}
