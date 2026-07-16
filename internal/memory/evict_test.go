package memory

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestRetentionScore(t *testing.T) {
	// A cold, unreferenced, un-touched episode scores 0 (importance 0).
	assert.Zero(t, RetentionScore(RetentionInputs{LastEventAgeDays: 100}))

	// Links-in lift the score; older = lower (recency decays).
	fresh := RetentionScore(RetentionInputs{LastEventAgeDays: 10, LinksIn: 3})
	old := RetentionScore(RetentionInputs{LastEventAgeDays: 100, LinksIn: 3})
	assert.Greater(t, fresh, old, "recency decays with age")
	assert.Positive(t, old)

	// Owner-touch outweighs the situation bonus.
	owner := RetentionScore(RetentionInputs{LastEventAgeDays: 100, OwnerTouched: true})
	situation := RetentionInputs{LastEventAgeDays: 100, SituationOrigin: true}
	assert.Greater(t, owner, RetentionScore(situation))

	// Recency is floored so an ancient but well-linked episode still scores.
	ancient := RetentionScore(RetentionInputs{LastEventAgeDays: 100000, LinksIn: 10})
	assert.InDelta(t, retentionRecencyFloor*10, ancient, 1e-9)
}

// TestRetentionScoreEngagement: positive net owner-engagement raises importance;
// zero or negative net adds no bonus and never lowers the score below the
// un-engaged baseline (Phase-5 5D, Task 8).
func TestRetentionScoreEngagement(t *testing.T) {
	base := RetentionInputs{LastEventAgeDays: 50, LinksIn: 1}
	engaged := base
	engaged.Engagement = 2
	assert.Greater(t, RetentionScore(engaged), RetentionScore(base), "engagement raises importance")

	zero := base
	zero.Engagement = 0
	assert.Equal(t, RetentionScore(base), RetentionScore(zero), "zero net adds no bonus")

	negative := base
	negative.Engagement = -5
	assert.Equal(t, RetentionScore(base), RetentionScore(negative),
		"a net-dismissed entity never scores below the un-engaged baseline")

	// Monotonic in the positive range.
	more := base
	more.Engagement = 4
	assert.Greater(t, RetentionScore(more), RetentionScore(engaged), "score rises with engagement")
}

// TestEvictEngagedEpisodeSurvivesTwinEvicts: two otherwise-identical cold, closed,
// linked episodes — the one whose linking entity has positive engagement survives
// eviction while its un-engaged twin is rolled up. Isolates engagement as the
// deciding factor (both carry one link-in, so the only difference is the
// engagement aggregate feeding importance).
func TestEvictEngagedEpisodeSurvivesTwinEvicts(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	engagedEp := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EP1", "Warm story", "handled", "C1CHAN", 100)
	coldEp := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EP2", "Cold story", "handled", "C2CHAN", 100)
	writeAndIndex(t, v, d, engagedEp)
	writeAndIndex(t, v, d, coldEp)

	// One entity links each episode (both get links-in = 1); only the first's
	// entity carries owner engagement.
	engagedEnt := linkingEntity(t, "ent_00000000000000000000000001", "Alice", engagedEp.ID)
	coldEnt := linkingEntity(t, "ent_00000000000000000000000002", "Bob", coldEp.ID)
	writeAndIndex(t, v, d, engagedEnt)
	writeAndIndex(t, v, d, coldEnt)
	require.NoError(t, d.BumpEngagement(engagedEnt.ID, true, "2026-07-16T10:00:00Z"))

	evicted, err := EvictEpisodes(v, d, 45, 0.5, 20, t.Logf)
	require.NoError(t, err)
	require.Equal(t, 1, evicted, "only the un-engaged twin evicts")

	warm, err := v.ReadNode(engagedEp.ID)
	require.NoError(t, err)
	assert.Equal(t, "closed", warm.Status, "the engaged episode survives")

	tomb, err := v.ReadNode(coldEp.ID)
	require.NoError(t, err)
	assert.Equal(t, "tombstone", tomb.Status, "the un-engaged twin is rolled up")
}

