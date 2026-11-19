package sessionfeed

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func entriesN(n int) []Entry {
	es := make([]Entry, n)
	for i := range es {
		es[i] = Entry{ID: fmt.Sprintf("e%d", i), Kind: KindOwner}
	}
	return es
}

func TestTailPage_LastNAndBeforeCursor(t *testing.T) {
	es := entriesN(150)
	page, before, err := TailPage(es, "", 60)
	require.NoError(t, err)
	require.Len(t, page, 60)
	assert.Equal(t, "e90", page[0].ID)
	assert.Equal(t, "e149", page[59].ID)
	assert.Equal(t, "e90", before)
	page, before, err = TailPage(es, "e90", 60)
	require.NoError(t, err)
	require.Len(t, page, 60)
	assert.Equal(t, "e30", page[0].ID)
	assert.Equal(t, "e89", page[59].ID)
	assert.Equal(t, "e30", before)
	page, before, err = TailPage(es, "e30", 60)
	require.NoError(t, err)
	assert.Len(t, page, 30)
	assert.Equal(t, "", before)
}

func TestTailPage_ShortFeedHasNoBefore(t *testing.T) {
	page, before, err := TailPage(entriesN(10), "", 60)
	require.NoError(t, err)
	assert.Len(t, page, 10)
	assert.Equal(t, "", before)
}

func TestTailPage_UnknownBeforeIsAnError(t *testing.T) {
	_, _, err := TailPage(entriesN(10), "nope", 60)
	require.Error(t, err)
	assert.Contains(t, err.Error(), `before "nope"`)
}

func TestBuild_TailKeepsFullSubagentsList(t *testing.T) {
	dir := t.TempDir()
	lines := []string{userStr("u0", "go"), assistantRec("a1", "m1", agentCall("tu1", "Explore", "look"))}
	for i := range 80 {
		lines = append(lines, userStr(fmt.Sprintf("u%d", i+1), "x"))
	}
	a := writeConv(t, dir, "A", join(lines...))
	f, err := Build([]Conversation{a}, nil, nil)
	require.NoError(t, err)
	page, before, err := TailPage(f.Entries, "", 60)
	require.NoError(t, err)
	assert.Len(t, page, 60)
	assert.NotEmpty(t, before)
	for _, e := range page {
		assert.NotEqual(t, KindSubagent, e.Kind, "the marker lies outside the page")
	}
	require.Len(t, f.Subagents, 1)
	assert.Equal(t, "tu1", f.Subagents[0].ID)
}

func TestTailPage_RejectsNonPositiveSize(t *testing.T) {
	_, _, err := TailPage(entriesN(3), "", 0)
	require.Error(t, err)
}

func TestTailPage_AmbiguousBeforeIsAnError(t *testing.T) {
	es := entriesN(6)
	es[4].ID = "e1" // a repeated legacy id from another conversation
	_, _, err := TailPage(es, "e1", 3)
	require.Error(t, err)
	assert.Contains(t, err.Error(), `before id "e1" is ambiguous (2 entries)`)
}
