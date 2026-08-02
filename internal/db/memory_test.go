package db

import (
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// memTestNode returns a valid node row for tests, overridable via mutate.
func memTestNode(id string, mutate func(*MemoryNodeRow)) MemoryNodeRow {
	row := MemoryNodeRow{
		ID:          id,
		Type:        "entity",
		Tier:        "long",
		Status:      "active",
		Title:       "Test Node " + id,
		Path:        "entities/" + id + ".md",
		ContentHash: "hash-" + id,
		IndexedAt:   "2026-07-15T00:00:00Z",
	}
	if mutate != nil {
		mutate(&row)
	}
	return row
}

func TestUpsertMemoryNodeRoundTrip(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_alpha", nil)
	if err := db.UpsertMemoryNode(row, "Alpha body about deployments", []string{"C0123abc", "alpha-project"}); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	got, err := db.GetMemoryNode("ent_alpha")
	if err != nil {
		t.Fatalf("GetMemoryNode: %v", err)
	}
	if got != row {
		t.Errorf("round-trip mismatch:\n got %+v\nwant %+v", got, row)
	}

	// Aliases resolve to the node.
	nodeID, err := db.LookupMemoryAlias("alpha-project")
	if err != nil {
		t.Fatalf("LookupMemoryAlias: %v", err)
	}
	if nodeID != "ent_alpha" {
		t.Errorf("alias resolved to %q, want ent_alpha", nodeID)
	}

	// FTS row is searchable.
	hits, err := db.SearchMemoryFTS("deployments", 10)
	if err != nil {
		t.Fatalf("SearchMemoryFTS: %v", err)
	}
	if len(hits) != 1 || hits[0].ID != "ent_alpha" {
		t.Fatalf("FTS hits = %+v, want one hit for ent_alpha", hits)
	}
}

func TestUpsertMemoryNodeReplacesAliasesAndFTS(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_beta", nil)
	if err := db.UpsertMemoryNode(row, "first body oldword", []string{"old-alias"}); err != nil {
		t.Fatalf("first upsert: %v", err)
	}

	// Re-upsert with different aliases and body.
	row.Title = "Renamed Beta"
	row.ContentHash = "hash-2"
	if err := db.UpsertMemoryNode(row, "second body newword", []string{"new-alias"}); err != nil {
		t.Fatalf("second upsert: %v", err)
	}

	// Old alias is gone, new alias works — replacement is atomic per node.
	if _, err := db.LookupMemoryAlias("old-alias"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("old alias lookup err = %v, want sql.ErrNoRows", err)
	}
	nodeID, err := db.LookupMemoryAlias("new-alias")
	if err != nil || nodeID != "ent_beta" {
		t.Errorf("new alias lookup = (%q, %v), want (ent_beta, nil)", nodeID, err)
	}

	// Node row was updated, not duplicated.
	got, err := db.GetMemoryNode("ent_beta")
	if err != nil {
		t.Fatalf("GetMemoryNode: %v", err)
	}
	if got.Title != "Renamed Beta" || got.ContentHash != "hash-2" {
		t.Errorf("node not updated: %+v", got)
	}

	// FTS row replaced: old term gone, new term found, and only one row.
	if hits, err := db.SearchMemoryFTS("oldword", 10); err != nil || len(hits) != 0 {
		t.Errorf("oldword hits = %+v (err %v), want none", hits, err)
	}
	hits, err := db.SearchMemoryFTS("newword", 10)
	if err != nil || len(hits) != 1 {
		t.Fatalf("newword hits = %+v (err %v), want exactly one", hits, err)
	}

	var ftsCount int
	if err := db.QueryRow(`SELECT count(*) FROM memory_fts WHERE id = 'ent_beta'`).Scan(&ftsCount); err != nil {
		t.Fatalf("counting fts rows: %v", err)
	}
	if ftsCount != 1 {
		t.Errorf("fts rows for ent_beta = %d, want 1", ftsCount)
	}
}

func TestLookupMemoryAliasCaseInsensitive(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_chan", nil)
	if err := db.UpsertMemoryNode(row, "channel node", []string{"C0123abc"}); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	nodeID, err := db.LookupMemoryAlias("c0123ABC")
	if err != nil {
		t.Fatalf("LookupMemoryAlias: %v", err)
	}
	if nodeID != "ent_chan" {
		t.Errorf("alias resolved to %q, want ent_chan", nodeID)
	}

	if _, err := db.LookupMemoryAlias("nonexistent"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("unknown alias err = %v, want sql.ErrNoRows", err)
	}
}

// TestMirrorAliasNodeIDsNumericAnchor: the mirror alias set is anchored on a
// fully-numeric id (LIKE prefix + NOT GLOB non-digit rejection), so model-minted
// concept aliases like target:notanumber, digit-leading target:1abc, and a bare
// target: are excluded while target:12 / track:7 are returned.
func TestMirrorAliasNodeIDsNumericAnchor(t *testing.T) {
	db := openTestDB(t)

	seed := []struct {
		nodeID, alias string
	}{
		{"ent_t12", "target:12"},
		{"ent_tfoo", "target:notanumber"},
		{"ent_t1abc", "target:1abc"},
		{"ent_tbare", "target:"},
		{"ent_tcase", "Target:foo"},
		{"ent_tupper", "TARGET:34"},
		{"ent_k7", "track:7"},
	}
	for _, s := range seed {
		if err := db.UpsertMemoryNode(memTestNode(s.nodeID, nil), "body", []string{s.alias}); err != nil {
			t.Fatalf("UpsertMemoryNode(%s): %v", s.nodeID, err)
		}
	}

	got, err := db.MirrorAliasNodeIDs()
	if err != nil {
		t.Fatalf("MirrorAliasNodeIDs: %v", err)
	}
	if _, ok := got["target:notanumber"]; ok {
		t.Errorf("non-numeric alias target:notanumber leaked into the mirror set")
	}
	if _, ok := got["target:1abc"]; ok {
		t.Errorf("digit-leading alias target:1abc leaked into the mirror set")
	}
	if _, ok := got["target:"]; ok {
		t.Errorf("bare alias target: leaked into the mirror set")
	}
	for _, a := range []string{"Target:foo", "TARGET:34"} {
		if _, ok := got[a]; ok {
			t.Errorf("case-variant alias %s leaked into the mirror set", a)
		}
	}
	if got["target:12"] != "ent_t12" {
		t.Errorf("target:12 = %q, want ent_t12", got["target:12"])
	}
	if got["track:7"] != "ent_k7" {
		t.Errorf("track:7 = %q, want ent_k7", got["track:7"])
	}
}

func TestGetMemoryNodeNotFound(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.GetMemoryNode("ent_missing"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("GetMemoryNode err = %v, want sql.ErrNoRows", err)
	}
}

func TestListMemoryNodesOrderedByID(t *testing.T) {
	db := openTestDB(t)

	for _, id := range []string{"ep_b", "ent_a", "sum_c"} {
		if err := db.UpsertMemoryNode(memTestNode(id, nil), "body", nil); err != nil {
			t.Fatalf("UpsertMemoryNode(%s): %v", id, err)
		}
	}

	rows, err := db.ListMemoryNodes()
	if err != nil {
		t.Fatalf("ListMemoryNodes: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("got %d nodes, want 3", len(rows))
	}
	want := []string{"ent_a", "ep_b", "sum_c"}
	for i, id := range want {
		if rows[i].ID != id {
			t.Errorf("rows[%d].ID = %q, want %q", i, rows[i].ID, id)
		}
	}
}

// TestMemoryNodeSubjectConfidenceRoundTrip: memory_nodes.subject/.confidence
// (Task 1, migration 00019) round-trip through UpsertMemoryNode/GetMemoryNode
// /ListMemoryNodes, and DisputePending reads false when the node carries no
// memory_dispute_flags row.
func TestMemoryNodeSubjectConfidenceRoundTrip(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("bel_alpha", func(r *MemoryNodeRow) {
		r.Type = "belief"
		r.Subject = "ent_alpha"
		r.Confidence = 0.7
	})
	if err := db.UpsertMemoryNode(row, "belief body", nil); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	got, err := db.GetMemoryNode("bel_alpha")
	if err != nil {
		t.Fatalf("GetMemoryNode: %v", err)
	}
	if got.Subject != "ent_alpha" || got.Confidence != 0.7 {
		t.Errorf("GetMemoryNode subject/confidence = (%q, %v), want (ent_alpha, 0.7)", got.Subject, got.Confidence)
	}
	if got.DisputePending {
		t.Error("DisputePending = true, want false (no memory_dispute_flags row)")
	}

	rows, err := db.ListMemoryNodes()
	if err != nil {
		t.Fatalf("ListMemoryNodes: %v", err)
	}
	if len(rows) != 1 || rows[0].Subject != "ent_alpha" || rows[0].Confidence != 0.7 {
		t.Fatalf("ListMemoryNodes = %+v, want one row with subject ent_alpha confidence 0.7", rows)
	}
}

func TestListBeliefsForSubjects(t *testing.T) {
	d := openTestDB(t)

	mustUpsert := func(row MemoryNodeRow) {
		t.Helper()
		if err := d.UpsertMemoryNode(row, "body", nil); err != nil {
			t.Fatalf("UpsertMemoryNode %s: %v", row.ID, err)
		}
	}
	mustUpsert(memTestNode("bel_active", func(r *MemoryNodeRow) { r.Type = "belief"; r.Subject = "ent_alice"; r.Status = "active" }))
	mustUpsert(memTestNode("bel_shaken", func(r *MemoryNodeRow) { r.Type = "belief"; r.Subject = "ent_alice"; r.Status = "shaken" }))
	mustUpsert(memTestNode("bel_retired", func(r *MemoryNodeRow) { r.Type = "belief"; r.Subject = "ent_alice"; r.Status = "retired" }))
	mustUpsert(memTestNode("bel_other_subject", func(r *MemoryNodeRow) { r.Type = "belief"; r.Subject = "ent_bob"; r.Status = "active" }))
	mustUpsert(memTestNode("ent_alice", func(r *MemoryNodeRow) { r.Type = "entity" }))

	got, err := d.ListBeliefsForSubjects([]string{"ent_alice"})
	if err != nil {
		t.Fatalf("ListBeliefsForSubjects: %v", err)
	}
	var ids []string
	for _, r := range got {
		ids = append(ids, r.ID)
	}
	if len(ids) != 2 {
		t.Fatalf("ListBeliefsForSubjects = %v, want exactly [bel_active bel_shaken] (retired excluded, other-subject excluded, entity excluded)", ids)
	}
	for _, want := range []string{"bel_active", "bel_shaken"} {
		found := false
		for _, id := range ids {
			found = found || id == want
		}
		if !found {
			t.Errorf("ListBeliefsForSubjects missing %s", want)
		}
	}
}

// TestMemoryNodeImportanceScoreRoundTrip: memory_nodes.importance_score
// (Slice A, migration 00037, MEM-16) round-trips through
// UpsertMemoryNode/GetMemoryNode/ListMemoryNodes.
func TestMemoryNodeImportanceScoreRoundTrip(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_importance", func(r *MemoryNodeRow) {
		r.ImportanceScore = 6.5
	})
	if err := db.UpsertMemoryNode(row, "importance body", nil); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	got, err := db.GetMemoryNode("ent_importance")
	if err != nil {
		t.Fatalf("GetMemoryNode: %v", err)
	}
	if got.ImportanceScore != 6.5 {
		t.Errorf("GetMemoryNode.ImportanceScore = %v, want 6.5", got.ImportanceScore)
	}

	rows, err := db.ListMemoryNodes()
	if err != nil {
		t.Fatalf("ListMemoryNodes: %v", err)
	}
	if len(rows) != 1 || rows[0].ImportanceScore != 6.5 {
		t.Fatalf("ListMemoryNodes = %+v, want one row with importance_score 6.5", rows)
	}

	// A re-upsert with a different score replaces it (not additive).
	row.ImportanceScore = 1.0
	row.ContentHash = "hash-2"
	if err := db.UpsertMemoryNode(row, "importance body v2", nil); err != nil {
		t.Fatalf("second upsert: %v", err)
	}
	got, err = db.GetMemoryNode("ent_importance")
	if err != nil {
		t.Fatalf("GetMemoryNode after re-upsert: %v", err)
	}
	if got.ImportanceScore != 1.0 {
		t.Errorf("GetMemoryNode.ImportanceScore after re-upsert = %v, want 1.0", got.ImportanceScore)
	}
}

