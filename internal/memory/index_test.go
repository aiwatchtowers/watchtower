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
// memory_fts, and memory_provenance. memory_node_stats is deliberately absent:
// access stats are runtime state, not derivable from vault files. Provenance,
// by contrast, IS derived from each node's ## Provenance section, so it belongs
// inside the MEM-02 reindex-equivalence set (Phase-5 slice-3 extension).
type indexDump struct {
	Nodes      []db.MemoryNodeRow
	Aliases    [][2]string
	FTS        [][3]string
	Provenance []db.ProvenanceRow
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

	prows, err := d.Query(`SELECT node_id, scheme, channel_id, ts_raw, ts_unix
		FROM memory_provenance ORDER BY node_id, channel_id, ts_raw`)
	require.NoError(t, err)
	defer prows.Close()
	for prows.Next() {
		var p db.ProvenanceRow
		require.NoError(t, prows.Scan(&p.NodeID, &p.Scheme, &p.ChannelID, &p.TSRaw, &p.TSUnix))
		dump.Provenance = append(dump.Provenance, p)
	}
	require.NoError(t, prows.Err())

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

// TestReconcileIndexesBeliefSubjectConfidence: memory_nodes.subject/.confidence
// (Task 1, migration 00019) are populated from the parsed belief node so the
// Swift Discuss MEMORY block (Task 8) can join belief -> subject entity with a
// pure GRDB index read. A non-belief node keeps the "" / 0 defaults.
func TestReconcileIndexesBeliefSubjectConfidence(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	belief := Node{
		ID:         "bel_01ARZ3NDEKTSV4RRFFQ69G5IX9",
		Type:       "belief",
		Tier:       "long",
		Status:     "active",
		Confidence: 0.6,
		Stability:  2,
		Subject:    "ent_alpha",
		Body:       "# Alpha ships weekly\n\nBelief body.\n",
	}
	entity := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5IXA", "entity", "Alpha")
	writeNodes(t, v, belief, entity)

	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	row, err := d.GetMemoryNode(belief.ID)
	require.NoError(t, err)
	assert.Equal(t, "ent_alpha", row.Subject)
	assert.Equal(t, 0.6, row.Confidence)

	entityRow, err := d.GetMemoryNode(entity.ID)
	require.NoError(t, err)
	assert.Equal(t, "", entityRow.Subject)
	assert.Equal(t, 0.0, entityRow.Confidence)
}

// TestReconcileReparsesHashClearedBelief proves the migration-00019 remedy (M1)
// at the index layer: a belief already indexed whose content_hash is emptied —
// exactly what the migration does to every pre-existing belief — is re-parsed on
// the next Reconcile even though its file did not change, repopulating the new
// subject/confidence columns a hash-match skip would otherwise leave at ”/0.
func TestReconcileReparsesHashClearedBelief(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	belief := Node{
		ID:         "bel_01ARZ3NDEKTSV4RRFFQ69G5IY1",
		Type:       "belief",
		Tier:       "long",
		Status:     "active",
		Confidence: 0.6,
		Stability:  2,
		Subject:    "ent_alpha",
		Body:       "# Alpha ships weekly\n\nBelief body.\n",
	}
	writeNodes(t, v, belief)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Simulate the pre-00019 state: the row exists but subject/confidence are the
	// column defaults, and (as the migration does) content_hash is emptied.
	_, err = d.Exec(`UPDATE memory_nodes SET subject='', confidence=0, content_hash='' WHERE id=?`, belief.ID)
	require.NoError(t, err)

	// The file did NOT change, yet the emptied hash forces a re-parse.
	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 1, stats.Updated, "the hash-cleared belief is re-parsed")

	row, err := d.GetMemoryNode(belief.ID)
	require.NoError(t, err)
	assert.Equal(t, "ent_alpha", row.Subject)
	assert.Equal(t, 0.6, row.Confidence)
	assert.NotEmpty(t, row.ContentHash, "content_hash repopulated from the file")
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

// TestReconcileComputesImportanceScore: a fixture exercising all four
// ComputeImportance signals together — links-in, situation-origin,
// owner-touch, net engagement — proves Reconcile persists the SAME value
// ComputeImportance would compute directly, with no recency factor (Slice A,
// MEM-16).
func TestReconcileComputesImportanceScore(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	ep := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5RC1", "episode", "Warm story")
	ep.Aliases = []string{"situation:77"}
	writeNodes(t, v, ep)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	linker := linkingEntity(t, "ent_01ARZ3NDEKTSV4RRFFQ69G5RC2", "Linker", ep.ID)
	writeNodes(t, v, linker)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	require.NoError(t, d.BumpEngagement(linker.ID, true, "2026-07-18T10:00:00Z"))

	// Simulate an owner edit on ep, then touch it once more so it gets
	// reparsed NOW THAT the link (and the engagement bump) are already
	// committed.
	rel, err := nodeRelPath(ep.ID)
	require.NoError(t, err)
	edited := ep
	edited.Body = ep.Body + "\nOwner annotation.\n"
	require.NoError(t, os.WriteFile(filepath.Join(v.path, filepath.FromSlash(rel)), edited.Render(), 0o644))
	committed, err := v.CommitOwnerEdits()
	require.NoError(t, err)
	require.True(t, committed)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	require.Equal(t, 1, stats.Updated, "the owner-edited episode is reparsed")

	row, err := d.GetMemoryNode(ep.ID)
	require.NoError(t, err)

	want := ComputeImportance(ImportanceInputs{
		LinksIn:         1,
		SituationOrigin: true,
		OwnerTouched:    true,
		Engagement:      1,
	})
	assert.Equal(t, want, row.ImportanceScore, "importance_score matches ComputeImportance with no recency applied")
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

// TestReconcileImportanceOrderIndependent: a rollup and the entity it links
// to are BOTH touched within the SAME Reconcile call (the rollup is newly
// created, the entity's body is edited) — entities is scanned before
// rollups (vaultSubdirs order), so a single-pass computation would compute
// the entity's LinksIn before the rollup's link is indexed, understating its
// importance_score. The phase-B refinement pass must correct this within
// the same call, without requiring a later, separate Reconcile call to
// re-touch the entity (Slice A follow-up, added 2026-07-18, MEM-16 — the
// bug Task 6's implementer found while strengthening the MEM-02 fixture).
func TestReconcileImportanceOrderIndependent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5OI1", "entity", "Target")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	require.Zero(t, baseline.ImportanceScore, "sanity: no links yet")

	// Edit target's body (so it gets reparsed THIS call) and, in the SAME
	// Reconcile call, add a rollup linking to it. entities is scanned before
	// rollups, so a single-pass computation would see LinksIn=0 for target;
	// the refinement pass must correct it to 1 before Reconcile returns.
	target.Body = "# Target\n\nRevision one.\n"
	rollup := vaultTestNode("sum_01ARZ3NDEKTSV4RRFFQ69G5OI2", "rollup", "Summary")
	rollup.Body = "# Summary\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5OI1]] for background.\n"
	writeNodes(t, v, target, rollup)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	want := ComputeImportance(ImportanceInputs{LinksIn: 1})
	assert.Equal(t, want, row.ImportanceScore,
		"target's importance must reflect rollup's link within the SAME Reconcile call, not just after a later separate call")
}

// TestReconcileImportanceOverrideWins: a node whose frontmatter carries
// importance_override persists exactly that value through Reconcile, even
// though every organic signal (links-in, situation-origin, owner-touch,
// engagement) is zero — proving the override short-circuits
// computeImportance rather than being blended with the computed value
// (Slice A, MEM-16).
func TestReconcileImportanceOverrideWins(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	override := 7.5
	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5OV1", "entity", "Manually Important")
	n.ImportanceOverride = &override
	writeNodes(t, v, n)

	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	row, err := d.GetMemoryNode(n.ID)
	require.NoError(t, err)
	assert.Equal(t, 7.5, row.ImportanceScore, "the override wins over the (zero) computed signals")
}

// TestReconcileImportanceQuarantineOnSignalError: when a node's importance
// signal lookup fails (LinkedEntityEngagement here, via a dropped
// memory_engagement table), that ONE file is quarantined — its prior
// importance_score (and the rest of its row) stays untouched — while the
// rest of the pass completes normally. A brand-new node carrying its own
// importance_override never calls the broken lookup at all, proving the
// failure is isolated rather than pass-wide (Slice A, design §6, MEM-16).
func TestReconcileImportanceQuarantineOnSignalError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	// A linking entity gives A a nonzero baseline importance BEFORE anything
	// breaks, so "prior importance_score untouched" below is a real
	// assertion, not a vacuous 0 == 0.
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5QI1", "entity", "Linked Target")
	writeNodes(t, v, a)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	linker := linkingEntity(t, "ent_01ARZ3NDEKTSV4RRFFQ69G5QI2", "Linker", a.ID)
	writeNodes(t, v, linker)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Touch A again so it gets reparsed now that the link is already
	// committed (CountMemoryLinksIn only sees a link once its source file is
	// indexed).
	a.Body = "# Linked Target\n\nRevision one.\n"
	writeNodes(t, v, a)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(a.ID)
	require.NoError(t, err)
	require.Equal(t, 1.0, baseline.ImportanceScore, "sanity: A already reflects the link-in bonus")

	// Break LinkedEntityEngagement's lookup for every node that has no
	// override.
	_, err = d.Exec(`DROP TABLE memory_engagement`)
	require.NoError(t, err)

	// Touch A once more (forces a reparse into the now-broken lookup) and add
	// a brand-new node carrying an importance_override, which never calls the
	// broken signal lookups at all.
	a.Body = "# Linked Target\n\nRevision two.\n"
	overrideVal := 3.0
	fresh := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5QI3", "entity", "Fresh Override")
	fresh.ImportanceOverride = &overrideVal
	writeNodes(t, v, a, fresh)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err, "a signal-lookup failure must not abort the pass")
	assert.Equal(t, 1, stats.Added, "the override-carrying node is still indexed")
	assert.Equal(t, 1, stats.Quarantined)
	assert.Equal(t, []string{"entities/" + a.ID + ".md"}, stats.QuarantinedPaths)

	after, err := d.GetMemoryNode(a.ID)
	require.NoError(t, err)
	assert.Equal(t, baseline.ImportanceScore, after.ImportanceScore, "prior importance_score untouched")
	assert.Equal(t, baseline.ContentHash, after.ContentHash, "quarantine keeps the whole prior row, not just the score")

	freshRow, err := d.GetMemoryNode(fresh.ID)
	require.NoError(t, err)
	assert.Equal(t, 3.0, freshRow.ImportanceScore)
}