// linkingEntity is an active entity page whose ## Links section wiki-links the
// given episode (so CountMemoryLinksIn/LinkedEntityEngagement see the link).
func linkingEntity(t *testing.T, id, title, episodeID string) Node {
	t.Helper()
	body := "# " + title + "\n\n## What\nx\n\n## Current\n\n## Facts\n\n## Links\n- [[" + episodeID + "|ep]]\n\n## Open loops\n"
	return Node{ID: id, Type: "entity", Tier: "long", Status: "active", Title: title, Aliases: []string{id + "-alias"}, Body: body}
}

// oldEpNode builds a closed long-tier episode whose newest provenance event is
// ageDays old, with the given refs, title and outcome — the eviction candidate
// shape.
func oldEpNode(t *testing.T, id, title, outcome, channel string, ageDays int, extraTS ...string) Node {
	t.Helper()
	base := time.Now().AddDate(0, 0, -ageDays).Unix()
	tss := []string{fmt.Sprintf("%d.000100", base)}
	tss = append(tss, extraTS...)
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n## Story\n%s happened.\n\n## Outcome\n%s\n\n## Provenance\n", title, title, outcome)
	for _, ts := range tss {
		fmt.Fprintf(&b, "- %s %s\n", channel, ts)
	}
	return Node{ID: id, Type: "episode", Tier: "long", Status: "closed", Title: title, Body: b.String()}
}

// TestMemory07_EvictionKeepsProvenance is the MEM-07 formal guard: provenance
// never thins. Eviction carries EVERY provenance ref verbatim into the rollup
// line, tombstones the episode redirecting to the sum_* rollup, and the resolver
// chases the old id to the rollup (the rollup line is FTS-searchable). The
// dedupe path is covered too: a partial-overlap merge unions the loser-only ref
// into the winner rather than dropping it. Dropping any ref must fail this test.
func TestMemory07_EvictionKeepsProvenance(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base := time.Now().AddDate(0, 0, -100).Unix()
	ts1 := fmt.Sprintf("%d.000100", base)
	ts2 := fmt.Sprintf("%d.000200", base+30)
	ep := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EV1", "Deploy freeze retro", "Freeze lifted after two days", "C1CHAN", 100, ts2)
	writeAndIndex(t, v, d, ep)

	evicted, err := EvictEpisodes(v, d, 45, 0.5, 20, t.Logf)
	require.NoError(t, err)
	require.Equal(t, 1, evicted)

	// The episode is now a tombstone redirecting to a rollup.
	tomb, err := v.ReadNode(ep.ID)
	require.NoError(t, err)
	assert.Equal(t, "tombstone", tomb.Status)
	assert.True(t, strings.HasPrefix(tomb.RedirectTo, "sum_"), "redirects to a rollup, got %q", tomb.RedirectTo)

	// The resolver chases the old id to the rollup.
	rollup, err := Resolve(v, d, ep.ID)
	require.NoError(t, err)
	assert.Equal(t, "rollup", rollup.Type)
	assert.Equal(t, tomb.RedirectTo, rollup.ID)

	// MEM-07: every provenance ref present verbatim in the rollup gist line.
	for _, ref := range []string{"C1CHAN " + ts1, "C1CHAN " + ts2} {
		assert.Contains(t, rollup.Body, ref, "rollup keeps provenance ref %q", ref)
	}
	assert.Contains(t, rollup.Body, "Deploy freeze retro")

	// The rollup line is FTS-searchable (the episode body is gone from FTS).
	hits, err := d.SearchMemoryFTS("Deploy freeze retro", 10)
	require.NoError(t, err)
	require.Len(t, hits, 1)
	assert.Equal(t, rollup.ID, hits[0].ID)

	// The dedupe path also preserves provenance: a partial-overlap merge unions
	// the loser-only ref into the winner (MEM-07 — no ref lost on merge either).
	v2, d2 := newTestVault(t), newTestDB(t)
	older := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5EW1", "First", "CDCHAN", "1752570000.000100", "1752570100.000200")
	newer := epNode("ep_01ARZ3NDEKTSV4RRFFQ69G5EW2", "Second", "CDCHAN", "1752570100.000200", "1752570200.000300")
	writeAndIndex(t, v2, d2, older)
	writeAndIndex(t, v2, d2, newer)
	merged, err := DedupeEpisodes(v2, d2, 20, t.Logf)
	require.NoError(t, err)
	require.Equal(t, 1, merged)
	winner, err := Resolve(v2, d2, newer.ID)
	require.NoError(t, err)
	assert.Contains(t, winner.Body, "CDCHAN 1752570200.000300", "MEM-07: dedupe unions the loser-only provenance ref")
}