// seedProvenanceRow is a small test helper: inserts one memory_provenance row
// directly (bypassing the memory package's provenanceRows), for tests that
// only need the DB-layer index populated, not a real vault file.
func seedProvenanceRow(t *testing.T, d *DB, nodeID, channelID, tsRaw string, tsUnix float64, senderID string) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO memory_provenance (node_id, scheme, channel_id, ts_raw, ts_unix, sender_id)
		VALUES (?, '', ?, ?, ?, ?)`, nodeID, channelID, tsRaw, tsUnix, senderID); err != nil {
		t.Fatalf("seeding provenance row for %s: %v", nodeID, err)
	}
}

// TestListShortTierEpisodesForAliases: recency-ordered short-tier episodes
// whose provenance sender_id matches one of the given aliases (Slice B).
// Long-tier episodes, tombstones, and episodes with no matching sender are
// excluded; a node with multiple matching provenance rows appears once,
// ordered by its MOST RECENT matching ref.
func TestListShortTierEpisodesForAliases(t *testing.T) {
	d := openTestDB(t)

	mustUpsert := func(row MemoryNodeRow) {
		t.Helper()
		if err := d.UpsertMemoryNode(row, row.ID+" body", nil); err != nil {
			t.Fatalf("UpsertMemoryNode %s: %v", row.ID, err)
		}
	}
	mustUpsert(memTestNode("ep_recent", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "short" }))
	mustUpsert(memTestNode("ep_older", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "short" }))
	mustUpsert(memTestNode("ep_long_tier", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "long" }))
	mustUpsert(memTestNode("ep_tombstoned", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "short"; r.Status = "tombstone" }))
	mustUpsert(memTestNode("ep_other_sender", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "short" }))

	seedProvenanceRow(t, d, "ep_recent", "C1", "200.0", 200.0, "U1")
	seedProvenanceRow(t, d, "ep_older", "C1", "100.0", 100.0, "U1")
	// ep_recent also has an OLDER ref from the same sender — must still be
	// deduped to one row, ordered by its most recent ref.
	seedProvenanceRow(t, d, "ep_recent", "C1", "50.0", 50.0, "U1")
	seedProvenanceRow(t, d, "ep_long_tier", "C1", "300.0", 300.0, "U1")    // wrong tier, excluded
	seedProvenanceRow(t, d, "ep_tombstoned", "C1", "400.0", 400.0, "U1")   // tombstone, excluded
	seedProvenanceRow(t, d, "ep_other_sender", "C1", "500.0", 500.0, "U2") // wrong sender, excluded

	got, err := d.ListShortTierEpisodesForAliases([]string{"U1"}, 10)
	if err != nil {
		t.Fatalf("ListShortTierEpisodesForAliases: %v", err)
	}
	var ids []string
	for _, r := range got {
		ids = append(ids, r.ID)
	}
	if len(ids) != 2 || ids[0] != "ep_recent" || ids[1] != "ep_older" {
		t.Fatalf("ListShortTierEpisodesForAliases ids = %v, want [ep_recent ep_older] in that order", ids)
	}

	// Empty aliases: no query, clean empty result.
	empty, err := d.ListShortTierEpisodesForAliases(nil, 10)
	if err != nil || len(empty) != 0 {
		t.Fatalf("ListShortTierEpisodesForAliases(nil) = (%v, %v), want (empty, nil)", empty, err)
	}

	// Limit truncates to the most recent.
	limited, err := d.ListShortTierEpisodesForAliases([]string{"U1"}, 1)
	if err != nil || len(limited) != 1 || limited[0].ID != "ep_recent" {
		t.Fatalf("ListShortTierEpisodesForAliases limit=1 = %+v, want just ep_recent", limited)
	}
}

// TestUpdateMemoryNodeImportanceScore: a narrow single-column update that
// changes only importance_score, leaving every other field (content_hash,
// title, etc.) untouched — the primitive Reconcile's phase-B refinement
// pass uses to correct a node's importance after the whole vaultSubdirs
// walk completes (Slice A follow-up, added 2026-07-18, MEM-16).
func TestUpdateMemoryNodeImportanceScore(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_importance_narrow", func(r *MemoryNodeRow) {
		r.ImportanceScore = 1.0
		r.Title = "Original Title"
	})
	if err := db.UpsertMemoryNode(row, "body", nil); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	if err := db.UpdateMemoryNodeImportanceScore("ent_importance_narrow", 7.0); err != nil {
		t.Fatalf("UpdateMemoryNodeImportanceScore: %v", err)
	}

	got, err := db.GetMemoryNode("ent_importance_narrow")
	if err != nil {
		t.Fatalf("GetMemoryNode: %v", err)
	}
	if got.ImportanceScore != 7.0 {
		t.Errorf("ImportanceScore = %v, want 7.0", got.ImportanceScore)
	}
	if got.Title != "Original Title" {
		t.Errorf("Title = %q, want unchanged %q — this must be a NARROW update", got.Title, "Original Title")
	}
}

// TestGetMemoryNodeBody: the new narrow FTS-body reader returns the exact
// body last upserted, and sql.ErrNoRows for an id with no FTS row — the
// contract memory's Reconcile (index.go) relies on to read a node's PRIOR
// body BEFORE UpsertMemoryNode overwrites it (whole-branch review follow-up,
// 2026-07-19, MEM-16 addendum — closing the link-removal asymmetry).
func TestGetMemoryNodeBody(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_body_read", nil)
	if err := db.UpsertMemoryNode(row, "# Body\n\nSee [[ent_other]].\n", nil); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	body, err := db.GetMemoryNodeBody("ent_body_read")
	if err != nil {
		t.Fatalf("GetMemoryNodeBody: %v", err)
	}
	if body != "# Body\n\nSee [[ent_other]].\n" {
		t.Errorf("GetMemoryNodeBody = %q, want the exact body last upserted", body)
	}

	if _, err := db.GetMemoryNodeBody("ent_does_not_exist"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("GetMemoryNodeBody for unknown id: err = %v, want sql.ErrNoRows", err)
	}
}

// TestMemoryNodeSubjectConfidenceDefaults: non-belief nodes (and the memTestNode
// helper's zero-value Subject/Confidence) persist as ""/0.
func TestMemoryNodeSubjectConfidenceDefaults(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_plain", nil)
	if err := db.UpsertMemoryNode(row, "plain body", nil); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}
	got, err := db.GetMemoryNode("ent_plain")
	if err != nil {
		t.Fatalf("GetMemoryNode: %v", err)
	}
	if got.Subject != "" || got.Confidence != 0 {
		t.Errorf("defaults = (%q, %v), want (\"\", 0)", got.Subject, got.Confidence)
	}
}

func TestSearchMemoryFTSSnippetAndTombstones(t *testing.T) {
	db := openTestDB(t)

	live := memTestNode("ent_live", nil)
	if err := db.UpsertMemoryNode(live, "the migration rollout finished cleanly", nil); err != nil {
		t.Fatalf("upsert live: %v", err)
	}
	tomb := memTestNode("ent_tomb", func(r *MemoryNodeRow) {
		r.Status = "tombstone"
		r.RedirectTo = "ent_live"
	})
	if err := db.UpsertMemoryNode(tomb, "the migration rollout duplicate page", nil); err != nil {
		t.Fatalf("upsert tombstone: %v", err)
	}

	hits, err := db.SearchMemoryFTS("migration rollout", 10)
	if err != nil {
		t.Fatalf("SearchMemoryFTS: %v", err)
	}
	if len(hits) != 1 {
		t.Fatalf("got %d hits %+v, want 1 (tombstone excluded)", len(hits), hits)
	}
	h := hits[0]
	if h.ID != "ent_live" || h.Type != "entity" || h.Title != live.Title {
		t.Errorf("hit = %+v, want ent_live/entity/%q", h, live.Title)
	}
	if !strings.Contains(h.Snippet, "migration") {
		t.Errorf("snippet %q does not contain matched term", h.Snippet)
	}

	// Hostile input must not break the MATCH query.
	if _, err := db.SearchMemoryFTS(`"unbalanced OR (dropme`, 10); err != nil {
		t.Errorf("hostile query errored: %v", err)
	}
	if hits, err := db.SearchMemoryFTS("   ", 10); err != nil || hits != nil {
		t.Errorf("blank query = (%+v, %v), want (nil, nil)", hits, err)
	}
}

// TestSearchMemoryFTSCandidates: same sanitized MATCH as SearchMemoryFTS, but
// returns full MemoryNodeRows (importance_score included) plus the raw rank,
// best-match-first — SearchMemoryFTS itself is untouched (still
// memory_recall's legacy path).
func TestSearchMemoryFTSCandidates(t *testing.T) {
	d := openTestDB(t)

	strong := memTestNode("ent_strong", func(r *MemoryNodeRow) { r.ImportanceScore = 1 })
	weak := memTestNode("ent_weak", func(r *MemoryNodeRow) { r.ImportanceScore = 9 })
	if err := d.UpsertMemoryNode(strong, "deployments of deployments for deployments rollout", nil); err != nil {
		t.Fatalf("UpsertMemoryNode strong: %v", err)
	}
	if err := d.UpsertMemoryNode(weak, "deployments happened once, briefly", nil); err != nil {
		t.Fatalf("UpsertMemoryNode weak: %v", err)
	}

	cands, err := d.SearchMemoryFTSCandidates("deployments", 10)
	if err != nil {
		t.Fatalf("SearchMemoryFTSCandidates: %v", err)
	}
	if len(cands) != 2 {
		t.Fatalf("SearchMemoryFTSCandidates returned %d candidates, want 2", len(cands))
	}
	// Best FTS match (more mentions of the term) ranks first, REGARDLESS of
	// importance_score — this function does not re-rank; RetrieveByQuery does.
	if cands[0].Row.ID != "ent_strong" {
		t.Errorf("cands[0].Row.ID = %q, want ent_strong (strongest FTS match)", cands[0].Row.ID)
	}
	if cands[0].Row.ImportanceScore != 1 {
		t.Errorf("cands[0].Row.ImportanceScore = %v, want 1 (the full row, not just id/title)", cands[0].Row.ImportanceScore)
	}
	// A better match has a MORE NEGATIVE (smaller) rank.
	if !(cands[0].Rank < cands[1].Rank) {
		t.Errorf("cands[0].Rank = %v, cands[1].Rank = %v; want cands[0] (better match) more negative", cands[0].Rank, cands[1].Rank)
	}
}

func TestBumpMemoryAccess(t *testing.T) {
	db := openTestDB(t)

	if err := db.UpsertMemoryNode(memTestNode("ent_hot", nil), "body", nil); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	if err := db.BumpMemoryAccess("ent_hot"); err != nil {
		t.Fatalf("first bump: %v", err)
	}
	if err := db.BumpMemoryAccess("ent_hot"); err != nil {
		t.Fatalf("second bump: %v", err)
	}

	var count int
	var lastAccessed sql.NullString
	err := db.QueryRow(`SELECT access_count, last_accessed_at FROM memory_node_stats WHERE node_id = 'ent_hot'`).
		Scan(&count, &lastAccessed)
	if err != nil {
		t.Fatalf("reading stats: %v", err)
	}
	if count != 2 {
		t.Errorf("access_count = %d, want 2", count)
	}
	if !lastAccessed.Valid || lastAccessed.String == "" {
		t.Errorf("last_accessed_at not set: %+v", lastAccessed)
	}
}