// TestReconcileImportanceRefinesAfterDeletion: a same-pass file deletion of a
// node's only linker must be reflected in the linked node's refined
// importance_score — refineImportance must run AFTER the deletion loop, not
// before, or it recomputes CountMemoryLinksIn while the about-to-be-deleted
// linker's row/FTS entry is still present, diverging from what a fresh
// Rebuild (which never sees the deleted file at all) would compute (whole-
// branch review follow-up, added 2026-07-18, MEM-16).
func TestReconcileImportanceRefinesAfterDeletion(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5DE1", "entity", "Target")
	linker := linkingEntity(t, "ent_01ARZ3NDEKTSV4RRFFQ69G5DE2", "Linker", target.ID)
	writeNodes(t, v, target, linker)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	require.Equal(t, 1.0, baseline.ImportanceScore, "sanity: linker gives target a link-in")

	// In the SAME Reconcile call: delete the linker's file AND touch target
	// (so it gets reparsed this pass, entering phase B's refinement).
	require.NoError(t, os.Remove(filepath.Join(v.path, "entities", linker.ID+".md")))
	target.Body = "# Target\n\nRevision one.\n"
	writeNodes(t, v, target)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 1, stats.Deleted, "the linker's file is gone")
	assert.Equal(t, 1, stats.Updated, "target is reparsed this same pass")

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	assert.Zero(t, row.ImportanceScore,
		"the deleted linker must not be counted — refineImportance must run AFTER the deletion loop, matching a fresh Rebuild")
}

