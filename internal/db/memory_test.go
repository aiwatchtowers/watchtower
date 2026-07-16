package db

import (
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/pressly/goose/v3"
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

// TestCountMemoryLinksInBulk: the grouped links-in query returns the same counts
// as the per-id CountMemoryLinksIn, in one pass — self-links and tombstones
// excluded, and every requested id present (0 when unlinked).
func TestCountMemoryLinksInBulk(t *testing.T) {
	db := openTestDB(t)

	// a is linked by b and c; b is linked by c; c is linked by nobody. a's own
	// body links to a (self-link, must not count). A tombstone links to a but is
	// excluded.
	if err := db.UpsertMemoryNode(memTestNode("ent_a", nil), "about a, see [[ent_a]] self", nil); err != nil {
		t.Fatalf("UpsertMemoryNode a: %v", err)
	}
	if err := db.UpsertMemoryNode(memTestNode("ent_b", nil), "b references [[ent_a]]", nil); err != nil {
		t.Fatalf("UpsertMemoryNode b: %v", err)
	}
	if err := db.UpsertMemoryNode(memTestNode("ent_c", nil), "c references [[ent_a]] and [[ent_b]]", nil); err != nil {
		t.Fatalf("UpsertMemoryNode c: %v", err)
	}
	tomb := memTestNode("ent_t", func(r *MemoryNodeRow) { r.Status = "tombstone" })
	if err := db.UpsertMemoryNode(tomb, "tombstone points at [[ent_a]]", nil); err != nil {
		t.Fatalf("UpsertMemoryNode tomb: %v", err)
	}

	ids := []string{"ent_a", "ent_b", "ent_c", "ent_missing"}
	got, err := db.CountMemoryLinksInBulk(ids)
	if err != nil {
		t.Fatalf("CountMemoryLinksInBulk: %v", err)
	}

	// Bulk result matches the per-id method for every id.
	for _, id := range ids {
		want, err := db.CountMemoryLinksIn(id)
		if err != nil {
			t.Fatalf("CountMemoryLinksIn(%s): %v", id, err)
		}
		if got[id] != want {
			t.Errorf("bulk[%s] = %d, per-id = %d", id, got[id], want)
		}
	}
	if got["ent_a"] != 2 {
		t.Errorf("ent_a links-in = %d, want 2 (b + c, self and tombstone excluded)", got["ent_a"])
	}
	if got["ent_b"] != 1 {
		t.Errorf("ent_b links-in = %d, want 1 (c)", got["ent_b"])
	}
	if _, ok := got["ent_missing"]; !ok {
		t.Error("an unseen id must still get a (zero) entry")
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

// TestDisputePendingSetListClear covers the memory_dispute_flags side table
// helpers (Task 1): SetDisputePending flags a belief, ListDisputePendingBeliefs
// returns only flagged belief nodes (oldest first) capped to limit, and
// ClearDisputePending removes the flag so a second list call returns nothing.
func TestDisputePendingSetListClear(t *testing.T) {
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

	if err := db.ClearDisputePending([]string{"bel_one"}); err != nil {
		t.Fatalf("ClearDisputePending: %v", err)
	}
	got, err = db.GetMemoryNode("bel_one")
	if err != nil {
		t.Fatalf("GetMemoryNode after clear: %v", err)
	}
	if got.DisputePending {
		t.Error("DisputePending still true after ClearDisputePending")
	}
	remaining, err := db.ListDisputePendingBeliefs(10)
	if err != nil {
		t.Fatalf("ListDisputePendingBeliefs after clear: %v", err)
	}
	if len(remaining) != 1 || remaining[0].ID != "bel_two" {
		t.Errorf("ListDisputePendingBeliefs after clear = %+v, want [bel_two]", remaining)
	}
}

// TestClearDisputePendingEmpty: clearing an empty id list is a no-op, not an
// error (callers may run the detector with nothing to clear).
func TestClearDisputePendingEmpty(t *testing.T) {
	db := openTestDB(t)
	if err := db.ClearDisputePending(nil); err != nil {
		t.Errorf("ClearDisputePending(nil) = %v, want nil", err)
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
