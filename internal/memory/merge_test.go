package memory

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// mergeFixture writes an indexed winner + loser pair. The winner body carries
// a ## Links section so the merged-from placement is exercised by default.
func mergeFixture(t *testing.T, v *Vault, d *db.DB) (winner, loser Node) {
	t.Helper()
	winner = Node{
		ID:      "ent_01ARZ3NDEKTSV4RRFFQ69G5MG1",
		Type:    "entity",
		Tier:    "long",
		Status:  "active",
		Title:   "Winner",
		Aliases: []string{"winner-alias"},
		Body:    "# Winner\n\n## What\nThe canonical page.\n\n## Links\n- [[ent_01ARZ3NDEKTSV4RRFFQ69G5MG9]]\n\n## Open loops\n",
	}
	loser = Node{
		ID:      "ent_01ARZ3NDEKTSV4RRFFQ69G5MG2",
		Type:    "entity",
		Tier:    "long",
		Status:  "active",
		Title:   "Loser",
		Aliases: []string{"old-alias", "C0LOSER"},
		Body:    "# Loser\n\nDuplicate page.\n",
	}
	writeNodes(t, v, winner, loser)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	return winner, loser
}

func TestMergeHappyPath(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	winner, loser := mergeFixture(t, v, d)
	repo := openTestRepo(t, v.path)
	commitsBefore := commitCount(t, repo)

	require.NoError(t, Merge(v, d, loser.ID, winner.ID))

	// Loser file is a tombstone stub: one-line body, redirect, no aliases.
	gotLoser, err := v.ReadNode(loser.ID)
	require.NoError(t, err)
	assert.Equal(t, "tombstone", gotLoser.Status)
	assert.Equal(t, winner.ID, gotLoser.RedirectTo)
	assert.Equal(t, "Merged into [["+winner.ID+"]].\n", gotLoser.Body)
	assert.Empty(t, gotLoser.Aliases)

	// Winner carries the loser's aliases in frontmatter and the merged-from
	// line under its ## Links section.
	gotWinner, err := v.ReadNode(winner.ID)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"winner-alias", "old-alias", "C0LOSER"}, gotWinner.Aliases)
	assert.Contains(t, gotWinner.Body, "## Links\n- merged from [["+loser.ID+"]]\n")

	// Exactly one commit, op merge, touching exactly the two node files.
	assert.Equal(t, commitsBefore+1, commitCount(t, repo))
	commit := headCommit(t, repo)
	assert.True(t, strings.HasPrefix(commit.Message, "memory(merge): "), "message %q", commit.Message)
	assert.ElementsMatch(t,
		[]string{"entities/" + loser.ID + ".md", "entities/" + winner.ID + ".md"},
		commitFiles(t, commit))
	made, err := v.CommitOwnerEdits()
	require.NoError(t, err)
	assert.False(t, made, "merge leaves a clean worktree")

	// Index updated in the same call: aliases moved, tombstone row recorded.
	row, err := d.GetMemoryNode(loser.ID)
	require.NoError(t, err)
	assert.Equal(t, "tombstone", row.Status)
	assert.Equal(t, winner.ID, row.RedirectTo)
	nodeID, err := d.LookupMemoryAlias("old-alias")
	require.NoError(t, err)
	assert.Equal(t, winner.ID, nodeID)

	// The resolver now takes the loser's old alias and old ID to the winner.
	resolved, err := Resolve(v, d, "OLD-ALIAS")
	require.NoError(t, err)
	assert.Equal(t, winner.ID, resolved.ID)
	resolved, err = Resolve(v, d, loser.ID)
	require.NoError(t, err)
	assert.Equal(t, winner.ID, resolved.ID)
}

func TestMergeAppendsWhenNoLinksSection(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	winner := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5MG3", "entity", "Plain Winner")
	loser := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5MG4", "entity", "Plain Loser")
	writeNodes(t, v, winner, loser)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	require.NoError(t, Merge(v, d, loser.ID, winner.ID))

	gotWinner, err := v.ReadNode(winner.ID)
	require.NoError(t, err)
	assert.True(t, strings.HasSuffix(gotWinner.Body, "- merged from [["+loser.ID+"]]\n"),
		"body %q", gotWinner.Body)
}

func TestMergeDedupesAliasesCaseInsensitive(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	winner := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5MG5", "entity", "Winner")
	winner.Aliases = []string{"Shared"}
	loser := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5MG6", "entity", "Loser")
	loser.Aliases = []string{"shared", "unique"}
	writeNodes(t, v, winner, loser)
	// The case-duplicate alias can only exist in frontmatter: memory_aliases
	// is COLLATE NOCASE unique, so the index holds it for the winner only.
	indexNode(t, d, winner)
	indexedLoser := loser
	indexedLoser.Aliases = []string{"unique"}
	indexNode(t, d, indexedLoser)

	require.NoError(t, Merge(v, d, loser.ID, winner.ID))

	gotWinner, err := v.ReadNode(winner.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"Shared", "unique"}, gotWinner.Aliases,
		"case-insensitive duplicate dropped, winner's casing kept")
}