// TestReconcileImportanceRefinesUnchangedLinkedNode: a brand-new episode
// links to an existing, otherwise-untouched entity — the entity's OWN file
// never changes this pass (or ever again, in this test), so file()'s
// content-hash gate skips it entirely and it never enters p.touched. Without
// a delta-refine pass over touched nodes' outgoing links, the entity's
// importance_score would stay frozen at its original value forever, even
// though CountMemoryLinksIn — the formula's dominant signal — has grown
// (whole-branch review follow-up, added 2026-07-18, MEM-16 — the Critical
// bug: a node linked from many new episodes over weeks, none of which touch
// its own file, never gets its importance_score refreshed).
func TestReconcileImportanceRefinesUnchangedLinkedNode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5DL1", "entity", "Target")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	require.Zero(t, baseline.ImportanceScore, "sanity: no links yet")

	// A brand-new episode links to target — target's OWN file is untouched
	// this pass (its content hash is unchanged, so file() never reparses it
	// and it never enters p.touched).
	linker := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DL2", "episode", "New Story")
	linker.Body = "# New Story\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5DL1]] for background.\n"
	writeNodes(t, v, linker)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	require.Equal(t, Stats{Added: 1}, stats, "sanity: only the new episode is (re)indexed, target is not reparsed")

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	want := ComputeImportance(ImportanceInputs{LinksIn: 1})
	assert.Equal(t, want, row.ImportanceScore,
		"target's importance must be refreshed even though ITS OWN file never changed — the new episode's outgoing link is what changed target's LinksIn")
	assert.Equal(t, baseline.ContentHash, row.ContentHash, "target's content/hash must be untouched — only its score changed")
}

