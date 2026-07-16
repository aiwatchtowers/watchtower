package memory

import (
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// epNode builds an active short-tier episode with a ## Provenance section of
// the given channel_id + ts refs (the shape episodeBody renders).
func epNode(id, title, channel string, tss ...string) Node {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n## Story\n%s happened.\n\n## Outcome\n\n## Provenance\n", title, title)
	for _, ts := range tss {
		fmt.Fprintf(&b, "- %s %s\n", channel, ts)
	}
	return Node{ID: id, Type: "episode", Tier: "short", Status: "active", Title: title, Body: b.String()}
}

// TestDedupeMergesSharedProvenance: the E2E incident shape — two active short
// episodes in one channel with duplicate content but DIFFERENT titles, sharing
// a provenance ref → merged newer-into-older. Older wins; the newer becomes a
// tombstone the resolver chases back to the older.
func TestDedupeMergesSharedProvenance(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	older := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DA1", "Deploy freeze announced", "C1CHAN",
		"1752570000.000100", "1752570100.000200")
	newer := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DA2", "Release window locked", "C1CHAN",
		"1752570100.000200", "1752570200.000300") // shares the middle ref
	writeAndIndex(t, v, d, older)
	writeAndIndex(t, v, d, newer)

	merged, err := DedupeEpisodes(v, d, 20)
	require.NoError(t, err)
	assert.Equal(t, 1, merged)

	gotNewer, err := v.ReadNode(newer.ID)
	require.NoError(t, err)
	assert.Equal(t, "tombstone", gotNewer.Status, "newer episode becomes a tombstone")
	assert.Equal(t, older.ID, gotNewer.RedirectTo, "redirecting to the older winner")

	resolved, err := Resolve(v, d, newer.ID)
	require.NoError(t, err)
	assert.Equal(t, older.ID, resolved.ID, "resolver chases the newer id to the older")
}

// TestDedupeDisjointRefsNeverMerge: near-identical titles but ZERO shared
// provenance refs must NOT merge — title similarity is explicitly dead as a
// signal (spec §3, E2E-proven).
func TestDedupeDisjointRefsNeverMerge(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	a := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DB1", "Billing sync incident", "C2CHAN",
		"1752570000.000100", "1752570050.000100")
	b := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DB2", "Billing sync incident", "C2CHAN",
		"1752570040.000900", "1752570090.000900") // overlaps in time, shares no ref
	writeAndIndex(t, v, d, a)
	writeAndIndex(t, v, d, b)

	merged, err := DedupeEpisodes(v, d, 20)
	require.NoError(t, err)
	assert.Equal(t, 0, merged, "identical titles with disjoint refs do not merge")

	got, err := v.ReadNode(b.ID)
	require.NoError(t, err)
	assert.Equal(t, "active", got.Status)
}

// TestDedupeNeverCrossChannel: a ts value shared across two DIFFERENT channels
// is not a shared ref (the ref is keyed channel_id+ts) → never merged.
func TestDedupeNeverCrossChannel(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	a := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DC1", "Same ts here", "C3AAAA", "1752570000.000100")
	b := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DC2", "Same ts there", "C3BBBB", "1752570000.000100")
	writeAndIndex(t, v, d, a)
	writeAndIndex(t, v, d, b)

	merged, err := DedupeEpisodes(v, d, 20)
	require.NoError(t, err)
	assert.Equal(t, 0, merged, "same ts in different channels is not a shared ref")
}

// TestDedupeSkipsClosedAndLong: closed or long-tier episodes are never merged
// even with a shared ref.
func TestDedupeSkipsClosedAndLong(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	closedOld := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DD1", "Closed one", "C4CHAN", "1752570000.000100")
	closedOld.Status = "closed"
	activeNew := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DD2", "Active dup", "C4CHAN", "1752570000.000100")
	writeAndIndex(t, v, d, closedOld)
	writeAndIndex(t, v, d, activeNew)

	longOld := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DD3", "Long one", "C5CHAN", "1752571000.000100")
	longOld.Tier = "long"
	shortNew := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DD4", "Short dup", "C5CHAN", "1752571000.000100")
	writeAndIndex(t, v, d, longOld)
	writeAndIndex(t, v, d, shortNew)

	merged, err := DedupeEpisodes(v, d, 20)
	require.NoError(t, err)
	assert.Equal(t, 0, merged, "closed and long episodes are out of scope")

	for _, id := range []string{closedOld.ID, activeNew.ID, longOld.ID, shortNew.ID} {
		got, err := v.ReadNode(id)
		require.NoError(t, err)
		assert.NotEqual(t, "tombstone", got.Status, id)
	}
}

