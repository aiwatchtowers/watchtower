package memory

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// writeNodes commits nodes to the vault without touching the index (that is
// Reconcile's job in these tests).
func writeNodes(t *testing.T, v *Vault, nodes ...Node) {
	t.Helper()
	ids := make([]string, len(nodes))
	for i, n := range nodes {
		ids[i] = n.ID
	}
	_, err := v.WriteNodes(nodes, CommitMsg{Op: "seed", Summary: "test nodes", Cause: "seed", NodeIDs: ids})
	require.NoError(t, err)
}

// indexDump is a comparable snapshot of the file-derived index tables:
// memory_nodes (indexed_at zeroed — it is a wall-clock stamp), memory_aliases,
// and memory_fts. memory_node_stats is deliberately absent: access stats are
// runtime state, not derivable from vault files.
type indexDump struct {
	Nodes   []db.MemoryNodeRow
	Aliases [][2]string
	FTS     [][3]string
}

func dumpIndex(t *testing.T, d *db.DB) indexDump {
	t.Helper()
	var dump indexDump

	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	for i := range nodes {
		nodes[i].IndexedAt = ""
	}
	dump.Nodes = nodes

	rows, err := d.Query(`SELECT alias, node_id FROM memory_aliases ORDER BY alias`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var a [2]string
		require.NoError(t, rows.Scan(&a[0], &a[1]))
		dump.Aliases = append(dump.Aliases, a)
	}
	require.NoError(t, rows.Err())

	frows, err := d.Query(`SELECT id, title, body FROM memory_fts ORDER BY id`)
	require.NoError(t, err)
	defer frows.Close()
	for frows.Next() {
		var f [3]string
		require.NoError(t, frows.Scan(&f[0], &f[1], &f[2]))
		dump.FTS = append(dump.FTS, f)
	}
	require.NoError(t, frows.Err())

	return dump
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func TestReconcileIndexesNewNodes(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5IX1", "entity", "Billing")
	a.Aliases = []string{"billing-v2", "C0123ABC"}
	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5IX2", "episode", "Rollout incident")
	writeNodes(t, v, a, b)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, Stats{Added: 2}, stats)

	row, err := d.GetMemoryNode(a.ID)
	require.NoError(t, err)
	assert.Equal(t, "Billing", row.Title)
	assert.Equal(t, "entities/"+a.ID+".md", row.Path)
	assert.Equal(t, sha256Hex(a.Render()), row.ContentHash)
	assert.NotEmpty(t, row.IndexedAt)

	nodeID, err := d.LookupMemoryAlias("billing-v2")
	require.NoError(t, err)
	assert.Equal(t, a.ID, nodeID)

	hits, err := d.SearchMemoryFTS("incident", 10)
	require.NoError(t, err)
	require.Len(t, hits, 1)
	assert.Equal(t, b.ID, hits[0].ID)

	// A second pass over an unchanged vault touches nothing.
	stats, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, Stats{}, stats)
}

func TestReconcileUpdatesEditedFile(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5IX3", "entity", "Old Title")
	n.Aliases = []string{"old-alias"}
	writeNodes(t, v, n)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Owner-style edit: new title, new alias, new body term.
	edited := n
	edited.Title = "New Title"
	edited.Aliases = []string{"new-alias"}
	edited.Body = "# New Title\n\nNow about kubernetes.\n"
	path := filepath.Join(v.path, "entities", n.ID+".md")
	require.NoError(t, os.WriteFile(path, edited.Render(), 0o644))

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, Stats{Updated: 1}, stats)

	row, err := d.GetMemoryNode(n.ID)
	require.NoError(t, err)
	assert.Equal(t, "New Title", row.Title)
	assert.Equal(t, sha256Hex(edited.Render()), row.ContentHash)

	// Aliases replaced wholesale.
	_, err = d.LookupMemoryAlias("old-alias")
	assert.ErrorIs(t, err, sql.ErrNoRows)
	nodeID, err := d.LookupMemoryAlias("new-alias")
	require.NoError(t, err)
	assert.Equal(t, n.ID, nodeID)

	// FTS row replaced: new term hits, old body does not.
	hits, err := d.SearchMemoryFTS("kubernetes", 10)
	require.NoError(t, err)
	require.Len(t, hits, 1)
	hits, err = d.SearchMemoryFTS("Old", 10)
	require.NoError(t, err)
	assert.Empty(t, hits)
}

func TestReconcileDeletesRemovedFile(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	keep := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5IX4", "entity", "Keeper")
	gone := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5IX5", "episode", "Ephemeral")
	gone.Aliases = []string{"situation:42"}
	writeNodes(t, v, keep, gone)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	require.NoError(t, os.Remove(filepath.Join(v.path, "episodes", gone.ID+".md")))

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, Stats{Deleted: 1}, stats)

	_, err = d.GetMemoryNode(gone.ID)
	assert.ErrorIs(t, err, sql.ErrNoRows)
	_, err = d.LookupMemoryAlias("situation:42")
	assert.ErrorIs(t, err, sql.ErrNoRows)
	hits, err := d.SearchMemoryFTS("Ephemeral", 10)
	require.NoError(t, err)
	assert.Empty(t, hits)

	_, err = d.GetMemoryNode(keep.ID)
	assert.NoError(t, err, "untouched node stays indexed")
}