// TestEvictSkipsRecentAndHighScore: a recent episode (inside the window) and an
// old-but-well-linked episode (score above threshold) are both kept.
func TestEvictSkipsRecentAndHighScore(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	recent := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EV2", "Recent chat", "ongoing", "C2CHAN", 5)
	writeAndIndex(t, v, d, recent)

	linked := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EV3", "Well linked", "done", "C2CHAN", 100)
	writeAndIndex(t, v, d, linked)
	// Three live entity pages link to the old episode → importance high.
	for i := 0; i < 3; i++ {
		e := vaultTestNode(fmt.Sprintf("ent_01ARZ3NDEKTSV4RRFFQ69G5EL%d", i), "entity", "Linker")
		e.Body = "# Linker\n\n## Links\n- [[" + linked.ID + "]]\n"
		writeAndIndex(t, v, d, e)
	}

	evicted, err := EvictEpisodes(v, d, 45, 0.5, 20, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 0, evicted, "recent and well-linked episodes are kept")
	for _, id := range []string{recent.ID, linked.ID} {
		got, err := v.ReadNode(id)
		require.NoError(t, err)
		assert.NotEqual(t, "tombstone", got.Status, id)
	}
}

// TestEvictNeverActiveOrShort: an active or short-tier episode is out of scope.
func TestEvictNeverActiveOrShort(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	active := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EV4", "Active old", "x", "C3CHAN", 100)
	active.Status = "active"
	writeAndIndex(t, v, d, active)

	short := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EV5", "Short old", "x", "C3CHAN", 100)
	short.Tier = "short"
	writeAndIndex(t, v, d, short)

	evicted, err := EvictEpisodes(v, d, 45, 0.5, 20, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 0, evicted)
}

// TestEvictAppendsToExistingRollup: a second eviction into the same channel-
// month appends to the existing rollup — no duplicate rollup node.
func TestEvictAppendsToExistingRollup(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	// Two episodes in the same channel and month (both ~100 days old).
	e1 := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EV6", "First cold", "closed", "C4CHAN", 100)
	writeAndIndex(t, v, d, e1)
	n1, err := EvictEpisodes(v, d, 45, 0.5, 20, t.Logf)
	require.NoError(t, err)
	require.Equal(t, 1, n1)

	e2 := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EV7", "Second cold", "closed", "C4CHAN", 100)
	writeAndIndex(t, v, d, e2)
	n2, err := EvictEpisodes(v, d, 45, 0.5, 20, t.Logf)
	require.NoError(t, err)
	require.Equal(t, 1, n2)

	// Exactly one rollup node exists.
	rows, err := d.ListMemoryNodes()
	require.NoError(t, err)
	rollupCount := 0
	var rollupID string
	for _, r := range rows {
		if r.Type == "rollup" {
			rollupCount++
			rollupID = r.ID
		}
	}
	assert.Equal(t, 1, rollupCount, "second eviction appends, no duplicate rollup")

	rollup, err := v.ReadNode(rollupID)
	require.NoError(t, err)
	assert.Contains(t, rollup.Body, "First cold")
	assert.Contains(t, rollup.Body, "Second cold")
}