func TestMemoryWatermarkRoundTrip(t *testing.T) {
	db := openTestDB(t)

	if _, err := db.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}

	ts, err := db.MemoryWatermark()
	if err != nil {
		t.Fatalf("MemoryWatermark: %v", err)
	}
	if ts != 0 {
		t.Errorf("initial watermark = %v, want 0", ts)
	}

	if err := db.SetMemoryWatermark(1752537600.125); err != nil {
		t.Fatalf("SetMemoryWatermark: %v", err)
	}
	ts, err = db.MemoryWatermark()
	if err != nil {
		t.Fatalf("MemoryWatermark after set: %v", err)
	}
	if ts != 1752537600.125 {
		t.Errorf("watermark = %v, want 1752537600.125", ts)
	}
}

func TestDeleteMemoryNode(t *testing.T) {
	db := openTestDB(t)

	if err := db.UpsertMemoryNode(memTestNode("ent_gone", nil), "delete me body", []string{"gone-alias"}); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}
	if err := db.BumpMemoryAccess("ent_gone"); err != nil {
		t.Fatalf("BumpMemoryAccess: %v", err)
	}

	if err := db.DeleteMemoryNode("ent_gone"); err != nil {
		t.Fatalf("DeleteMemoryNode: %v", err)
	}

	if _, err := db.GetMemoryNode("ent_gone"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("node still present, err = %v", err)
	}
	if _, err := db.LookupMemoryAlias("gone-alias"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("alias still present, err = %v", err)
	}
	for _, q := range []string{
		`SELECT count(*) FROM memory_node_stats WHERE node_id = 'ent_gone'`,
		`SELECT count(*) FROM memory_fts WHERE id = 'ent_gone'`,
	} {
		var n int
		if err := db.QueryRow(q).Scan(&n); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		if n != 0 {
			t.Errorf("%s = %d, want 0", q, n)
		}
	}
}

func TestDropMemoryIndex(t *testing.T) {
	db := openTestDB(t)

	if err := db.UpsertMemoryNode(memTestNode("ent_x", nil), "body x", []string{"x-alias"}); err != nil {
		t.Fatalf("upsert x: %v", err)
	}
	if err := db.UpsertMemoryNode(memTestNode("ep_y", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "short" }), "body y", []string{"situation:42"}); err != nil {
		t.Fatalf("upsert y: %v", err)
	}
	if err := db.BumpMemoryAccess("ent_x"); err != nil {
		t.Fatalf("bump: %v", err)
	}

	if err := db.DropMemoryIndex(); err != nil {
		t.Fatalf("DropMemoryIndex: %v", err)
	}

	for _, table := range []string{"memory_nodes", "memory_aliases", "memory_node_stats", "memory_fts"} {
		var n int
		if err := db.QueryRow(`SELECT count(*) FROM ` + table).Scan(&n); err != nil {
			t.Fatalf("counting %s: %v", table, err)
		}
		if n != 0 {
			t.Errorf("%s has %d rows after drop, want 0", table, n)
		}
	}

	// The drop disables foreign_keys for the duration and must re-enable it: a
	// reindex left with FK enforcement stuck OFF silently voids integrity for
	// every later statement on the connection (fix #5).
	var fk int
	if err := db.QueryRow(`PRAGMA foreign_keys`).Scan(&fk); err != nil {
		t.Fatalf("reading foreign_keys: %v", err)
	}
	if fk != 1 {
		t.Errorf("foreign_keys = %d after DropMemoryIndex, want 1 (re-enabled)", fk)
	}
}

// epNode returns an episode node row for provenance tests.
func epNode(id string) MemoryNodeRow {
	return memTestNode(id, func(r *MemoryNodeRow) {
		r.Type = "episode"
		r.Tier = "short"
		r.Path = "episodes/" + id + ".md"
	})
}

// provRows reads memory_provenance for a node, ordered deterministically.
func provRows(t *testing.T, db *DB, nodeID string) []ProvenanceRow {
	t.Helper()
	rows, err := db.Query(`SELECT node_id, scheme, channel_id, ts_raw, ts_unix
		FROM memory_provenance WHERE node_id = ? ORDER BY channel_id, ts_raw`, nodeID)
	if err != nil {
		t.Fatalf("query provenance: %v", err)
	}
	defer rows.Close()
	var out []ProvenanceRow
	for rows.Next() {
		var p ProvenanceRow
		if err := rows.Scan(&p.NodeID, &p.Scheme, &p.ChannelID, &p.TSRaw, &p.TSUnix); err != nil {
			t.Fatalf("scan provenance: %v", err)
		}
		out = append(out, p)
	}
	return out
}

// TestUpsertMemoryNodeWritesProvenance: provenance rows ride the same upsert
// tx as aliases/FTS (delete-then-insert wholesale), and a re-upsert with a
// changed provenance set replaces the node's rows entirely.
func TestUpsertMemoryNodeWritesProvenance(t *testing.T) {
	db := openTestDB(t)

	prov := []ProvenanceRow{
		{NodeID: "ep_prov1", Scheme: "", ChannelID: "C0AAA", TSRaw: "1700000000.000100", TSUnix: 1700000000.0001},
		{NodeID: "ep_prov1", Scheme: "mail", ChannelID: "mail:abc", TSRaw: "1700000500", TSUnix: 1700000500},
	}
	if err := db.UpsertMemoryNode(epNode("ep_prov1"), "body", nil, prov...); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	got := provRows(t, db, "ep_prov1")
	if len(got) != 2 {
		t.Fatalf("got %d provenance rows, want 2: %+v", len(got), got)
	}
	// mail: ref keeps its scheme; the bare Slack ref is scheme "".
	if got[0].ChannelID != "C0AAA" || got[0].Scheme != "" {
		t.Errorf("row0 = %+v, want C0AAA scheme ''", got[0])
	}
	if got[1].ChannelID != "mail:abc" || got[1].Scheme != "mail" {
		t.Errorf("row1 = %+v, want mail:abc scheme 'mail'", got[1])
	}

	// Re-upsert with a wholly different provenance set replaces the old rows.
	if err := db.UpsertMemoryNode(epNode("ep_prov1"), "body2", nil,
		ProvenanceRow{NodeID: "ep_prov1", ChannelID: "C0BBB", TSRaw: "1700009999.000000", TSUnix: 1700009999}); err != nil {
		t.Fatalf("re-upsert: %v", err)
	}
	got = provRows(t, db, "ep_prov1")
	if len(got) != 1 || got[0].ChannelID != "C0BBB" {
		t.Fatalf("after re-upsert got %+v, want a single C0BBB row", got)
	}
}