func TestReconcileSkipsNonNodeFiles(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5IX6", "entity", "Real Node")
	writeNodes(t, v, n)

	// map.md lives at the vault root — never walked. Non-node files inside the
	// subdirs (wrong extension, no ID prefix, prefix belonging to another
	// subdir) are skipped without error.
	require.NoError(t, os.WriteFile(filepath.Join(v.path, "entities", "notes.md"), []byte("scratch"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(v.path, "entities", "ent_noext"), []byte("no extension"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(v.path, "episodes", "ent_01ARZ3NDEKTSV4RRFFQ69G5IX7.md"), []byte("misplaced"), 0o644))

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, Stats{Added: 1}, stats)

	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	require.Len(t, nodes, 1)
	assert.Equal(t, n.ID, nodes[0].ID)
}

// A malformed node file (unknown frontmatter key — classic Obsidian-side
// damage) is quarantined: the run continues, other files are indexed, and the
// file's previously indexed row survives because the file is still on disk
// (the delete loop must not treat a quarantined file as removed).
func TestReconcileQuarantinesMalformedFile(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	broken := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5QF1", "entity", "Broken Later")
	writeNodes(t, v, broken)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Owner damages the file (unknown frontmatter key) and adds a fresh valid
	// node in the same window.
	brokenPath := filepath.Join(v.path, "entities", broken.ID+".md")
	damaged := strings.Replace(string(broken.Render()), "id: "+broken.ID+"\n",
		"id: "+broken.ID+"\nmood: sparkling\n", 1)
	require.NoError(t, os.WriteFile(brokenPath, []byte(damaged), 0o644))
	fresh := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5QF2", "episode", "Fresh One")
	writeNodes(t, v, fresh)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err, "a per-file parse failure must not fail the run")
	assert.Equal(t, 1, stats.Added, "the healthy file is still indexed")
	assert.Equal(t, 0, stats.Deleted)
	assert.Equal(t, 1, stats.Quarantined)
	assert.Equal(t, []string{"entities/" + broken.ID + ".md"}, stats.QuarantinedPaths)

	// The quarantined file's OLD index row is preserved, not deleted.
	row, err := d.GetMemoryNode(broken.ID)
	require.NoError(t, err)
	assert.Equal(t, "Broken Later", row.Title)
	assert.Equal(t, sha256Hex(broken.Render()), row.ContentHash, "row still reflects the last good parse")

	_, err = d.GetMemoryNode(fresh.ID)
	assert.NoError(t, err)
}

// A duplicate alias across two files quarantines the second file (its index
// upsert fails on the alias primary key); the first stays intact.
func TestReconcileQuarantinesDuplicateAlias(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	first := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5QA1", "entity", "First Owner")
	first.Aliases = []string{"shared-alias"}
	second := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5QA2", "entity", "Second Claimant")
	second.Aliases = []string{"SHARED-ALIAS"} // COLLATE NOCASE — collides
	writeNodes(t, v, first, second)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err, "a per-file upsert failure must not fail the run")
	assert.Equal(t, 1, stats.Added)
	assert.Equal(t, 1, stats.Quarantined)
	assert.Equal(t, []string{"entities/" + second.ID + ".md"}, stats.QuarantinedPaths)

	// First file fully indexed, alias resolves to it.
	nodeID, err := d.LookupMemoryAlias("shared-alias")
	require.NoError(t, err)
	assert.Equal(t, first.ID, nodeID)
	_, err = d.GetMemoryNode(second.ID)
	assert.ErrorIs(t, err, sql.ErrNoRows, "quarantined file gets no partial row")
}

// TestMemory02_ReindexEquivalence guards MEM-02: dropping all memory_* tables
// and rebuilding from the vault reproduces the incrementally-maintained index.
// memory_node_stats is excluded by design — access stats are runtime state,
// not derivable from files; their reset on rebuild is accepted v1 behavior.
func TestMemory02_ReindexEquivalence(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	// Pass 1: two fresh nodes.
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5IXA", "entity", "Alpha")
	a.Aliases = []string{"alpha", "C0AAAAAAA"}
	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5IXB", "episode", "Beta")
	writeNodes(t, v, a, b)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Pass 2: edit A (title + aliases), add C.
	a.Title = "Alpha Prime"
	a.Aliases = []string{"alpha-prime"}
	a.Body = "# Alpha Prime\n\nRewritten body.\n"
	c := vaultTestNode("sum_01ARZ3NDEKTSV4RRFFQ69G5IXC", "rollup", "Q3 rollup")
	writeNodes(t, v, a, c)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Pass 3: delete B, edit C.
	require.NoError(t, os.Remove(filepath.Join(v.path, "episodes", b.ID+".md")))
	c.Body = "# Q3 rollup\n\nCollapsed episodes live here.\n"
	writeNodes(t, v, c)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	incremental := dumpIndex(t, d)
	require.Len(t, incremental.Nodes, 2, "sanity: A and C survive")

	_, err = Rebuild(v, d, t.Logf)
	require.NoError(t, err)
	rebuilt := dumpIndex(t, d)

	assert.Equal(t, incremental, rebuilt)
}