func TestMergeErrors(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	winner, loser := mergeFixture(t, v, d)
	stone := tombstoneNode("ent_01ARZ3NDEKTSV4RRFFQ69G5MG7", winner.ID)
	writeNodes(t, v, stone)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	repo := openTestRepo(t, v.path)
	commitsBefore := commitCount(t, repo)
	winnerBefore, err := v.ReadNode(winner.ID)
	require.NoError(t, err)

	cases := []struct {
		name          string
		loser, winner string
	}{
		{"into itself", winner.ID, winner.ID},
		{"loser is a tombstone", stone.ID, winner.ID},
		{"winner is a tombstone", loser.ID, stone.ID},
		{"unknown loser", "ent_01ARZ3NDEKTSV4RRFFQ69G5MG8", winner.ID},
		{"unknown winner", loser.ID, "ent_01ARZ3NDEKTSV4RRFFQ69G5MG8"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Error(t, Merge(v, d, tc.loser, tc.winner))
		})
	}

	// Nothing was written by any failed merge: no commits, files untouched,
	// index aliases still on the loser.
	assert.Equal(t, commitsBefore, commitCount(t, repo))
	winnerAfter, err := v.ReadNode(winner.ID)
	require.NoError(t, err)
	assert.Equal(t, winnerBefore, winnerAfter)
	nodeID, err := d.LookupMemoryAlias("old-alias")
	require.NoError(t, err)
	assert.Equal(t, loser.ID, nodeID)
}

// appendToLinks inserts new lines at the top of ## Links but never duplicates
// a line already present — a re-processed window or repeated merge must not
// stack identical Links entries.
func TestAppendToLinksDeduplicates(t *testing.T) {
	body := "# Page\n\n## Links\n- [[ep_X|First]]\n"
	line := "- [[ep_Y|Second]]\n"

	once := appendToLinks(body, line)
	assert.Contains(t, once, "## Links\n- [[ep_Y|Second]]\n- [[ep_X|First]]\n",
		"new line becomes the first Links entry")

	twice := appendToLinks(once, line)
	assert.Equal(t, once, twice, "an existing line must not be added again")
	assert.Equal(t, 1, strings.Count(twice, "- [[ep_Y|Second]]"))

	// Bodies without a Links section: appended once, still deduplicated.
	plain := appendToLinks("# Bare\n", line)
	assert.Equal(t, plain, appendToLinks(plain, line))
}

// TestUpsertIndexNodeComputesImportance: upsertIndexNode (the non-Reconcile
// index-write path used by eviction/dedupe/concepts/beliefs/aging/mirrors/
// ingest/reflect/seed) must compute a real importance_score via the same
// ComputeImportance logic Reconcile uses, not silently persist 0 (Slice A
// follow-up, added 2026-07-18: upsertIndexNode previously clobbered any
// prior importance_score to 0 via UpsertMemoryNode's unconditional
// ON CONFLICT SET).
func TestUpsertIndexNodeComputesImportance(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	linker := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5UI1", "entity", "Linker")
	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5UI2", "entity", "Target")
	linker.Body = "# Linker\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5UI2]] for background.\n"
	writeNodes(t, v, linker, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// target now has LinksIn == 1 in the index. Re-write it via
	// upsertIndexNode directly (the non-Reconcile path) and confirm the
	// persisted importance_score reflects that link, not a reset to 0.
	require.NoError(t, upsertIndexNode(d, v.OwnerEdited, target, "2026-07-18T00:00:00Z"))

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	want := ComputeImportance(ImportanceInputs{LinksIn: 1})
	assert.Equal(t, want, row.ImportanceScore, "upsertIndexNode must compute importance like Reconcile, not persist 0")
}

// TestUpsertIndexNodeImportanceOverrideWins: an ImportanceOverride short-
// circuits upsertIndexNode's computation exactly as it does in Reconcile.
func TestUpsertIndexNodeImportanceOverrideWins(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	override := 9.0
	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5UI3", "entity", "Overridden")
	n.ImportanceOverride = &override

	require.NoError(t, upsertIndexNode(d, v.OwnerEdited, n, "2026-07-18T00:00:00Z"))

	row, err := d.GetMemoryNode(n.ID)
	require.NoError(t, err)
	assert.Equal(t, 9.0, row.ImportanceScore)
}