// TestDedupeCapRespected: with three merge-able pairs across three channels and
// a cap of one, only one merge happens per run.
func TestDedupeCapRespected(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	for i, ch := range []string{"C6AAAA", "C6BBBB", "C6CCCC"} {
		ts := fmt.Sprintf("17525720%02d.000100", i)
		older := epNode(fmt.Sprintf("ep_01ARZ3NDEKTSV4RRFFQ69G5DE%d", i*2+1), "older", ch, ts)
		newer := epNode(fmt.Sprintf("ep_01ARZ3NDEKTSV4RRFFQ69G5DE%d", i*2+2), "newer", ch, ts)
		writeAndIndex(t, v, d, older)
		writeAndIndex(t, v, d, newer)
	}

	merged, err := DedupeEpisodes(v, d, 1)
	require.NoError(t, err)
	assert.Equal(t, 1, merged, "cap of one stops after a single merge")

	tombstones := countTombstones(t, d)
	assert.Equal(t, 1, tombstones)
}

// TestDedupeProvenanceUnionPreserved: after a real duplicate (identical refs)
// merge, the winner retains every provenance ref — no ref is lost (MEM-07 spirit).
func TestDedupeProvenanceUnionPreserved(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	refs := []string{"1752570000.000100", "1752570100.000200", "1752570200.000300"}
	older := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DF1", "First extraction", "C7CHAN", refs...)
	newer := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DF2", "Retry extraction", "C7CHAN", refs...)
	writeAndIndex(t, v, d, older)
	writeAndIndex(t, v, d, newer)

	merged, err := DedupeEpisodes(v, d, 20)
	require.NoError(t, err)
	require.Equal(t, 1, merged)

	winner, err := Resolve(v, d, newer.ID)
	require.NoError(t, err)
	assert.Equal(t, older.ID, winner.ID)
	for _, ts := range refs {
		assert.Contains(t, winner.Body, "C7CHAN "+ts, "winner keeps provenance ref %s", ts)
	}
}

// TestDedupeUnionsPartialOverlapProvenance: when the loser carries provenance
// refs the winner lacks (a partial-overlap duplicate, not an identical retry),
// dedupe must append those loser-only refs to the winner's ## Provenance before
// the merge — no ref may be lost (MEM-07: provenance never thins). This is the
// non-identical-ref-set case the identical-refs test above cannot catch.
func TestDedupeUnionsPartialOverlapProvenance(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	older := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DG1", "First", "C8CHAN",
		"1752570000.000100", "1752570100.000200")
	newer := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DG2", "Second", "C8CHAN",
		"1752570100.000200", "1752570200.000300") // shares the middle ref, adds a tail ref
	writeAndIndex(t, v, d, older)
	writeAndIndex(t, v, d, newer)

	merged, err := DedupeEpisodes(v, d, 20)
	require.NoError(t, err)
	require.Equal(t, 1, merged)

	winner, err := Resolve(v, d, newer.ID)
	require.NoError(t, err)
	require.Equal(t, older.ID, winner.ID)
	// The winner keeps its own refs AND gains the loser-only ref via the union.
	for _, ts := range []string{"1752570000.000100", "1752570100.000200", "1752570200.000300"} {
		assert.Contains(t, winner.Body, "C8CHAN "+ts, "winner has provenance ref %s after union", ts)
	}
	assert.Contains(t, winner.Body, "## Provenance", "the union ref lives in the winner's Provenance section")
}

// countTombstones counts tombstone rows in the index.
func countTombstones(t *testing.T, d *db.DB) int {
	t.Helper()
	rows, err := d.ListMemoryNodes()
	require.NoError(t, err)
	n := 0
	for _, r := range rows {
		if r.Status == "tombstone" {
			n++
		}
	}
	return n
}