// TestDeleteMemoryNodeClearsProvenance: DeleteMemoryNode removes the node's
// provenance rows in the same delete tx (the alias/FTS precedent).
func TestDeleteMemoryNodeClearsProvenance(t *testing.T) {
	db := openTestDB(t)
	if err := db.UpsertMemoryNode(epNode("ep_del"), "body", nil,
		ProvenanceRow{NodeID: "ep_del", ChannelID: "C0AAA", TSRaw: "1700000000.000000", TSUnix: 1700000000}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if err := db.DeleteMemoryNode("ep_del"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if got := provRows(t, db, "ep_del"); len(got) != 0 {
		t.Errorf("provenance survived delete: %+v", got)
	}
}

// TestDropMemoryIndexClearsProvenance: memory_provenance is vault-derived, so
// DropMemoryIndex empties it (unlike the runtime engagement/hint side tables).
func TestDropMemoryIndexClearsProvenance(t *testing.T) {
	db := openTestDB(t)
	if err := db.UpsertMemoryNode(epNode("ep_drop"), "body", nil,
		ProvenanceRow{NodeID: "ep_drop", ChannelID: "C0AAA", TSRaw: "1700000000.000000", TSUnix: 1700000000}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if err := db.DropMemoryIndex(); err != nil {
		t.Fatalf("drop: %v", err)
	}
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM memory_provenance`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Errorf("memory_provenance has %d rows after drop, want 0", n)
	}
}

// TestListEpisodesForChannelWindow: the window query returns episodes whose
// per-channel provenance SPAN [min,max] overlaps (from,to], is boundary-correct
// (excludes from, includes to), and never returns prefixed-scheme (mail:/cal:)
// refs for a bare Slack channel id or tombstoned nodes.
func TestListEpisodesForChannelWindow(t *testing.T) {
	db := openTestDB(t)

	mk := func(id string, prov ...ProvenanceRow) {
		if err := db.UpsertMemoryNode(epNode(id), "body", nil, prov...); err != nil {
			t.Fatalf("upsert %s: %v", id, err)
		}
	}
	// ep_in: inside the window. ep_before: at the exclusive lower bound.
	// ep_at_to: at the inclusive upper bound. ep_after: past it. ep_other:
	// another channel. ep_mail: a mail: ref that must not match a bare id.
	mk("ep_in", ProvenanceRow{NodeID: "ep_in", ChannelID: "C0AAA", TSRaw: "150", TSUnix: 150})
	mk("ep_before", ProvenanceRow{NodeID: "ep_before", ChannelID: "C0AAA", TSRaw: "100", TSUnix: 100})
	mk("ep_at_to", ProvenanceRow{NodeID: "ep_at_to", ChannelID: "C0AAA", TSRaw: "200", TSUnix: 200})
	mk("ep_after", ProvenanceRow{NodeID: "ep_after", ChannelID: "C0AAA", TSRaw: "201", TSUnix: 201})
	mk("ep_other", ProvenanceRow{NodeID: "ep_other", ChannelID: "C0BBB", TSRaw: "150", TSUnix: 150})
	mk("ep_mail", ProvenanceRow{NodeID: "ep_mail", Scheme: "mail", ChannelID: "mail:C0AAA", TSRaw: "150", TSUnix: 150})

	// Tombstoned node with an in-window ref must be excluded.
	tomb := epNode("ep_tomb")
	tomb.Status = "tombstone"
	tomb.RedirectTo = "ep_in"
	if err := db.UpsertMemoryNode(tomb, "body", nil,
		ProvenanceRow{NodeID: "ep_tomb", ChannelID: "C0AAA", TSRaw: "150", TSUnix: 150}); err != nil {
		t.Fatalf("upsert tomb: %v", err)
	}

	// Span fixtures: refs OUTSIDE (100,200] but story span overlapping it —
	// the 2026-07-20 instrument fix (episodes cite sparse key messages, so a
	// window falling between two cited refs must still select the episode).
	mk("ep_span", ProvenanceRow{NodeID: "ep_span", ChannelID: "C0AAA", TSRaw: "50", TSUnix: 50},
		ProvenanceRow{NodeID: "ep_span", ChannelID: "C0AAA", TSRaw: "250", TSUnix: 250})
	// Span entirely before the window (max == from is still OUT: bounds are (from,to]).
	mk("ep_span_before", ProvenanceRow{NodeID: "ep_span_before", ChannelID: "C0AAA", TSRaw: "40", TSUnix: 40},
		ProvenanceRow{NodeID: "ep_span_before", ChannelID: "C0AAA", TSRaw: "100", TSUnix: 100})
	// Span starting exactly at to (min == to is IN: inclusive-high).
	mk("ep_span_at_to", ProvenanceRow{NodeID: "ep_span_at_to", ChannelID: "C0AAA", TSRaw: "200", TSUnix: 200},
		ProvenanceRow{NodeID: "ep_span_at_to", ChannelID: "C0AAA", TSRaw: "300", TSUnix: 300})
	// Span crossing the window but in ANOTHER channel — per-channel spans only.
	mk("ep_span_other", ProvenanceRow{NodeID: "ep_span_other", ChannelID: "C0BBB", TSRaw: "50", TSUnix: 50},
		ProvenanceRow{NodeID: "ep_span_other", ChannelID: "C0BBB", TSRaw: "250", TSUnix: 250})
	// Fractional-suffix span: raw min 200.00005 > to(200), but the SQL
	// HAVING floors both aggregates to whole seconds first (matching
	// loadRenderEpisodes' Go-side flooring), so floored min 200 <= to(200)
	// selects it even though the unfloored comparison would not.
	mk("ep_frac", ProvenanceRow{NodeID: "ep_frac", ChannelID: "C0AAA", TSRaw: "200.000050", TSUnix: 200.00005},
		ProvenanceRow{NodeID: "ep_frac", ChannelID: "C0AAA", TSRaw: "300.5", TSUnix: 300.5})

	ids, err := db.ListEpisodesForChannelWindow("C0AAA", 100, 200)
	if err != nil {
		t.Fatalf("window query: %v", err)
	}
	// (100,200] with span semantics: ep_in (ref inside), ep_at_to (span
	// [200,200], min <= to), ep_span (span [50,250] crosses the window),
	// ep_span_at_to (span [200,300], min == to), ep_frac (floored span
	// [200,300], floored min == to). Excluded: ep_before (span [100,100],
	// max == from), ep_span_before (max == from), ep_after,
	// ep_span_other/ep_other (other channel), ep_mail (scheme ref),
	// ep_tomb (tombstone).
	want := []string{"ep_at_to", "ep_frac", "ep_in", "ep_span", "ep_span_at_to"}
	if strings.Join(ids, ",") != strings.Join(want, ",") {
		t.Errorf("window ids = %v, want %v", ids, want)
	}
}

// TestDropMemoryIndexWithDisputeFlagDoesNotViolateFK guards a live-found bug:
// memory_dispute_flags.node_id REFERENCES memory_nodes(id), so a full drop
// that deletes memory_nodes without first clearing a live dispute flag trips
// the FK and the whole reindex fails — found live when a single MEM-06
// downgrade's dispute flag broke `watchtower memory reindex`. Dropping the
// flag here is exactly the "self-healing on reindex" its own doc comment
// promises: a still-conflicting belief is simply re-flagged by the next
// belief/reflection pass.
func TestDropMemoryIndexWithDisputeFlagDoesNotViolateFK(t *testing.T) {
	db := openTestDB(t)

	if err := db.UpsertMemoryNode(memTestNode("bel_x", func(r *MemoryNodeRow) { r.Type = "belief"; r.Tier = "long" }), "body", nil); err != nil {
		t.Fatalf("upsert bel_x: %v", err)
	}
	if err := db.SetDisputePending("bel_x", "owner-rank belief challenged"); err != nil {
		t.Fatalf("SetDisputePending: %v", err)
	}

	if err := db.DropMemoryIndex(); err != nil {
		t.Fatalf("DropMemoryIndex: %v", err)
	}

	var n int
	if err := db.QueryRow(`SELECT count(*) FROM memory_dispute_flags`).Scan(&n); err != nil {
		t.Fatalf("counting memory_dispute_flags: %v", err)
	}
	if n != 0 {
		t.Errorf("memory_dispute_flags has %d rows after drop, want 0", n)
	}
}

func TestRecordEntityHintsDedupesByPair(t *testing.T) {
	db := openTestDB(t)

	// Same (hint, episode) recorded twice → one row (re-extraction must not
	// double-count); a different episode for the same hint is a second row.
	if err := db.RecordEntityHints([]EntityHint{
		{Hint: "hsm", EpisodeID: "ep_1"},
		{Hint: "hsm", EpisodeID: "ep_1"},
		{Hint: "hsm", EpisodeID: "ep_2"},
		{Hint: "", EpisodeID: "ep_3"},     // empty hint skipped
		{Hint: "phishing", EpisodeID: ""}, // empty episode skipped
	}); err != nil {
		t.Fatalf("RecordEntityHints: %v", err)
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM memory_entity_hints`).Scan(&count); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 2 {
		t.Fatalf("hint rows = %d, want 2 (deduped pair, empties skipped)", count)
	}
}

func TestListPromotableHintsThresholdAndUnpromoted(t *testing.T) {
	db := openTestDB(t)

	if err := db.RecordEntityHints([]EntityHint{
		{Hint: "hsm", EpisodeID: "ep_1"},
		{Hint: "hsm", EpisodeID: "ep_2"},
		{Hint: "hsm", EpisodeID: "ep_3"},
		{Hint: "phishing", EpisodeID: "ep_4"}, // only 1 distinct episode
	}); err != nil {
		t.Fatalf("RecordEntityHints: %v", err)
	}

	// Threshold 3: only "hsm" qualifies, with all three episodes.
	got, err := db.ListPromotableHints(3)
	if err != nil {
		t.Fatalf("ListPromotableHints: %v", err)
	}
	if len(got) != 1 || got[0].Hint != "hsm" {
		t.Fatalf("got %+v, want one hint hsm", got)
	}
	if strings.Join(got[0].EpisodeIDs, ",") != "ep_1,ep_2,ep_3" {
		t.Errorf("episode ids = %v, want ep_1,ep_2,ep_3", got[0].EpisodeIDs)
	}

	// After marking hsm promoted, it drops out of the list.
	if err := db.MarkHintPromoted("hsm", "ent_concept"); err != nil {
		t.Fatalf("MarkHintPromoted: %v", err)
	}
	got, err = db.ListPromotableHints(3)
	if err != nil {
		t.Fatalf("ListPromotableHints after promote: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %+v, want none (hsm now promoted)", got)
	}

	// The rows carry the promotion marker.
	var promotedTo string
	if err := db.QueryRow(`SELECT promoted_to FROM memory_entity_hints WHERE hint = 'hsm' LIMIT 1`).Scan(&promotedTo); err != nil {
		t.Fatalf("read promoted_to: %v", err)
	}
	if promotedTo != "ent_concept" {
		t.Errorf("promoted_to = %q, want ent_concept", promotedTo)
	}
}

// TestEntityHintsSurviveDropIndex: the hint table is runtime accumulation, not
// derivable from the vault, so DropMemoryIndex (MEM-02 reindex) must NOT clear
// it — a reindex never resets promotion progress.
func TestEntityHintsSurviveDropIndex(t *testing.T) {
	db := openTestDB(t)

	if err := db.RecordEntityHints([]EntityHint{
		{Hint: "hsm", EpisodeID: "ep_1"},
		{Hint: "hsm", EpisodeID: "ep_2"},
	}); err != nil {
		t.Fatalf("RecordEntityHints: %v", err)
	}
	if err := db.DropMemoryIndex(); err != nil {
		t.Fatalf("DropMemoryIndex: %v", err)
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM memory_entity_hints`).Scan(&count); err != nil {
		t.Fatalf("count after drop: %v", err)
	}
	if count != 2 {
		t.Errorf("hint rows after DropMemoryIndex = %d, want 2 (hints must survive reindex)", count)
	}
}

// seedExtractMessage inserts a channel-message pair for extract-query tests.
func seedExtractMessage(t *testing.T, db *DB, channelID, ts, userID, text string) {
	t.Helper()
	if _, err := db.Exec(`INSERT OR IGNORE INTO channels (id, name, type) VALUES (?, ?, 'public')`,
		channelID, "chan-"+channelID); err != nil {
		t.Fatalf("seeding channel %s: %v", channelID, err)
	}
	if _, err := db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES (?, ?, ?, ?)`,
		channelID, ts, userID, text); err != nil {
		t.Fatalf("seeding message %s/%s: %v", channelID, ts, err)
	}
}

// TestListMemoryExtractMessagesDrainsBoundarySecond: ts_unix is truncated to
// whole seconds, so a LIMIT cut inside a same-second group would let the
// watermark (which advances to a loaded message's ts_unix and reloads with a
// strict >) permanently skip the unloaded rows of that second. The query must
// drain the boundary: when the limit cuts inside a second, ALL rows sharing
// that second are returned, even across channels.
func TestListMemoryExtractMessagesDrainsBoundarySecond(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.Exec(`INSERT INTO users (id, name) VALUES ('U1', 'alice')`); err != nil {
		t.Fatalf("seeding user: %v", err)
	}
	// Two messages one second earlier, then five sharing one second across two channels.
	seedExtractMessage(t, db, "C1", "1752570000.000001", "U1", "early one")
	seedExtractMessage(t, db, "C1", "1752570000.000002", "U1", "early two")
	seedExtractMessage(t, db, "C1", "1752570001.000001", "U1", "same second 1")
	seedExtractMessage(t, db, "C1", "1752570001.000002", "U1", "same second 2")
	seedExtractMessage(t, db, "C2", "1752570001.000003", "U1", "same second 3")
	seedExtractMessage(t, db, "C2", "1752570001.000004", "U1", "same second 4")
	seedExtractMessage(t, db, "C1", "1752570001.000005", "U1", "same second 5")

	// limit=3 cuts inside second 1752570001 → the whole second must be loaded.
	msgs, err := db.ListMemoryExtractMessages(0, 3)
	if err != nil {
		t.Fatalf("ListMemoryExtractMessages: %v", err)
	}
	if len(msgs) != 7 {
		t.Fatalf("got %d messages, want 7 (limit cut inside the boundary second must drain it)", len(msgs))
	}
	for i := 1; i < len(msgs); i++ {
		if msgs[i].TSUnix < msgs[i-1].TSUnix {
			t.Errorf("messages out of ts_unix order at %d: %v after %v", i, msgs[i].TSUnix, msgs[i-1].TSUnix)
		}
	}

	// A limit past the end returns everything with no phantom drain.
	msgs, err = db.ListMemoryExtractMessages(0, 100)
	if err != nil {
		t.Fatalf("ListMemoryExtractMessages (big limit): %v", err)
	}
	if len(msgs) != 7 {
		t.Errorf("got %d messages with a big limit, want 7", len(msgs))
	}

	// A limit cutting exactly at a second boundary stays exact: the two early
	// messages fill the limit and the later second is left as debt.
	msgs, err = db.ListMemoryExtractMessages(0, 2)
	if err != nil {
		t.Fatalf("ListMemoryExtractMessages (limit 2): %v", err)
	}
	if len(msgs) != 7-5 {
		// limit=2 loads the two early rows; the boundary second is 1752570000,
		// which is already fully loaded — no drain needed beyond it... unless
		// the boundary drain pulls the rest of second 1752570000 (none left).
		t.Fatalf("got %d messages with limit 2, want 2", len(msgs))
	}
	for _, m := range msgs {
		if m.TSUnix != 1752570000 {
			t.Errorf("limit 2 loaded ts_unix %v, want only second 1752570000", m.TSUnix)
		}
	}
}

// TestListMemoryExtractMessagesAuthorless: a message whose user_id has no
// users row (deleted/ex-employee author never synced) must still be
// extracted, with the raw user_id as the author fallback.
func TestListMemoryExtractMessagesAuthorless(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.Exec(`INSERT INTO users (id, name, is_bot) VALUES ('UBOT', 'botty', 1)`); err != nil {
		t.Fatalf("seeding bot user: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO users (id, name, is_muted_for_llm) VALUES ('UMUTED', 'muted', 1)`); err != nil {
		t.Fatalf("seeding muted user: %v", err)
	}
	seedExtractMessage(t, db, "C1", "1752570000.000001", "UGONE", "authorless but human")
	seedExtractMessage(t, db, "C1", "1752570000.000002", "UBOT", "bot chatter")
	seedExtractMessage(t, db, "C1", "1752570000.000003", "UMUTED", "muted user")
	// Empty user_id is this codebase's bot_message convention (see
	// channel_stats.go): it must NOT pass through the authorless branch.
	seedExtractMessage(t, db, "C1", "1752570000.000004", "", "bot event without user")

	msgs, err := db.ListMemoryExtractMessages(0, 100)
	if err != nil {
		t.Fatalf("ListMemoryExtractMessages: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("got %d messages, want 1 (authorless kept; bot, muted and empty-user_id excluded)", len(msgs))
	}
	if msgs[0].Author != "UGONE" {
		t.Errorf("author = %q, want raw user_id fallback %q", msgs[0].Author, "UGONE")
	}
	if msgs[0].Text != "authorless but human" {
		t.Errorf("text = %q", msgs[0].Text)
	}
}

// TestMemoryWatermarkFreshWorkspace: a brand-new DB has no workspace row yet;
// the watermark must read as 0, not fail the whole run.
func TestMemoryWatermarkFreshWorkspace(t *testing.T) {
	db := openTestDB(t)

	ts, err := db.MemoryWatermark()
	if err != nil {
		t.Fatalf("MemoryWatermark on fresh workspace: %v", err)
	}
	if ts != 0 {
		t.Errorf("watermark = %v, want 0", ts)
	}
}

// TestMessageExistsIgnoresDeleted: the MEM-01 write-time provenance check
// counts only live messages — a tombstoned (is_deleted = 1) message would
// 404 for the owner just like a hallucinated ref.
func TestMessageExistsIgnoresDeleted(t *testing.T) {
	db := openTestDB(t)

	if err := db.UpsertMessage(Message{ChannelID: "C001", TS: "1700000000.000001", UserID: "U001", Text: "hello"}); err != nil {
		t.Fatalf("UpsertMessage: %v", err)
	}
	ok, err := db.MessageExists("C001", "1700000000.000001")
	if err != nil || !ok {
		t.Fatalf("MessageExists(live) = %v, %v; want true, nil", ok, err)
	}

	if _, err := db.Exec(`UPDATE messages SET is_deleted = 1 WHERE channel_id = 'C001'`); err != nil {
		t.Fatalf("mark deleted: %v", err)
	}
	ok, err = db.MessageExists("C001", "1700000000.000001")
	if err != nil {
		t.Fatalf("MessageExists(deleted): %v", err)
	}
	if ok {
		t.Error("MessageExists must be false for a deleted message")
	}
}

func TestMessageSender(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1SND', '100.000100', 'U9', 'hi')`); err != nil {
		t.Fatalf("seeding message: %v", err)
	}

	sender, err := d.MessageSender("C1SND", "100.000100")
	if err != nil {
		t.Fatalf("MessageSender: %v", err)
	}
	if sender != "U9" {
		t.Errorf("MessageSender = %q, want U9", sender)
	}

	if _, err := d.MessageSender("C1SND", "nonexistent"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("MessageSender on missing message = %v, want sql.ErrNoRows", err)
	}
}

func TestGmailMessageSender(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`INSERT INTO google_accounts (email, label) VALUES ('a@x.com', 'A')`); err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO gmail_messages (account_id, id, from_email) VALUES (1, 'gm1', 'sender@example.com')`); err != nil {
		t.Fatalf("seeding gmail message: %v", err)
	}

	sender, err := d.GmailMessageSender("gm1")
	if err != nil {
		t.Fatalf("GmailMessageSender: %v", err)
	}
	if sender != "sender@example.com" {
		t.Errorf("GmailMessageSender = %q, want sender@example.com", sender)
	}

	if _, err := d.GmailMessageSender("nonexistent"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("GmailMessageSender on missing message = %v, want sql.ErrNoRows", err)
	}
}

// TestMemoryChatTurnFloorRoundTrip: the owner-chat ingest floor (Task 1,
// migration 00019) defaults to 0 on a fresh workspace and persists after
// SetMemoryChatTurnFloor, mirroring MemoryIngestFloor/SetMemoryIngestFloor.
func TestMemoryChatTurnFloorRoundTrip(t *testing.T) {
	db := openTestDB(t)

	floor, err := db.MemoryChatTurnFloor()
	if err != nil {
		t.Fatalf("MemoryChatTurnFloor on fresh workspace: %v", err)
	}
	if floor != 0 {
		t.Errorf("initial floor = %d, want 0", floor)
	}

	if _, err := db.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	if err := db.SetMemoryChatTurnFloor(42); err != nil {
		t.Fatalf("SetMemoryChatTurnFloor: %v", err)
	}
	floor, err = db.MemoryChatTurnFloor()
	if err != nil {
		t.Fatalf("MemoryChatTurnFloor after set: %v", err)
	}
	if floor != 42 {
		t.Errorf("floor after set = %d, want 42", floor)
	}
}

// TestDisputePendingSetList covers the memory_dispute_flags side table helpers
// (Task 1): SetDisputePending flags a belief, ListDisputePendingBeliefs returns
// only flagged belief nodes (oldest first) capped to limit, and clearing the
// side-table row (the inbox detector's same-tx DELETE path) flips the derived
// DisputePending back to false.
func TestDisputePendingSetList(t *testing.T) {
	db := openTestDB(t)

	belief1 := memTestNode("bel_one", func(r *MemoryNodeRow) { r.Type = "belief" })
	belief2 := memTestNode("bel_two", func(r *MemoryNodeRow) { r.Type = "belief" })
	entity := memTestNode("ent_three", nil) // not a belief — must never surface
	for _, row := range []MemoryNodeRow{belief1, belief2, entity} {
		if err := db.UpsertMemoryNode(row, "body", nil); err != nil {
			t.Fatalf("UpsertMemoryNode(%s): %v", row.ID, err)
		}
	}

	if err := db.SetDisputePending("bel_one", "evidence conflicts"); err != nil {
		t.Fatalf("SetDisputePending(bel_one): %v", err)
	}
	// Flag the entity too, to prove ListDisputePendingBeliefs filters by type,
	// not merely by side-table presence.
	if err := db.SetDisputePending("ent_three", "should never surface"); err != nil {
		t.Fatalf("SetDisputePending(ent_three): %v", err)
	}
	if err := db.SetDisputePending("bel_two", "also conflicts"); err != nil {
		t.Fatalf("SetDisputePending(bel_two): %v", err)
	}

	got, err := db.GetMemoryNode("bel_one")
	if err != nil {
		t.Fatalf("GetMemoryNode: %v", err)
	}
	if !got.DisputePending {
		t.Error("GetMemoryNode(bel_one).DisputePending = false, want true")
	}

	pending, err := db.ListDisputePendingBeliefs(10)
	if err != nil {
		t.Fatalf("ListDisputePendingBeliefs: %v", err)
	}
	if len(pending) != 2 {
		t.Fatalf("ListDisputePendingBeliefs = %+v, want 2 belief rows (entity excluded)", pending)
	}
	// Ordered by flagged_at, then node id as a tie-break for same-second
	// flags (as in this test) — bel_one was flagged first either way.
	if pending[0].ID != "bel_one" || pending[1].ID != "bel_two" {
		t.Errorf("ListDisputePendingBeliefs order = [%s, %s], want [bel_one, bel_two]",
			pending[0].ID, pending[1].ID)
	}

	// Cap bounds the result.
	capped, err := db.ListDisputePendingBeliefs(1)
	if err != nil {
		t.Fatalf("ListDisputePendingBeliefs(1): %v", err)
	}
	if len(capped) != 1 || capped[0].ID != "bel_one" {
		t.Errorf("ListDisputePendingBeliefs(1) = %+v, want [bel_one]", capped)
	}

	// Clearing the side-table row (the inbox detector's same-tx DELETE path)
	// flips the derived DisputePending back to false.
	if _, err := db.Exec(`DELETE FROM memory_dispute_flags WHERE node_id = 'bel_one'`); err != nil {
		t.Fatalf("clearing dispute flag: %v", err)
	}
	got, err = db.GetMemoryNode("bel_one")
	if err != nil {
		t.Fatalf("GetMemoryNode after clear: %v", err)
	}
	if got.DisputePending {
		t.Error("DisputePending still true after clearing the side-table row")
	}
	remaining, err := db.ListDisputePendingBeliefs(10)
	if err != nil {
		t.Fatalf("ListDisputePendingBeliefs after clear: %v", err)
	}
	if len(remaining) != 1 || remaining[0].ID != "bel_two" {
		t.Errorf("ListDisputePendingBeliefs after clear = %+v, want [bel_two]", remaining)
	}
}

// createChatTablesForTest creates the Swift-owned chat tables
// (chat_conversations + chat_messages) exactly the way the Desktop app's GRDB
// ensureTable helpers do. They are ABSENT from Go's goose schema (Phase-4
// resolved ambiguity #1: created lazily by the Desktop app the first time the
// owner opens a Discuss chat), so every Go chat reader must tolerate both their
// presence and their absence.
func createChatTablesForTest(t *testing.T, db *DB) {
	t.Helper()
	stmts := []string{
		`CREATE TABLE chat_conversations (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			title TEXT NOT NULL DEFAULT '',
			session_id TEXT,
			context_type TEXT,
			context_id TEXT,
			created_at REAL NOT NULL,
			updated_at REAL NOT NULL)`,
		`CREATE TABLE chat_messages (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
			role TEXT NOT NULL,
			text TEXT NOT NULL,
			created_at REAL NOT NULL)`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("create chat table: %v", err)
		}
	}
}

func insertChatConversation(t *testing.T, db *DB, contextType, contextID string) int64 {
	t.Helper()
	res, err := db.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('', ?, ?, 0, 0)`, contextType, contextID)
	if err != nil {
		t.Fatalf("insert chat conversation: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("chat conversation id: %v", err)
	}
	return id
}

func insertChatMessage(t *testing.T, db *DB, convID int64, role, text string, createdAt float64) int64 {
	t.Helper()
	res, err := db.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at)
		VALUES (?, ?, ?, ?)`, convID, role, text, createdAt)
	if err != nil {
		t.Fatalf("insert chat message: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("chat message id: %v", err)
	}
	return id
}

// TestChatTablesPresent: the guard reports false on a fresh goose schema (the
// Swift chat tables do not exist) and true once they are created.
func TestChatTablesPresent(t *testing.T) {
	db := openTestDB(t)

	present, err := db.ChatTablesPresent()
	if err != nil {
		t.Fatalf("ChatTablesPresent (absent): %v", err)
	}
	if present {
		t.Fatal("chat tables must be reported absent on a fresh goose schema")
	}

	createChatTablesForTest(t, db)
	present, err = db.ChatTablesPresent()
	if err != nil {
		t.Fatalf("ChatTablesPresent (present): %v", err)
	}
	if !present {
		t.Fatal("chat tables must be reported present after creation")
	}
}

// TestOwnerChatTurnExists: the MEM-09 authenticity check resolves only
// role='user' turns of situation conversations — never an assistant turn, a
// wrong ts, a non-situation conversation, or an unknown conversation.
func TestOwnerChatTurnExists(t *testing.T) {
	db := openTestDB(t)
	createChatTablesForTest(t, db)
	sit := insertChatConversation(t, db, "situation", "42")
	other := insertChatConversation(t, db, "track", "9") // non-situation context
	insertChatMessage(t, db, sit, "user", "owner said", 1720000000.0)
	insertChatMessage(t, db, sit, "assistant", "secretary said", 1720000100.0)
	insertChatMessage(t, db, other, "user", "elsewhere", 1720000200.0)

	cases := []struct {
		name string
		conv int64
		ts   int64
		want bool
	}{
		{"owner user turn", sit, 1720000000, true},
		{"assistant turn is not owner", sit, 1720000100, false},
		{"wrong ts", sit, 1720000999, false},
		{"non-situation conversation", other, 1720000200, false},
		{"unknown conversation", 999, 1720000000, false},
	}
	for _, c := range cases {
		got, err := db.OwnerChatTurnExists(c.conv, c.ts, []string{"situation"})
		if err != nil {
			t.Fatalf("%s: OwnerChatTurnExists: %v", c.name, err)
		}
		if got != c.want {
			t.Errorf("%s: OwnerChatTurnExists(%d,%d) = %v, want %v", c.name, c.conv, c.ts, got, c.want)
		}
	}
}

// TestOwnerChatTurnExistsWidenedContextTypes: with the widened context-type set
// {situation,target,track} a track owner turn resolves; with only {situation} it
// does not (the flag-off MEM-09 shape). The IN-clause is parameterized, so a
// context type carrying a quote is harmless (no injection).
func TestOwnerChatTurnExistsWidenedContextTypes(t *testing.T) {
	db := openTestDB(t)
	createChatTablesForTest(t, db)
	track := insertChatConversation(t, db, "track", "9")
	insertChatMessage(t, db, track, "user", "owner on a track", 1720000000.0)

	off, err := db.OwnerChatTurnExists(track, 1720000000, []string{"situation"})
	if err != nil {
		t.Fatalf("OwnerChatTurnExists (situation-only): %v", err)
	}
	if off {
		t.Error("a track turn must NOT resolve under the situation-only set (MEM-09 flag-off shape)")
	}

	on, err := db.OwnerChatTurnExists(track, 1720000000, []string{"situation", "target", "track"})
	if err != nil {
		t.Fatalf("OwnerChatTurnExists (widened): %v", err)
	}
	if !on {
		t.Error("a track turn must resolve under the widened set")
	}

	// A context type carrying a quote is a normal (unmatched) value, not injection.
	safe, err := db.OwnerChatTurnExists(track, 1720000000, []string{`track' OR '1'='1`})
	if err != nil {
		t.Fatalf("OwnerChatTurnExists (quoted): %v", err)
	}
	if safe {
		t.Error("a quoted context type is parameterized, not interpolated — no match")
	}
}

// TestOwnerChatTurnExistsTruncatesFractionalSecond: created_at is a REAL unix
// second; the evidence-line ts is whole seconds, so the lookup must match a
// fractional-second turn against its truncated second (CAST ... AS INTEGER).
func TestOwnerChatTurnExistsTruncatesFractionalSecond(t *testing.T) {
	db := openTestDB(t)
	createChatTablesForTest(t, db)
	sit := insertChatConversation(t, db, "situation", "1")
	insertChatMessage(t, db, sit, "user", "x", 1720000000.75)

	ok, err := db.OwnerChatTurnExists(sit, 1720000000, []string{"situation"})
	if err != nil {
		t.Fatalf("OwnerChatTurnExists: %v", err)
	}
	if !ok {
		t.Error("a fractional-second turn must match its truncated whole second")
	}
}

// TestListOwnerChatTurns: only role='user' turns of situation conversations are
// returned, ordered by id, filtered strictly above the floor, carrying the
// situation context_id, whole-second ts, and verbatim text.
func TestListOwnerChatTurns(t *testing.T) {
	db := openTestDB(t)
	createChatTablesForTest(t, db)
	sit := insertChatConversation(t, db, "situation", "42")
	other := insertChatConversation(t, db, "track", "9")
	u1 := insertChatMessage(t, db, sit, "user", "first", 1720000000.0)
	insertChatMessage(t, db, sit, "assistant", "reply", 1720000100.0)
	u2 := insertChatMessage(t, db, sit, "user", "second", 1720000200.0)
	insertChatMessage(t, db, other, "user", "elsewhere", 1720000300.0)

	turns, err := db.ListOwnerChatTurns(0, []string{"situation"})
	if err != nil {
		t.Fatalf("ListOwnerChatTurns: %v", err)
	}
	if len(turns) != 2 {
		t.Fatalf("ListOwnerChatTurns = %+v, want 2 user situation turns", turns)
	}
	if turns[0].ID != u1 || turns[1].ID != u2 {
		t.Errorf("turn ids = [%d,%d], want [%d,%d]", turns[0].ID, turns[1].ID, u1, u2)
	}
	if turns[0].ConversationID != sit || turns[0].ContextID != "42" || turns[0].ContextType != "situation" {
		t.Errorf("turn0 conversation=%d context=%q/%q, want %d \"situation\"/\"42\"", turns[0].ConversationID, turns[0].ContextType, turns[0].ContextID, sit)
	}
	if turns[0].TurnTS != 1720000000 {
		t.Errorf("turn0 ts = %d, want 1720000000", turns[0].TurnTS)
	}
	if turns[0].Text != "first" {
		t.Errorf("turn0 text = %q, want \"first\"", turns[0].Text)
	}

	// Floor filters strictly above: floor=u1 drops u1, keeps u2.
	above, err := db.ListOwnerChatTurns(u1, []string{"situation"})
	if err != nil {
		t.Fatalf("ListOwnerChatTurns(floor): %v", err)
	}
	if len(above) != 1 || above[0].ID != u2 {
		t.Errorf("ListOwnerChatTurns(%d) = %+v, want only u2 (%d)", u1, above, u2)
	}
}

// TestListOwnerChatTurnsWidenedContextTypes: the situation-only set returns only
// the situation turn (MEM-09 flag-off shape); the widened set additionally
// returns target and track owner turns, each carrying its context_type/id.
func TestListOwnerChatTurnsWidenedContextTypes(t *testing.T) {
	db := openTestDB(t)
	createChatTablesForTest(t, db)
	sit := insertChatConversation(t, db, "situation", "42")
	trk := insertChatConversation(t, db, "track", "9")
	tgt := insertChatConversation(t, db, "target", "3")
	insertChatMessage(t, db, sit, "user", "on situation", 1720000000.0)
	insertChatMessage(t, db, trk, "user", "on track", 1720000100.0)
	insertChatMessage(t, db, tgt, "user", "on target", 1720000200.0)

	only, err := db.ListOwnerChatTurns(0, []string{"situation"})
	if err != nil {
		t.Fatalf("ListOwnerChatTurns (situation): %v", err)
	}
	if len(only) != 1 || only[0].ContextType != "situation" {
		t.Fatalf("situation-only set = %+v, want just the situation turn", only)
	}

	all, err := db.ListOwnerChatTurns(0, []string{"situation", "target", "track"})
	if err != nil {
		t.Fatalf("ListOwnerChatTurns (widened): %v", err)
	}
	if len(all) != 3 {
		t.Fatalf("widened set = %+v, want 3 turns", all)
	}
	byType := map[string]string{}
	for _, tn := range all {
		byType[tn.ContextType] = tn.ContextID
	}
	if byType["track"] != "9" || byType["target"] != "3" || byType["situation"] != "42" {
		t.Errorf("context ids by type = %+v, want situation=42 track=9 target=3", byType)
	}
}

// TestListOwnerChatTurnsAbsentTables: on a headless daemon the Swift chat
// tables never exist — the read is a clean empty no-op, never an error.
func TestListOwnerChatTurnsAbsentTables(t *testing.T) {
	db := openTestDB(t)

	turns, err := db.ListOwnerChatTurns(0, []string{"situation"})
	if err != nil {
		t.Fatalf("absent chat tables must read empty, got error: %v", err)
	}
	if turns != nil {
		t.Fatalf("absent chat tables must yield nil turns, got %+v", turns)
	}
}

// TestMemoryMigrationDownUpCycle: 00017's Down drops its ALTER-added columns
// (workspace.memory_last_extracted_ts, pipeline_runs cache token columns), so
// a down; up cycle is clean — Up's ADD COLUMN would otherwise fail on the
// leftovers.
func TestMemoryMigrationDownUpCycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cycle.db")
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer d.Close()

	if err := goose.Down(d.DB, "migrations"); err != nil {
		t.Fatalf("goose down: %v", err)
	}
	if err := goose.Up(d.DB, "migrations"); err != nil {
		t.Fatalf("goose up after down: %v", err)
	}

	// The re-added columns are usable (exactly once — a duplicate would have
	// failed the Up above).
	if _, err := d.Exec(`UPDATE workspace SET memory_last_extracted_ts = 0`); err != nil {
		t.Errorf("memory_last_extracted_ts missing after cycle: %v", err)
	}
	if _, err := d.Exec(`UPDATE pipeline_runs SET cache_read_tokens = 0, cache_creation_tokens = 0`); err != nil {
		t.Errorf("cache token columns missing after cycle: %v", err)
	}
}

// TestMemoryGmailWatermarkRoundTrip (MemoryGmailWatermark/
// SetMemoryGmailWatermark) moved onto a per-account google_accounts column by
// migration 00043 — see
// TestGoogleAccount_MemoryGmailWatermark_RoundTrip/TestGoogleAccount_MemoryGmailWatermark_MissingRowReturnsZero
// in google_accounts_test.go.

// TestMemoryCalendarWatermarkRoundTrip: the calendar episode-build watermark
// (Task 2, migration 00033) defaults to 0 on a fresh workspace and persists
// after SetMemoryCalendarWatermark, mirroring MemoryGmailWatermark/
// SetMemoryGmailWatermark — a FOURTH, independent memory watermark.
func TestMemoryCalendarWatermarkRoundTrip(t *testing.T) {
	db := openTestDB(t)

	ts, err := db.MemoryCalendarWatermark()
	if err != nil {
		t.Fatalf("MemoryCalendarWatermark on fresh workspace: %v", err)
	}
	if ts != 0 {
		t.Errorf("initial watermark = %v, want 0", ts)
	}

	if _, err := db.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	if err := db.SetMemoryCalendarWatermark(1700000000); err != nil {
		t.Fatalf("SetMemoryCalendarWatermark: %v", err)
	}
	ts, err = db.MemoryCalendarWatermark()
	if err != nil {
		t.Fatalf("MemoryCalendarWatermark after set: %v", err)
	}
	if ts != 1700000000 {
		t.Errorf("watermark after set = %v, want 1700000000", ts)
	}
}

// TestCalendarEventExists: the write-time existence check behind the cal:
// provenance scheme resolves an existing calendar_events id and cleanly misses
// an unknown one.
func TestCalendarEventExists(t *testing.T) {
	db := openTestDB(t)
	if err := db.UpsertCalendar(0, CalendarCalendar{ID: "cal1", Name: "C", SyncedAt: "2026-01-01T00:00:00Z"}); err != nil {
		t.Fatalf("UpsertCalendar: %v", err)
	}
	if err := db.UpsertCalendarEvent(CalendarEvent{
		ID: "evt_1", CalendarID: "cal1", Title: "Standup",
		StartTime: "2026-07-15T10:00:00Z", EndTime: "2026-07-15T10:30:00Z",
	}); err != nil {
		t.Fatalf("UpsertCalendarEvent: %v", err)
	}

	ok, err := db.CalendarEventExists("evt_1")
	if err != nil {
		t.Fatalf("CalendarEventExists(evt_1): %v", err)
	}
	if !ok {
		t.Errorf("existing event should resolve")
	}

	ok, err = db.CalendarEventExists("missing")
	if err != nil {
		t.Fatalf("CalendarEventExists(missing): %v", err)
	}
	if ok {
		t.Errorf("a missing event id must not resolve")
	}
}

// TestCalendarEventExistsAbsentTablePropagates: calendar_events is a
// migration-guaranteed base table, so a query failure propagates as a genuine
// lookup error rather than being masked as a clean miss.
func TestCalendarEventExistsAbsentTablePropagates(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.Exec(`DROP TABLE calendar_events`); err != nil {
		t.Fatalf("dropping calendar_events: %v", err)
	}
	if _, err := db.CalendarEventExists("anything"); err == nil {
		t.Errorf("a failed calendar_events lookup must propagate, not be masked as a miss")
	}
}

// TestListCalendarEventsForExtract: only ENDED events (end_time before now)
// whose end_time is above (watermark - lookback) are returned, oldest-end
// first; future events and events below the re-scan floor are excluded.
func TestListCalendarEventsForExtract(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.UpsertCalendar(0, CalendarCalendar{ID: "cal1", Name: "C", SyncedAt: "2026-01-01T00:00:00Z"}))
	now := time.Now().UTC()
	mk := func(id string, endOffset time.Duration) {
		start := now.Add(endOffset - time.Hour)
		end := now.Add(endOffset)
		require.NoError(t, db.UpsertCalendarEvent(CalendarEvent{
			ID: id, CalendarID: "cal1", Title: id,
			StartTime: start.Format(time.RFC3339), EndTime: end.Format(time.RFC3339),
		}))
	}
	mk("past-2h", -2*time.Hour) // ended
	mk("past-1h", -1*time.Hour) // ended, newer
	mk("future", 2*time.Hour)   // not ended yet — excluded

	// Watermark 0, lookback 2 days → all past events returned, oldest-end first.
	evs, err := db.ListCalendarEventsForExtract(0, 2, 100)
	require.NoError(t, err)
	require.Len(t, evs, 2, "only the two ended events")
	assert.Equal(t, "past-2h", evs[0].ID, "oldest end_time first")
	assert.Equal(t, "past-1h", evs[1].ID)
	assert.Greater(t, evs[1].EndUnix, evs[0].EndUnix)
	assert.NotZero(t, evs[0].StartUnix, "start unix decoded for the cal: ref ts")

	// Watermark just below past-1h's end, lookback 0 → only past-1h (past-2h is
	// below the floor).
	wm := float64(now.Add(-90 * time.Minute).Unix())
	evs, err = db.ListCalendarEventsForExtract(wm, 0, 100)
	require.NoError(t, err)
	require.Len(t, evs, 1)
	assert.Equal(t, "past-1h", evs[0].ID)
}

// TestTrackSubjectRefs: a track's subject refs are its channel_ids +
// participant user ids + assignee/requester/owner user ids, deduped, and an
// unknown track id is a clean empty read.
func TestTrackSubjectRefs(t *testing.T) {
	db := openTestDB(t)
	res, err := db.Exec(`INSERT INTO tracks (text, channel_ids, participants, assignee_user_id, requester_user_id, owner_user_id)
		VALUES ('do the thing', ?, ?, 'UASSIGN', 'UREQ', 'UOWN')`,
		`["C1","C2"]`, `[{"user_id":"UP1"},{"user_id":"UP2"},{"user_id":""}]`)
	require.NoError(t, err)
	tid, err := res.LastInsertId()
	require.NoError(t, err)

	refs, err := db.TrackSubjectRefs(int(tid))
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"C1", "C2", "UP1", "UP2", "UASSIGN", "UREQ", "UOWN"}, refs)

	none, err := db.TrackSubjectRefs(999999)
	require.NoError(t, err)
	assert.Empty(t, none, "an unknown track id is a clean empty read")
}

// TestTrackIDsForTarget: the tracks linked to a target are returned; a target
// with no linked track is a clean empty read.
func TestTrackIDsForTarget(t *testing.T) {
	db := openTestDB(t)
	tgtID, err := db.CreateTarget(Target{Text: "Ship the thing", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	res, err := db.Exec(`INSERT INTO tracks (text, linked_target_id) VALUES ('t1', ?)`, tgtID)
	require.NoError(t, err)
	t1, _ := res.LastInsertId()

	ids, err := db.TrackIDsForTarget(int(tgtID))
	require.NoError(t, err)
	assert.Equal(t, []int{int(t1)}, ids)

	none, err := db.TrackIDsForTarget(999999)
	require.NoError(t, err)
	assert.Empty(t, none, "a target with no linked track maps to nothing")
}

// TestMemoryInteractionFloorRoundTrip: the 5D interaction-ingest floor (Task
// 3, migration 00042) defaults to 0 on a fresh workspace and persists after
// SetMemoryInteractionFloor, mirroring MemoryChatTurnFloor/
// SetMemoryChatTurnFloor.
func TestMemoryInteractionFloorRoundTrip(t *testing.T) {
	db := openTestDB(t)

	floor, err := db.MemoryInteractionFloor()
	if err != nil {
		t.Fatalf("MemoryInteractionFloor on fresh workspace: %v", err)
	}
	if floor != 0 {
		t.Errorf("initial floor = %d, want 0", floor)
	}

	if _, err := db.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	if err := db.SetMemoryInteractionFloor(7); err != nil {
		t.Fatalf("SetMemoryInteractionFloor: %v", err)
	}
	floor, err = db.MemoryInteractionFloor()
	if err != nil {
		t.Fatalf("MemoryInteractionFloor after set: %v", err)
	}
	if floor != 7 {
		t.Errorf("floor after set = %d, want 7", floor)
	}
}

// TestBumpEngagementAccumulatesEngagedAndDismissed covers the memory_engagement
// side table helpers (Task 3): BumpEngagement upserts and increments the right
// counter per call, stamping last_interaction_at each time, and GetEngagement
// on an unseen node reads as (0, 0, nil) rather than an error (the
// memory_node_stats upsert precedent, sql.ErrNoRows folded to a zero value).
func TestBumpEngagementAccumulatesEngagedAndDismissed(t *testing.T) {
	db := openTestDB(t)

	if err := db.UpsertMemoryNode(memTestNode("ent_x", nil), "body x", nil); err != nil {
		t.Fatalf("upsert ent_x: %v", err)
	}

	engaged, dismissed, err := db.GetEngagement("ent_x")
	if err != nil {
		t.Fatalf("GetEngagement on unseen node: %v", err)
	}
	if engaged != 0 || dismissed != 0 {
		t.Errorf("initial engagement = (%d, %d), want (0, 0)", engaged, dismissed)
	}

	if err := db.BumpEngagement("ent_x", true, "2026-07-16T00:00:00Z"); err != nil {
		t.Fatalf("BumpEngagement(engaged): %v", err)
	}
	if err := db.BumpEngagement("ent_x", true, "2026-07-16T00:01:00Z"); err != nil {
		t.Fatalf("BumpEngagement(engaged) again: %v", err)
	}
	if err := db.BumpEngagement("ent_x", false, "2026-07-16T00:02:00Z"); err != nil {
		t.Fatalf("BumpEngagement(dismissed): %v", err)
	}

	engaged, dismissed, err = db.GetEngagement("ent_x")
	if err != nil {
		t.Fatalf("GetEngagement after bumps: %v", err)
	}
	if engaged != 2 || dismissed != 1 {
		t.Errorf("engagement after bumps = (%d, %d), want (2, 1)", engaged, dismissed)
	}

	var lastAt string
	if err := db.QueryRow(`SELECT last_interaction_at FROM memory_engagement WHERE node_id = 'ent_x'`).Scan(&lastAt); err != nil {
		t.Fatalf("reading last_interaction_at: %v", err)
	}
	if lastAt != "2026-07-16T00:02:00Z" {
		t.Errorf("last_interaction_at = %q, want the most recent bump's timestamp", lastAt)
	}
}

// TestEngagementSurvivesDropIndex: memory_engagement is runtime state derived
// from interaction rows, MEM-02-exempt like memory_entity_hints (NOT like
// memory_node_stats) — the interaction floor may already have stepped past
// the rows that produced these aggregates, so DropMemoryIndex (a MEM-02
// reindex) must not clear it (resolved ambiguity #3).
func TestEngagementSurvivesDropIndex(t *testing.T) {
	db := openTestDB(t)

	if err := db.UpsertMemoryNode(memTestNode("ent_x", nil), "body x", nil); err != nil {
		t.Fatalf("upsert ent_x: %v", err)
	}
	if err := db.BumpEngagement("ent_x", true, "2026-07-16T00:00:00Z"); err != nil {
		t.Fatalf("BumpEngagement: %v", err)
	}

	if err := db.DropMemoryIndex(); err != nil {
		t.Fatalf("DropMemoryIndex: %v", err)
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM memory_engagement`).Scan(&count); err != nil {
		t.Fatalf("count after drop: %v", err)
	}
	if count != 1 {
		t.Errorf("engagement rows after DropMemoryIndex = %d, want 1 (must survive reindex)", count)
	}
}

