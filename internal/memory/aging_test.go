package memory

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// agingEpNode builds an active short-tier episode whose newest provenance event
// is ageDays old, with the given aliases.
func agingEpNode(t *testing.T, id, channel string, ageDays int, aliases ...string) Node {
	t.Helper()
	base := time.Now().AddDate(0, 0, -ageDays).Unix()
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n## Story\ns\n\n## Provenance\n- %s %d.000100\n", id, channel, base)
	return Node{ID: id, Type: "episode", Tier: "short", Status: "active", Title: id, Aliases: aliases, Body: b.String()}
}

// TestAgeEpisodesTransitionsOldRawEpisodes is the fix-1 guard: an active short
// NON-situation episode older than the age window becomes closed+long (the
// eviction lifecycle can only start once it is closed); a recent episode and a
// situation-aliased episode are both left byte-identical (their lifecycle
// belongs to ingest, not the aging pass).
func TestAgeEpisodesTransitionsOldRawEpisodes(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	old := agingEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5AG1", "C1CHAN", 30)
	recent := agingEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5AG2", "C2CHAN", 3)
	sit := agingEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5AG3", "C3CHAN", 30, "situation:77")
	writeAndIndex(t, v, d, old)
	writeAndIndex(t, v, d, recent)
	writeAndIndex(t, v, d, sit)
	sitBefore, err := v.ReadNode(sit.ID)
	require.NoError(t, err)

	aged, err := AgeEpisodes(v, d, 14, time.Now(), t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 1, aged, "only the old raw episode ages")

	gotOld, err := v.ReadNode(old.ID)
	require.NoError(t, err)
	assert.Equal(t, "closed", gotOld.Status, "old raw episode closed")
	assert.Equal(t, "long", gotOld.Tier, "old raw episode moved to long tier")

	gotRecent, err := v.ReadNode(recent.ID)
	require.NoError(t, err)
	assert.Equal(t, "active", gotRecent.Status, "recent episode untouched")
	assert.Equal(t, "short", gotRecent.Tier)

	gotSit, err := v.ReadNode(sit.ID)
	require.NoError(t, err)
	assert.Equal(t, sitBefore.Body, gotSit.Body, "situation-aliased episode byte-identical")
	assert.Equal(t, "active", gotSit.Status, "situation-aliased episode's lifecycle belongs to ingest")

	// The index mirrors the transition.
	row, err := d.GetMemoryNode(old.ID)
	require.NoError(t, err)
	assert.Equal(t, "closed", row.Status)
	assert.Equal(t, "long", row.Tier)
}

// TestAgeEpisodesSkipsCorruptedCandidate: a candidate whose file cannot be read
// (index row present, vault file absent) is skipped-and-logged, and the pass
// still ages the healthy old episode.
func TestAgeEpisodesSkipsCorruptedCandidate(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	// Corrupted: indexed as an active short episode but never written to disk.
	indexNode(t, d, Node{ID: "ep_01ARZ3NDEKTSV4RRFFQ69G5AC1", Type: "episode", Tier: "short", Status: "active", Title: "ghost"})
	healthy := agingEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5AC2", "C1CHAN", 30)
	writeAndIndex(t, v, d, healthy)

	aged, err := AgeEpisodes(v, d, 14, time.Now(), t.Logf)
	require.NoError(t, err, "a corrupted candidate does not abort the pass")
	assert.Equal(t, 1, aged, "the healthy old episode still ages")

	got, err := v.ReadNode(healthy.ID)
	require.NoError(t, err)
	assert.Equal(t, "closed", got.Status)
}