// TestMemory02_ReindexEquivalence guards MEM-02: dropping all memory_* tables
// and rebuilding from the vault reproduces the incrementally-maintained index.
// memory_node_stats is excluded by design — access stats are runtime state,
// not derivable from files; their reset on rebuild is accepted v1 behavior.
func TestMemory02_ReindexEquivalence(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	// Pass 1: two fresh nodes. Episode B carries a ## Provenance section so the
	// derived memory_provenance index is exercised by the reindex-equivalence
	// comparison (MEM-02 extension, Phase-5 slice-3).
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5IXA", "entity", "Alpha")
	a.Aliases = []string{"alpha", "C0AAAAAAA"}
	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5IXB", "episode", "Beta")
	b.Body = "# Beta\n\n## Story\nA thing happened.\n\n## Provenance\n" +
		"- C0AAAAAAA 1700000000.000100\n- mail:abc123 1700000500\n"
	writeNodes(t, v, a, b)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Pass 2: edit A (title + aliases), add C — C links to A so LinksIn (and
	// therefore importance_score) actually differs between fixtures instead of
	// comparing two zeros (Slice A, MEM-16 extension of this guard).
	a.Title = "Alpha Prime"
	a.Aliases = []string{"alpha-prime"}
	a.Body = "# Alpha Prime\n\nRewritten body.\n"
	c := vaultTestNode("sum_01ARZ3NDEKTSV4RRFFQ69G5IXC", "rollup", "Q3 rollup")
	c.Body = "# Q3 rollup\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5IXA]] for background.\n"
	writeNodes(t, v, a, c)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Pass 3: delete B (its provenance rows must vanish with it), edit C —
	// keep its link to A alongside a surviving ## Provenance section — and
	// touch A once more (a trivial body edit) so A gets reparsed NOW THAT C's
	// link to it is already committed (pass 2): this is what makes A's
	// persisted importance_score reflect LinksIn=1 by the end of the
	// incremental history, matching what a fresh Rebuild computes from the
	// FINAL vault state.
	require.NoError(t, os.Remove(filepath.Join(v.path, "episodes", b.ID+".md")))
	c.Body = "# Q3 rollup\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5IXA]] for background.\n\n## Provenance\n" +
		"- C0AAAAAAA 1700100000.000200\n"
	a.Body = "# Alpha Prime\n\nRewritten body, revision two.\n"
	writeNodes(t, v, c, a)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	incremental := dumpIndex(t, d)
	require.Len(t, incremental.Nodes, 2, "sanity: A and C survive")
	for _, row := range incremental.Nodes {
		if row.ID == a.ID {
			require.Equal(t, 1.0, row.ImportanceScore,
				"sanity: A's persisted importance reflects C's link-in, not a trivial zero")
		}
	}

	_, err = Rebuild(v, d, t.Logf)
	require.NoError(t, err)
	rebuilt := dumpIndex(t, d)

	assert.Equal(t, incremental, rebuilt)
}