// TestUpsertDigestShadow_RoundTrip: UpsertDigestShadow writes a row that
// ListDigestShadow can read back, with all fields intact (Phase-5 slice-3
// Task 2).
func TestUpsertDigestShadow_RoundTrip(t *testing.T) {
	db := openTestDB(t)

	row := DigestShadowRow{
		ChannelID:          "C1",
		PeriodFrom:         1000,
		PeriodTo:           2000,
		LegacyDigestID:     42,
		RenderedJSON:       `{"summary":"s"}`,
		Coverage:           0.75,
		RenderRefsRejected: 3,
		Model:              "haiku",
		CreatedAt:          "2026-07-16T00:00:00Z",
	}
	if err := db.UpsertDigestShadow(row); err != nil {
		t.Fatalf("UpsertDigestShadow: %v", err)
	}

	rows, err := db.ListDigestShadow("2026-07-15T00:00:00Z")
	if err != nil {
		t.Fatalf("ListDigestShadow: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("ListDigestShadow returned %d rows, want 1", len(rows))
	}
	got := rows[0]
	if got.ChannelID != row.ChannelID || got.PeriodFrom != row.PeriodFrom ||
		got.PeriodTo != row.PeriodTo || got.LegacyDigestID != row.LegacyDigestID ||
		got.RenderedJSON != row.RenderedJSON || got.Coverage != row.Coverage ||
		got.RenderRefsRejected != row.RenderRefsRejected || got.Model != row.Model ||
		got.CreatedAt != row.CreatedAt {
		t.Errorf("round-tripped row = %+v, want %+v", got, row)
	}
	if got.ID == 0 {
		t.Errorf("expected a non-zero autoincrement ID")
	}
}

// TestUpsertDigestShadow_ReplacesOnPeriodKey: a second Upsert for the same
// (channel_id, period_from, period_to) replaces the row in place rather than
// inserting a duplicate — the shadow table self-overwrites on a rerun over
// the same window (plan resolved ambiguity #7).
func TestUpsertDigestShadow_ReplacesOnPeriodKey(t *testing.T) {
	db := openTestDB(t)

	first := DigestShadowRow{
		ChannelID:    "C1",
		PeriodFrom:   1000,
		PeriodTo:     2000,
		RenderedJSON: `{"summary":"first"}`,
		CreatedAt:    "2026-07-16T00:00:00Z",
	}
	if err := db.UpsertDigestShadow(first); err != nil {
		t.Fatalf("first UpsertDigestShadow: %v", err)
	}

	second := first
	second.RenderedJSON = `{"summary":"second"}`
	second.RenderRefsRejected = 5
	second.CreatedAt = "2026-07-16T00:05:00Z"
	if err := db.UpsertDigestShadow(second); err != nil {
		t.Fatalf("second UpsertDigestShadow: %v", err)
	}

	rows, err := db.ListDigestShadow("2026-07-15T00:00:00Z")
	if err != nil {
		t.Fatalf("ListDigestShadow: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("ListDigestShadow returned %d rows, want 1 (upsert should replace, not duplicate)", len(rows))
	}
	if rows[0].RenderedJSON != second.RenderedJSON || rows[0].RenderRefsRejected != 5 {
		t.Errorf("row after re-upsert = %+v, want the second write's fields", rows[0])
	}
}

// TestListDigestShadow_FiltersBySinceISO: ListDigestShadow returns only rows
// created at or after sinceISO (the report's bounded-window input).
func TestListDigestShadow_FiltersBySinceISO(t *testing.T) {
	db := openTestDB(t)

	old := DigestShadowRow{
		ChannelID: "C1", PeriodFrom: 1, PeriodTo: 2,
		RenderedJSON: "{}", CreatedAt: "2026-07-01T00:00:00Z",
	}
	recent := DigestShadowRow{
		ChannelID: "C2", PeriodFrom: 1, PeriodTo: 2,
		RenderedJSON: "{}", CreatedAt: "2026-07-16T00:00:00Z",
	}
	if err := db.UpsertDigestShadow(old); err != nil {
		t.Fatalf("upsert old: %v", err)
	}
	if err := db.UpsertDigestShadow(recent); err != nil {
		t.Fatalf("upsert recent: %v", err)
	}

	rows, err := db.ListDigestShadow("2026-07-10T00:00:00Z")
	if err != nil {
		t.Fatalf("ListDigestShadow: %v", err)
	}
	if len(rows) != 1 || rows[0].ChannelID != "C2" {
		t.Fatalf("ListDigestShadow(since) = %+v, want only the recent row", rows)
	}
}

func TestMemoryRetrieveShadowRoundTrip(t *testing.T) {
	database := openTestDB(t)

	err := database.InsertMemoryRetrieveShadow(MemoryRetrieveShadowRow{
		Surface: "recall", QueryKey: "billing",
		OldResultJSON: `["ent_1"]`, NewResultJSON: `["ent_1","ent_2"]`,
		DiffMetricsJSON: `{"coverage_ok":true}`, TS: "2026-07-20T00:00:00Z",
	})
	if err != nil {
		t.Fatalf("InsertMemoryRetrieveShadow: %v", err)
	}
	// A second surface must not collide with the first.
	if err := database.InsertMemoryRetrieveShadow(MemoryRetrieveShadowRow{
		Surface: "briefing", QueryKey: "1721433600",
		OldResultJSON: `[]`, NewResultJSON: `[]`, DiffMetricsJSON: `{}`, TS: "2026-07-20T01:00:00Z",
	}); err != nil {
		t.Fatalf("second insert: %v", err)
	}

	rows, err := database.ListMemoryRetrieveShadow("recall", time.Time{})
	if err != nil {
		t.Fatalf("ListMemoryRetrieveShadow: %v", err)
	}
	if len(rows) != 1 || rows[0].QueryKey != "billing" {
		t.Fatalf("ListMemoryRetrieveShadow(recall) = %+v, want one billing row", rows)
	}
}

// jiraIssueSeed is the minimal jira_issues fixture for memory-source tests.
type jiraIssueSeed struct {
	Key, ProjectKey, Summary, DescriptionText   string
	IssueType, Status, StatusCategory, Priority string
	AssigneeDisplayName, AssigneeSlackID        string
	ReporterDisplayName, ReporterSlackID        string
	SprintName, EpicKey, DueDate, ResolvedAt    string
	UpdatedAt                                   string
	IsDeleted                                   bool
}

func seedJiraIssueRow(t *testing.T, db *DB, s jiraIssueSeed) {
	t.Helper()
	deleted := 0
	if s.IsDeleted {
		deleted = 1
	}
	_, err := db.Exec(`INSERT INTO jira_issues
		(account_id, key, project_key, summary, description_text, issue_type, status, status_category,
		 priority, assignee_display_name, assignee_slack_id, reporter_display_name, reporter_slack_id,
		 sprint_name, epic_key, due_date, resolved_at, created_at, updated_at, synced_at, is_deleted)
		VALUES (1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		s.Key, s.ProjectKey, s.Summary, s.DescriptionText, s.IssueType, s.Status, s.StatusCategory,
		s.Priority, s.AssigneeDisplayName, s.AssigneeSlackID, s.ReporterDisplayName, s.ReporterSlackID,
		s.SprintName, s.EpicKey, s.DueDate, s.ResolvedAt, "2026-07-01T00:00:00.000+0000", s.UpdatedAt,
		"2026-07-22T00:00:00Z", deleted)
	if err != nil {
		t.Fatalf("seed jira issue %s: %v", s.Key, err)
	}
}

// TestMemoryJiraWatermark: the fifth extraction watermark round-trips on the
// jira_accounts row, reads 0 for a missing account, and Set fails without a
// parent row.
func TestMemoryJiraWatermark(t *testing.T) {
	db := openTestDB(t)
	wm, err := db.MemoryJiraWatermark(1)
	if err != nil || wm != 0 {
		t.Fatalf("missing-account watermark = %v, %v; want 0, nil", wm, err)
	}
	if err := db.SetMemoryJiraWatermark(1, 1784500000); err == nil {
		t.Fatal("set without jira_accounts row: want error, got nil")
	}
	SeedTestJiraAccount(t, db)
	wm, err = db.MemoryJiraWatermark(1)
	if err != nil || wm != 0 {
		t.Fatalf("fresh watermark = %v, %v; want 0, nil", wm, err)
	}
	if err := db.SetMemoryJiraWatermark(1, 1784500000); err != nil {
		t.Fatalf("set: %v", err)
	}
	wm, err = db.MemoryJiraWatermark(1)
	if err != nil || wm != 1784500000 {
		t.Fatalf("watermark = %v, %v; want 1784500000, nil", wm, err)
	}
}

// TestJiraIssueExists: key+is_deleted=0 resolves; a deleted issue 404s (the
// tombstoned-message reasoning); an absent key is a clean false.
func TestJiraIssueExists(t *testing.T) {
	db := openTestDB(t)
	SeedTestJiraAccount(t, db)
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-1", ProjectKey: "CEX", Summary: "s", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T10:00:00.000+0000"})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-2", ProjectKey: "CEX", Summary: "s", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T10:00:00.000+0000", IsDeleted: true})

	if ok, err := db.JiraIssueExists("CEX-1"); err != nil || !ok {
		t.Errorf("CEX-1 = %v, %v; want true, nil", ok, err)
	}
	if ok, err := db.JiraIssueExists("CEX-2"); err != nil || ok {
		t.Errorf("deleted CEX-2 = %v, %v; want false, nil", ok, err)
	}
	if ok, err := db.JiraIssueExists("CEX-404"); err != nil || ok {
		t.Errorf("absent = %v, %v; want false, nil", ok, err)
	}
}

// jiraIssueKeys projects an issue slice down to its ordered keys.
func jiraIssueKeys(issues []JiraExtractIssue) []string {
	keys := make([]string, 0, len(issues))
	for _, is := range issues {
		keys = append(keys, is.Key)
	}
	return keys
}

// assertSingleJiraIssue fails the test unless issues is exactly the one
// wantKey issue with no error.
func assertSingleJiraIssue(t *testing.T, issues []JiraExtractIssue, err error, wantKey string) {
	t.Helper()
	if err != nil || len(issues) != 1 || issues[0].Key != wantKey {
		t.Errorf("limited = %v, %v; want just %s", issues, err, wantKey)
	}
}

// assertMaxJiraUpdated fails the test unless got == want with no error.
func assertMaxJiraUpdated(t *testing.T, got, want int64, err error) {
	t.Helper()
	if err != nil || got != want {
		t.Errorf("MaxJiraUpdatedUnix = %v, %v; want %v", got, err, want)
	}
}

// assertKeySet fails the test unless issues' keys are exactly the want set
// (order-independent).
func assertKeySet(t *testing.T, issues []JiraExtractIssue, want ...string) {
	t.Helper()
	got := map[string]bool{}
	for _, k := range jiraIssueKeys(issues) {
		got[k] = true
	}
	if len(got) != len(want) {
		t.Fatalf("keys = %+v, want exactly %v", issues, want)
	}
	for _, k := range want {
		if !got[k] {
			t.Errorf("keys = %+v, missing want key %q", issues, k)
		}
	}
}

// TestListJiraIssuesForExtract: parsed-updated_at filtering and ordering, the
// is_deleted filter, the unparseable-updated_at skip, and the limit cap.
func TestListJiraIssuesForExtract(t *testing.T) {
	db := openTestDB(t)
	SeedTestJiraAccount(t, db)
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-1", ProjectKey: "CEX", Summary: "old", Status: "Done", StatusCategory: "done", UpdatedAt: "2026-07-20T10:00:00.000+0000"})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-2", ProjectKey: "CEX", Summary: "new", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T10:00:00.000+0000"})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-3", ProjectKey: "CEX", Summary: "newer", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T11:00:00.000+0000"})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-4", ProjectKey: "CEX", Summary: "deleted", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T12:00:00.000+0000", IsDeleted: true})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-5", ProjectKey: "CEX", Summary: "badts", Status: "To Do", StatusCategory: "todo", UpdatedAt: "not-a-time"})

	since, ok := ParseJiraTime("2026-07-21T00:00:00.000+0000")
	if !ok {
		t.Fatal("test time failed to parse")
	}
	issues, err := db.ListJiraIssuesForExtract(1, since, 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if keys := jiraIssueKeys(issues); strings.Join(keys, ",") != "CEX-2,CEX-3" {
		t.Errorf("keys = %v, want [CEX-2 CEX-3] (old filtered, deleted filtered, unparseable skipped, ascending)", keys)
	}
	// Limit caps from the oldest pending side.
	issues, err = db.ListJiraIssuesForExtract(1, since, 1)
	assertSingleJiraIssue(t, issues, err, "CEX-2")
	// Max helper sees the newest parseable non-deleted row (CEX-3).
	maxU, err := db.MaxJiraUpdatedUnix(1)
	want, _ := ParseJiraTime("2026-07-22T11:00:00.000+0000")
	assertMaxJiraUpdated(t, maxU, want, err)

	// Boundary-drain (Finding 2, final-review fix wave): a same-second tie at
	// the cap boundary must never be split. Two issues share one updated_at
	// second, a third is strictly later; limit=1 must still return BOTH
	// same-second issues (the later one stays excluded).
	db2 := openTestDB(t)
	SeedTestJiraAccount(t, db2)
	seedJiraIssueRow(t, db2, jiraIssueSeed{Key: "TIE-1", ProjectKey: "TIE", Summary: "a", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T10:00:00.000+0000"})
	seedJiraIssueRow(t, db2, jiraIssueSeed{Key: "TIE-2", ProjectKey: "TIE", Summary: "b", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T10:00:00.000+0000"})
	seedJiraIssueRow(t, db2, jiraIssueSeed{Key: "TIE-3", ProjectKey: "TIE", Summary: "later", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T11:00:00.000+0000"})

	tieIssues, err := db2.ListJiraIssuesForExtract(1, 0, 1)
	if err != nil {
		t.Fatalf("boundary-drain list: %v", err)
	}
	if len(tieIssues) != 2 {
		t.Fatalf("boundary drain len = %d, want 2 (both same-second issues drained in)", len(tieIssues))
	}
	assertKeySet(t, tieIssues, "TIE-1", "TIE-2")
}

// upsertNamedNode is a test helper for inserting a memory_nodes row with the
// given id/title/status via UpsertMemoryNode.
func upsertNamedNode(t *testing.T, db *DB, id, title, status string) {
	t.Helper()
	row := memTestNode(id, func(r *MemoryNodeRow) {
		r.Title = title
		r.Status = status
	})
	if err := db.UpsertMemoryNode(row, "body", nil); err != nil {
		t.Fatalf("upsert node %s: %v", id, err)
	}
}

// TestFocusFingerprintRoundTrip: the applied-focus fingerprint round-trips on
// the workspace singleton; a fresh workspace reads "".
func TestFocusFingerprintRoundTrip(t *testing.T) {
	db := openTestDB(t)
	seedWorkspace(t, db)
	fp, err := db.FocusFingerprint()
	if err != nil || fp != "" {
		t.Fatalf("fresh = %q, %v; want \"\", nil", fp, err)
	}
	if err := db.SetFocusFingerprint("abc123"); err != nil {
		t.Fatal(err)
	}
	fp, err = db.FocusFingerprint()
	if err != nil || fp != "abc123" {
		t.Fatalf("got %q, %v; want abc123", fp, err)
	}
}

// TestFocusMatches: ReplaceFocusMatches rewrites wholesale; FocusState reads
// ” for unmatched, 'now'/'cooled' for matched.
func TestFocusMatches(t *testing.T) {
	db := openTestDB(t)
	if err := db.ReplaceFocusMatches([]string{"ent_a", "ent_b"}, []string{"ent_c"}); err != nil {
		t.Fatal(err)
	}
	for id, want := range map[string]string{"ent_a": "now", "ent_b": "now", "ent_c": "cooled", "ent_zzz": ""} {
		got, err := db.FocusState(id)
		if err != nil || got != want {
			t.Errorf("FocusState(%s) = %q, %v; want %q", id, got, err, want)
		}
	}
	// Wholesale replace: previous matches vanish.
	if err := db.ReplaceFocusMatches(nil, []string{"ent_a"}); err != nil {
		t.Fatal(err)
	}
	if got, _ := db.FocusState("ent_b"); got != "" {
		t.Errorf("ent_b survived replace: %q", got)
	}
	if got, _ := db.FocusState("ent_a"); got != "cooled" {
		t.Errorf("ent_a = %q, want cooled", got)
	}
}

// TestListMemoryNodeTitles: returns every non-tombstone node's (id, title)
// pair, tombstones excluded — the raw material the focus matcher (Go-side,
// Unicode-aware) filters case-insensitively itself (final-review Fix 3).
func TestListMemoryNodeTitles(t *testing.T) {
	db := openTestDB(t)
	upsertNamedNode(t, db, "ent_hash", "Hashbank Integration", "active")
	upsertNamedNode(t, db, "ent_other", "Preview Environments", "active")
	upsertNamedNode(t, db, "ent_tomb", "hashbank legacy", "tombstone")

	titles, err := db.ListMemoryNodeTitles()
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, tt := range titles {
		got[tt.ID] = tt.Title
	}
	want := map[string]string{"ent_hash": "Hashbank Integration", "ent_other": "Preview Environments"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v (tombstone must be excluded)", got, want)
	}
	for id, title := range want {
		if got[id] != title {
			t.Errorf("ListMemoryNodeTitles()[%s] = %q, want %q", id, got[id], title)
		}
	}
}