// TestEvictCapRespected: with three cold episodes and a cap of one, only one
// is evicted per run.
func TestEvictCapRespected(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	for i := 0; i < 3; i++ {
		ep := oldEpNode(t, fmt.Sprintf("ep_01ARZ3NDEKTSV4RRFFQ69G5EC%d", i), "Cold", "done", fmt.Sprintf("C5CHA%d", i), 100)
		writeAndIndex(t, v, d, ep)
	}
	evicted, err := EvictEpisodes(v, d, 45, 0.5, 1, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 1, evicted)
}

// TestEvictReindexEquivalence: after eviction the incrementally-maintained
// index equals the one Rebuild reconstructs from the vault (MEM-02 still holds
// with the new tombstones + rollups).
func TestEvictReindexEquivalence(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	ep := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5ER1", "Cold retro", "done", "C6CHAN", 100)
	ep.Aliases = []string{"situation:99"} // situation-origin alias must migrate to the rollup
	writeAndIndex(t, v, d, ep)

	evicted, err := EvictEpisodes(v, d, 45, 0.5, 20, t.Logf)
	require.NoError(t, err)
	require.Equal(t, 1, evicted)

	incremental := dumpIndex(t, d)
	_, err = Rebuild(v, d, t.Logf)
	require.NoError(t, err)
	rebuilt := dumpIndex(t, d)
	assert.Equal(t, incremental, rebuilt)

	// The migrated alias resolves to the rollup after a full rebuild.
	got, err := Resolve(v, d, "situation:99")
	require.NoError(t, err)
	assert.Equal(t, "rollup", got.Type)
}

// TestEvictSkipsCorruptedCandidate: a candidate whose file cannot be read
// (indexed as a cold closed long episode but not written) is skipped-and-logged,
// and a healthy cold episode is still evicted — one bad node never aborts the
// pass.
func TestEvictSkipsCorruptedCandidate(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	indexNode(t, d, Node{ID: "ep_01ARZ3NDEKTSV4RRFFQ69G5EX1", Type: "episode", Tier: "long", Status: "closed", Title: "ghost"})
	healthy := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EX2", "Cold retro", "done", "CXCHAN", 100)
	writeAndIndex(t, v, d, healthy)

	evicted, err := EvictEpisodes(v, d, 45, 0.5, 20, t.Logf)
	require.NoError(t, err, "a corrupted candidate does not abort the pass")
	assert.Equal(t, 1, evicted, "the healthy cold episode is still evicted")

	got, err := v.ReadNode(healthy.ID)
	require.NoError(t, err)
	assert.Equal(t, "tombstone", got.Status)
}

// TestEvictOwnerTouchedKept: an owner-edited episode (its file carried a
// memory(owner-edit) commit) gets the owner-touch bonus and is not evicted.
func TestEvictOwnerTouchedKept(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	ep := oldEpNode(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5EO1", "Owner note", "done", "C7CHAN", 100)
	writeAndIndex(t, v, d, ep)

	// Simulate an owner edit: change the worktree file and let CommitOwnerEdits
	// record it as a memory(owner-edit) commit.
	rel, err := nodeRelPath(ep.ID)
	require.NoError(t, err)
	edited := ep
	edited.Body = ep.Body + "\nOwner annotation.\n"
	require.NoError(t, os.WriteFile(filepath.Join(v.path, filepath.FromSlash(rel)), edited.Render(), 0o644))
	committed, err := v.CommitOwnerEdits()
	require.NoError(t, err)
	require.True(t, committed)

	touched, err := v.OwnerEdited(rel)
	require.NoError(t, err)
	require.True(t, touched, "OwnerEdited must see the owner-edit commit")

	evicted, err := EvictEpisodes(v, d, 45, 0.5, 20, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 0, evicted, "owner-touched episode is kept (bonus lifts score)")
}
