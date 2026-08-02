package db

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestOpenMemory(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Should be able to query
	var count int
	err = db.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table'").Scan(&count)
	require.NoError(t, err)
	assert.Greater(t, count, 0, "expected tables to be created")
}

func TestOpenCreatesDirectory(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "sub", "dir", "watchtower.db")

	db, err := Open(dbPath)
	require.NoError(t, err)
	defer db.Close()

	_, err = os.Stat(filepath.Dir(dbPath))
	assert.NoError(t, err, "directory should have been created")
}

func TestPragmas(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Check WAL mode
	var journalMode string
	err = db.QueryRow("PRAGMA journal_mode").Scan(&journalMode)
	require.NoError(t, err)
	// In-memory databases may use "memory" journal mode instead of WAL
	assert.Contains(t, []string{"wal", "memory"}, journalMode)

	// Check busy_timeout
	var busyTimeout int
	err = db.QueryRow("PRAGMA busy_timeout").Scan(&busyTimeout)
	require.NoError(t, err)
	assert.Equal(t, 5000, busyTimeout)

	// Check foreign_keys
	var fk int
	err = db.QueryRow("PRAGMA foreign_keys").Scan(&fk)
	require.NoError(t, err)
	assert.Equal(t, 1, fk)

	// Check synchronous
	var sync int
	err = db.QueryRow("PRAGMA synchronous").Scan(&sync)
	require.NoError(t, err)
	assert.Equal(t, 1, sync) // NORMAL = 1
}

func TestMigrationIdempotent(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "watchtower.db")

	// Open and close to create the DB
	db1, err := Open(dbPath)
	require.NoError(t, err)

	// Insert some data
	_, err = db1.Exec("INSERT INTO workspace (id, name, domain) VALUES ('T1', 'test', 'test')")
	require.NoError(t, err)
	db1.Close()

	// Open again - migration should be idempotent, data should persist
	db2, err := Open(dbPath)
	require.NoError(t, err)
	defer db2.Close()

	var name string
	err = db2.QueryRow("SELECT name FROM workspace WHERE id = 'T1'").Scan(&name)
	require.NoError(t, err)
	assert.Equal(t, "test", name)
}

func TestAllTablesExist(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	expectedTables := []string{
		"workspace", "users", "channels", "messages",
		"reactions", "files", "sync_state", "watch_list", "user_checkpoints",
		"digests", "decision_reads", "user_analyses", "period_summaries",
		"custom_emojis", "tracks", "decision_importance_corrections",
		"feedback", "prompts", "prompt_history", "user_profile",
		"track_events", "situations", "situation_signals",
		"feed_items", "feed_state", "meeting_transcripts", "voice_prints",
		"gmail_messages", "google_accounts", "slack_accounts",
		"email_accounts", "imap_messages", "calendar_accounts",
		"memory_nodes", "memory_aliases", "memory_node_stats",
		"memory_entity_hints", "memory_dispute_flags", "memory_engagement",
		"memory_provenance", "memory_digest_shadow", "memory_retrieve_shadow",
		"memory_focus_matches",
	}

	for _, table := range expectedTables {
		var name string
		err := db.QueryRow(
			"SELECT name FROM sqlite_master WHERE type='table' AND name=?", table,
		).Scan(&name)
		require.NoError(t, err, "table %q should exist", table)
		assert.Equal(t, table, name)
	}
}

func TestMigration00008CustomTracks(t *testing.T) {
	database := openTestDB(t) // existing helper that runs migrations on a fresh DB
	defer database.Close()

	// New columns exist on tracks.
	for _, col := range []string{"origin", "instruction", "enabled", "last_run_at", "linked_target_id"} {
		var count int
		err := database.QueryRow(
			`SELECT COUNT(*) FROM pragma_table_info('tracks') WHERE name = ?`, col).Scan(&count)
		if err != nil || count != 1 {
			t.Fatalf("tracks.%s missing (count=%d err=%v)", col, count, err)
		}
	}
	// origin defaults to 'auto' and rejects bad values.
	if _, err := database.Exec(`INSERT INTO tracks (text, origin) VALUES ('x', 'bogus')`); err == nil {
		t.Fatal("expected CHECK violation for origin='bogus'")
	}
	// track_events exists; observers/observer_events are gone.
	assertTableExists(t, database, "track_events")
	assertTableGone(t, database, "observers")
	assertTableGone(t, database, "observer_events")
}

func assertTableExists(t *testing.T, d *DB, name string) {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, name).Scan(&n); err != nil || n != 1 {
		t.Fatalf("table %s expected to exist (n=%d err=%v)", name, n, err)
	}
}

func assertTableGone(t *testing.T, d *DB, name string) {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, name).Scan(&n); err != nil || n != 0 {
		t.Fatalf("table %s expected to be dropped (n=%d err=%v)", name, n, err)
	}
}

func TestMigration00017MemoryIndex(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	// Consolidation watermark on workspace.
	var count int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('workspace') WHERE name = 'memory_last_extracted_ts'`,
	).Scan(&count)
	if err != nil || count != 1 {
		t.Fatalf("workspace.memory_last_extracted_ts missing (count=%d err=%v)", count, err)
	}

	// Split cache token accounting on pipeline_runs.
	for _, col := range []string{"cache_read_tokens", "cache_creation_tokens"} {
		var n int
		err := database.QueryRow(
			`SELECT COUNT(*) FROM pragma_table_info('pipeline_runs') WHERE name = ?`, col).Scan(&n)
		if err != nil || n != 1 {
			t.Fatalf("pipeline_runs.%s missing (count=%d err=%v)", col, n, err)
		}
	}

	// FTS index over memory node bodies.
	assertTableExists(t, database, "memory_fts")

	// Enum CHECKs reject bad values.
	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at)
		 VALUES ('ent_x', 'bogus', 'long', 'entities/x.md', 'h', '2026-07-15T00:00:00Z')`); err == nil {
		t.Fatal("expected CHECK violation for type='bogus'")
	}
	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at)
		 VALUES ('ent_x', 'entity', 'medium', 'entities/x.md', 'h', '2026-07-15T00:00:00Z')`); err == nil {
		t.Fatal("expected CHECK violation for tier='medium'")
	}
	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, status, path, content_hash, indexed_at)
		 VALUES ('ent_x', 'entity', 'long', 'gone', 'entities/x.md', 'h', '2026-07-15T00:00:00Z')`); err == nil {
		t.Fatal("expected CHECK violation for status='gone'")
	}

	// Aliases are case-insensitive (COLLATE NOCASE primary key).
	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at)
		 VALUES ('ent_x', 'entity', 'long', 'entities/x.md', 'h', '2026-07-15T00:00:00Z')`); err != nil {
		t.Fatalf("inserting memory node: %v", err)
	}
	if _, err := database.Exec(
		`INSERT INTO memory_aliases (alias, node_id) VALUES ('Alice', 'ent_x')`); err != nil {
		t.Fatalf("inserting alias: %v", err)
	}
	if _, err := database.Exec(
		`INSERT INTO memory_aliases (alias, node_id) VALUES ('alice', 'ent_x')`); err == nil {
		t.Fatal("expected NOCASE PK violation for duplicate alias with different case")
	}
}

func TestMigration00018MemorySemantic(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	// Ingest floor scalar on workspace (Task 13 reads/advances this).
	var count int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('workspace') WHERE name = 'memory_last_ingested_situation_id'`,
	).Scan(&count)
	if err != nil || count != 1 {
		t.Fatalf("workspace.memory_last_ingested_situation_id missing (count=%d err=%v)", count, err)
	}

	// Expanded memory_nodes.status CHECK accepts the new belief statuses.
	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, status, path, content_hash, indexed_at)
		 VALUES ('bel_x', 'belief', 'long', 'shaken', 'beliefs/x.md', 'h', '2026-07-16T00:00:00Z')`); err != nil {
		t.Fatalf("expected status='shaken' to be accepted post-migration: %v", err)
	}
	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, status, path, content_hash, indexed_at)
		 VALUES ('bel_y', 'belief', 'long', 'retired', 'beliefs/y.md', 'h', '2026-07-16T00:00:00Z')`); err != nil {
		t.Fatalf("expected status='retired' to be accepted post-migration: %v", err)
	}
	// The CHECK still rejects values outside the (now five-member) enum.
	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, status, path, content_hash, indexed_at)
		 VALUES ('ent_z', 'entity', 'long', 'gone', 'entities/z.md', 'h', '2026-07-16T00:00:00Z')`); err == nil {
		t.Fatal("expected CHECK violation for status='gone'")
	}
	// Existing statuses are still accepted (table-recreation preserved the
	// original enum members).
	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, status, path, content_hash, indexed_at)
		 VALUES ('ep_a', 'episode', 'short', 'active', 'episodes/a.md', 'h', '2026-07-16T00:00:00Z')`); err != nil {
		t.Fatalf("expected status='active' to still be accepted: %v", err)
	}

	// memory_entity_hints: persists unresolved extractor hints for concept
	// promotion; distinct-episode recurrence keyed on (hint, episode_id).
	assertTableExists(t, database, "memory_entity_hints")
	for _, col := range []string{"hint", "episode_id", "first_seen", "promoted_to"} {
		var n int
		err := database.QueryRow(
			`SELECT COUNT(*) FROM pragma_table_info('memory_entity_hints') WHERE name = ?`, col).Scan(&n)
		if err != nil || n != 1 {
			t.Fatalf("memory_entity_hints.%s missing (count=%d err=%v)", col, n, err)
		}
	}
	if _, err := database.Exec(
		`INSERT INTO memory_entity_hints (hint, episode_id, first_seen) VALUES ('hsm', 'ep_1', '2026-07-16T00:00:00Z')`,
	); err != nil {
		t.Fatalf("inserting entity hint: %v", err)
	}
	// Same (hint, episode_id) is rejected — re-extracting the same episode
	// must never double-count recurrence.
	if _, err := database.Exec(
		`INSERT INTO memory_entity_hints (hint, episode_id, first_seen) VALUES ('hsm', 'ep_1', '2026-07-16T00:00:01Z')`,
	); err == nil {
		t.Fatal("expected PK violation for duplicate (hint, episode_id)")
	}
	// A different episode contributing the same hint is a distinct row
	// (recurrence counting is COUNT(*) per hint).
	if _, err := database.Exec(
		`INSERT INTO memory_entity_hints (hint, episode_id, first_seen) VALUES ('hsm', 'ep_2', '2026-07-16T00:00:00Z')`,
	); err != nil {
		t.Fatalf("inserting entity hint for second episode: %v", err)
	}
}

func TestMigration00019MemorySurfaces(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	// Belief index columns on memory_nodes: file-derived, default '' / 0.
	for _, col := range []string{"subject", "confidence"} {
		var n int
		err := database.QueryRow(
			`SELECT COUNT(*) FROM pragma_table_info('memory_nodes') WHERE name = ?`, col).Scan(&n)
		if err != nil || n != 1 {
			t.Fatalf("memory_nodes.%s missing (count=%d err=%v)", col, n, err)
		}
	}
	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at)
		 VALUES ('bel_x', 'belief', 'long', 'beliefs/x.md', 'h', '2026-07-16T00:00:00Z')`); err != nil {
		t.Fatalf("inserting memory node without subject/confidence: %v", err)
	}
	var subject string
	var confidence float64
	if err := database.QueryRow(
		`SELECT subject, confidence FROM memory_nodes WHERE id = 'bel_x'`).Scan(&subject, &confidence); err != nil {
		t.Fatalf("reading subject/confidence defaults: %v", err)
	}
	if subject != "" || confidence != 0 {
		t.Fatalf("subject/confidence defaults = (%q, %v), want (\"\", 0)", subject, confidence)
	}

	// Owner-chat ingest floor on workspace.
	var count int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('workspace') WHERE name = 'memory_chat_turn_floor'`,
	).Scan(&count)
	if err != nil || count != 1 {
		t.Fatalf("workspace.memory_chat_turn_floor missing (count=%d err=%v)", count, err)
	}

	// memory_dispute_flags: a side table (not a memory_nodes column) keyed on
	// node_id, referencing memory_nodes.
	assertTableExists(t, database, "memory_dispute_flags")
	if _, err := database.Exec(
		`INSERT INTO memory_dispute_flags (node_id, flagged_at) VALUES ('bel_x', '2026-07-16T00:00:00Z')`,
	); err != nil {
		t.Fatalf("inserting dispute flag: %v", err)
	}
	var reason string
	if err := database.QueryRow(
		`SELECT reason FROM memory_dispute_flags WHERE node_id = 'bel_x'`).Scan(&reason); err != nil {
		t.Fatalf("reading dispute flag reason default: %v", err)
	}
	if reason != "" {
		t.Fatalf("reason default = %q, want \"\"", reason)
	}
}

// TestMigration00037MemoryImportanceScore: memory_nodes.importance_score
// (Slice A of the memory-importance-score redesign, MEM-16) is additive,
// defaults 0, and a plain insert that omits it still succeeds.
func TestMigration00037MemoryImportanceScore(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	var n int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('memory_nodes') WHERE name = 'importance_score'`).Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("memory_nodes.importance_score missing (count=%d err=%v)", n, err)
	}

	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at)
		 VALUES ('ent_importance_x', 'entity', 'long', 'entities/x.md', 'h', '2026-07-18T00:00:00Z')`); err != nil {
		t.Fatalf("inserting memory node without importance_score: %v", err)
	}
	var score float64
	if err := database.QueryRow(
		`SELECT importance_score FROM memory_nodes WHERE id = 'ent_importance_x'`).Scan(&score); err != nil {
		t.Fatalf("reading importance_score default: %v", err)
	}
	if score != 0 {
		t.Fatalf("importance_score default = %v, want 0", score)
	}
}

// TestMigration00038MemoryProvenanceSender: memory_provenance.sender_id
// (Slice B of the memory-retrieval redesign) is additive, defaults ”, a
// plain insert that omits it still succeeds, and its index exists.
func TestMigration00038MemoryProvenanceSender(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	var n int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('memory_provenance') WHERE name = 'sender_id'`).Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("memory_provenance.sender_id missing (count=%d err=%v)", n, err)
	}

	var idxCount int
	if err := database.QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_memory_provenance_sender'`).Scan(&idxCount); err != nil || idxCount != 1 {
		t.Fatalf("idx_memory_provenance_sender missing (count=%d err=%v)", idxCount, err)
	}

	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at)
		 VALUES ('ep_sender_x', 'episode', 'short', 'episodes/x.md', 'h', '2026-07-20T00:00:00Z')`); err != nil {
		t.Fatalf("inserting memory node: %v", err)
	}
	if _, err := database.Exec(
		`INSERT INTO memory_provenance (node_id, channel_id, ts_raw, ts_unix)
		 VALUES ('ep_sender_x', 'C0AAA', '100.000100', 100.0001)`); err != nil {
		t.Fatalf("inserting provenance row without sender_id: %v", err)
	}
	var sender string
	if err := database.QueryRow(
		`SELECT sender_id FROM memory_provenance WHERE node_id = 'ep_sender_x'`).Scan(&sender); err != nil {
		t.Fatalf("reading sender_id default: %v", err)
	}
	if sender != "" {
		t.Fatalf("sender_id default = %q, want empty string", sender)
	}
}

// TestMigration00039MemoryRetrieveShadow: memory_retrieve_shadow (Slice B
// Task 7, dark retrieval compare-mode) is additive, has no FK onto
// memory_nodes (a shadow row must survive even if the compared node is later
// deleted — it is pure telemetry, not derived state), and a plain insert
// with all five payload columns succeeds.
func TestMigration00039MemoryRetrieveShadow(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	var n int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='memory_retrieve_shadow'`).Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("memory_retrieve_shadow table missing (count=%d err=%v)", n, err)
	}

	_, err = database.Exec(
		`INSERT INTO memory_retrieve_shadow (surface, query_key, old_result_json, new_result_json, diff_metrics_json, ts)
		 VALUES ('recall', 'billing', '["ent_1"]', '["ent_1","ent_2"]', '{"coverage_ok":true}', '2026-07-20T00:00:00Z')`)
	if err != nil {
		t.Fatalf("inserting memory_retrieve_shadow row: %v", err)
	}

	var surface string
	if err := database.QueryRow(`SELECT surface FROM memory_retrieve_shadow WHERE query_key = 'billing'`).Scan(&surface); err != nil {
		t.Fatalf("reading back inserted row: %v", err)
	}
	if surface != "recall" {
		t.Errorf("surface = %q, want recall", surface)
	}
}

// TestMigration00019ClearsBeliefContentHash proves the migration empties every
// pre-existing belief's content_hash (M1) so the next Reconcile re-parses it and
// fills the new subject/confidence columns — a belief indexed before 00019 has
// an unchanged file, so a hash-match skip would leave it at ”/0 forever.
// Non-belief nodes keep their hash (their columns are always the ”/0 default).
func TestMigration00019ClearsBeliefContentHash(t *testing.T) {
	path := filepath.Join(t.TempDir(), "belief-hash.db")
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer d.Close()

	// Roll back to just before 00019: memory_nodes exists (from 00017) but has no
	// subject/confidence columns yet.
	if err := goose.DownTo(d.DB, "migrations", 18); err != nil {
		t.Fatalf("goose down to 18: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at)
		VALUES ('bel_seed', 'belief', 'long', 'beliefs/seed.md', 'beliefhash', '2026-07-16T00:00:00Z'),
		       ('ent_seed', 'entity', 'long', 'entities/seed.md', 'enthash', '2026-07-16T00:00:00Z')`); err != nil {
		t.Fatalf("seeding pre-00019 nodes: %v", err)
	}

	// Apply 00019 (adds columns + clears belief content_hash).
	if err := goose.UpTo(d.DB, "migrations", 19); err != nil {
		t.Fatalf("goose up to 19: %v", err)
	}

	var belHash, entHash string
	if err := d.QueryRow(`SELECT content_hash FROM memory_nodes WHERE id='bel_seed'`).Scan(&belHash); err != nil {
		t.Fatalf("reading belief hash: %v", err)
	}
	if err := d.QueryRow(`SELECT content_hash FROM memory_nodes WHERE id='ent_seed'`).Scan(&entHash); err != nil {
		t.Fatalf("reading entity hash: %v", err)
	}
	if belHash != "" {
		t.Errorf("belief content_hash = %q, want empty (forces re-parse for subject/confidence)", belHash)
	}
	if entHash != "enthash" {
		t.Errorf("non-belief content_hash = %q, want untouched", entHash)
	}
}

// TestMemorySurfacesMigrationDownUpCycle: 00019's Down drops its
// ALTER-added columns and the dispute-flags table (precedent: 00017/00018's
// Down), so a down;up cycle is clean.
func TestMemorySurfacesMigrationDownUpCycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "surfaces-cycle.db")
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

	if _, err := d.Exec(`UPDATE workspace SET memory_chat_turn_floor = 0`); err != nil {
		t.Errorf("memory_chat_turn_floor missing after cycle: %v", err)
	}
	if _, err := d.Exec(
		`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at, subject, confidence)
		 VALUES ('bel_cycle', 'belief', 'long', 'beliefs/cycle.md', 'h', '2026-07-16T00:00:00Z', 'ent_x', 0.5)`,
	); err != nil {
		t.Errorf("subject/confidence columns missing after cycle: %v", err)
	}
	if _, err := d.Exec(
		`INSERT INTO memory_dispute_flags (node_id, flagged_at) VALUES ('bel_cycle', '2026-07-16T00:00:00Z')`,
	); err != nil {
		t.Errorf("memory_dispute_flags missing after cycle: %v", err)
	}
}

// TestMigration00042MemoryPhase5Slice1 (renumbered from 00022 past main's email_accounts) covers Task 3's three additive
// changes: the interaction-ingest floor on workspace (defaults 0) and the
// memory_engagement side table (defaults ” / 0 / 0, keyed on memory_nodes.id).
// It originally also covered workspace.memory_gmail_last_extracted_ts, which
// migration 00043 (google_accounts) moves to a per-account column on
// google_accounts — see TestMigration00043GoogleAccounts.
func TestMigration00042MemoryPhase5Slice1(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	var n int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('workspace') WHERE name = ?`, "memory_last_interaction_id").Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("workspace.memory_last_interaction_id missing (count=%d err=%v)", n, err)
	}
	if _, err := database.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	var interactionFloor int64
	if err := database.QueryRow(
		`SELECT memory_last_interaction_id FROM workspace WHERE id = 'T1'`,
	).Scan(&interactionFloor); err != nil {
		t.Fatalf("reading floor default: %v", err)
	}
	if interactionFloor != 0 {
		t.Fatalf("floor default = %v, want 0", interactionFloor)
	}

	assertTableExists(t, database, "memory_engagement")
	if err := database.UpsertMemoryNode(memTestNode("ent_engage", nil), "body", nil); err != nil {
		t.Fatalf("upsert node for engagement fk: %v", err)
	}
	if _, err := database.Exec(
		`INSERT INTO memory_engagement (node_id) VALUES ('ent_engage')`,
	); err != nil {
		t.Fatalf("inserting engagement row with only node_id: %v", err)
	}
	var engaged, dismissed int
	var lastAt string
	if err := database.QueryRow(
		`SELECT engaged_count, dismissed_count, last_interaction_at FROM memory_engagement WHERE node_id = 'ent_engage'`,
	).Scan(&engaged, &dismissed, &lastAt); err != nil {
		t.Fatalf("reading engagement defaults: %v", err)
	}
	if engaged != 0 || dismissed != 0 || lastAt != "" {
		t.Fatalf("engagement defaults = (%d, %d, %q), want (0, 0, \"\")", engaged, dismissed, lastAt)
	}
}

// TestMemoryPhase5Slice1MigrationDownUpCycle: 00042's Down drops its
// ALTER-added columns and the memory_engagement table (precedent: 00017-19's
// Down), so a down;up cycle is clean.
func TestMemoryPhase5Slice1MigrationDownUpCycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "phase5-slice1-cycle.db")
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

	if _, err := d.Exec(`UPDATE workspace SET memory_last_interaction_id = 0`); err != nil {
		t.Errorf("workspace columns missing after cycle: %v", err)
	}
	if err := d.UpsertMemoryNode(memTestNode("ent_cycle", nil), "body", nil); err != nil {
		t.Fatalf("upsert node for engagement fk: %v", err)
	}
	if _, err := d.Exec(
		`INSERT INTO memory_engagement (node_id) VALUES ('ent_cycle')`,
	); err != nil {
		t.Errorf("memory_engagement missing after cycle: %v", err)
	}
}

// TestMigration00033MemoryPhase5Slice2 covers the Slice-2 Task 2 change: the
// calendar episode-build watermark on workspace (defaults 0), a FOURTH
// independent memory watermark alongside memory_last_extracted_ts (Slack),
// memory_gmail_last_extracted_ts (Gmail), and memory_last_interaction_id (5D
// floor). Additive ALTER TABLE ADD COLUMN only — no new table, no CHECK
// change.
func TestMigration00033MemoryPhase5Slice2(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	var n int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('workspace') WHERE name = ?`, "memory_calendar_last_extracted_ts").Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("workspace.memory_calendar_last_extracted_ts missing (count=%d err=%v)", n, err)
	}

	if _, err := database.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	var calTS float64
	if err := database.QueryRow(
		`SELECT memory_calendar_last_extracted_ts FROM workspace WHERE id = 'T1'`,
	).Scan(&calTS); err != nil {
		t.Fatalf("reading calendar watermark default: %v", err)
	}
	if calTS != 0 {
		t.Fatalf("calendar watermark default = %v, want 0", calTS)
	}
}

// TestMemoryPhase5Slice2MigrationDownUpCycle: 00033's Down drops its
// ALTER-added column (precedent: 00017-19, 00042's Down), so a down;up cycle is
// clean.
func TestMemoryPhase5Slice2MigrationDownUpCycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "phase5-slice2-cycle.db")
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

	if _, err := d.Exec(`UPDATE workspace SET memory_calendar_last_extracted_ts = 0`); err != nil {
		t.Errorf("memory_calendar_last_extracted_ts missing after cycle: %v", err)
	}
}

// TestMigration00044ConferenceURL: calendar_events.conference_url (Meet Join
// button) is additive, defaults ”, and a plain insert that omits it still
// succeeds.
func TestMigration00044ConferenceURL(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	var n int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('calendar_events') WHERE name = 'conference_url'`).Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("calendar_events.conference_url missing (count=%d err=%v)", n, err)
	}

	if _, err := database.Exec(
		`INSERT INTO calendar_calendars (id, name) VALUES ('cal1', 'Cal')`); err != nil {
		t.Fatalf("seeding calendar: %v", err)
	}
	if _, err := database.Exec(
		`INSERT INTO calendar_events (id, calendar_id, start_time, end_time)
		 VALUES ('evt-conf-x', 'cal1', '2026-01-01T09:00:00Z', '2026-01-01T10:00:00Z')`); err != nil {
		t.Fatalf("inserting event without conference_url: %v", err)
	}
	var confURL string
	if err := database.QueryRow(
		`SELECT conference_url FROM calendar_events WHERE id = 'evt-conf-x'`).Scan(&confURL); err != nil {
		t.Fatalf("reading conference_url default: %v", err)
	}
	if confURL != "" {
		t.Fatalf("conference_url default = %q, want empty string", confURL)
	}
}

// TestMigration00044ConferenceURLDownUpCycle: 00044's Down drops the
// ALTER-added column (precedent: 00033/00042's Down), so a down;up cycle is
// clean.
func TestMigration00044ConferenceURLDownUpCycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conference-url-cycle.db")
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer d.Close()

	// DownTo 43 (not Down): the moment a 00045 lands, a plain Down would
	// silently stop exercising 00044's Down forever (the DownTo idiom from
	// TestMigration00043DownUpCycle).
	if err := goose.DownTo(d.DB, "migrations", 43); err != nil {
		t.Fatalf("goose down to 43: %v", err)
	}
	if err := goose.Up(d.DB, "migrations"); err != nil {
		t.Fatalf("goose up after down: %v", err)
	}

	if _, err := d.Exec(`UPDATE calendar_events SET conference_url = ''`); err != nil {
		t.Errorf("conference_url missing after cycle: %v", err)
	}
}

func TestMigration00034MemoryDigestCompare(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	assertTableExists(t, database, "memory_provenance")
	assertTableExists(t, database, "memory_digest_shadow")

	// memory_provenance references memory_nodes(id); insert a node first,
	// then confirm the columns and PRIMARY KEY(node_id, channel_id, ts_raw)
	// shape.
	if err := database.UpsertMemoryNode(memTestNode("ep_prov", nil), "body", nil); err != nil {
		t.Fatalf("upsert node for provenance fk: %v", err)
	}
	if _, err := database.Exec(
		`INSERT INTO memory_provenance (node_id, scheme, channel_id, ts_raw, ts_unix) VALUES ('ep_prov', '', 'C1', '100.001', 100.001)`,
	); err != nil {
		t.Fatalf("inserting memory_provenance row: %v", err)
	}
	// A duplicate (node_id, channel_id, ts_raw) violates the PRIMARY KEY.
	if _, err := database.Exec(
		`INSERT INTO memory_provenance (node_id, scheme, channel_id, ts_raw, ts_unix) VALUES ('ep_prov', '', 'C1', '100.001', 100.001)`,
	); err == nil {
		t.Fatal("expected PRIMARY KEY violation on duplicate (node_id, channel_id, ts_raw)")
	}

	// memory_digest_shadow: default columns and UNIQUE(channel_id,
	// period_from, period_to).
	if _, err := database.Exec(
		`INSERT INTO memory_digest_shadow (channel_id, period_from, period_to, rendered_json, created_at) VALUES ('C1', 0, 100, '{}', '2026-07-16T00:00:00Z')`,
	); err != nil {
		t.Fatalf("inserting memory_digest_shadow row: %v", err)
	}
	if _, err := database.Exec(
		`INSERT INTO memory_digest_shadow (channel_id, period_from, period_to, rendered_json, created_at) VALUES ('C1', 0, 100, '{}', '2026-07-16T00:01:00Z')`,
	); err == nil {
		t.Fatal("expected UNIQUE violation on duplicate (channel_id, period_from, period_to)")
	}

	var legacyID, refsRejected int
	var coverage float64
	var model string
	if err := database.QueryRow(
		`SELECT legacy_digest_id, coverage, render_refs_rejected, model FROM memory_digest_shadow WHERE channel_id = 'C1'`,
	).Scan(&legacyID, &coverage, &refsRejected, &model); err != nil {
		t.Fatalf("reading memory_digest_shadow defaults: %v", err)
	}
	if legacyID != 0 || coverage != 0 || refsRejected != 0 || model != "" {
		t.Fatalf("memory_digest_shadow defaults = (%d, %v, %d, %q), want (0, 0, 0, \"\")", legacyID, coverage, refsRejected, model)
	}
}

// TestMemoryPhase5Slice3MigrationDownUpCycle: 00034's Down drops both
// additive CREATE TABLEs (precedent: 00017-19, 00042/00033's Down), so a down;up cycle is
// clean.
func TestMemoryPhase5Slice3MigrationDownUpCycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "phase5-slice3-cycle.db")
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

	assertTableExists(t, d, "memory_provenance")
	assertTableExists(t, d, "memory_digest_shadow")
}

func TestFTS5TableExists(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	var name string
	err = db.QueryRow(
		"SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'",
	).Scan(&name)
	require.NoError(t, err)
	assert.Equal(t, "messages_fts", name)
}

func TestMessageInsertTriggerPopulatesFTS(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Insert a message
	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1234567890.123456', 'U1', 'hello world deployment')",
	)
	require.NoError(t, err)

	// FTS should find it
	var text string
	err = db.QueryRow(
		"SELECT text FROM messages_fts WHERE messages_fts MATCH 'deployment'",
	).Scan(&text)
	require.NoError(t, err)
	assert.Contains(t, text, "deployment")
}

func TestFTSStemming(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1000000000.000001', 'U1', 'we are deploying the new version')",
	)
	require.NoError(t, err)

	// Porter stemmer: "deployed" should match "deploying"
	var count int
	err = db.QueryRow(
		"SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'deployed'",
	).Scan(&count)
	require.NoError(t, err)
	assert.Equal(t, 1, count)
}

func TestFTSDeletedMessageNotIndexed(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Insert a deleted message
	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text, is_deleted) VALUES ('C1', '1000000000.000001', 'U1', 'secret text', 1)",
	)
	require.NoError(t, err)

	// FTS should not find it
	var count int
	err = db.QueryRow(
		"SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'secret'",
	).Scan(&count)
	require.NoError(t, err)
	assert.Equal(t, 0, count)
}

func TestFTSEmptyTextNotIndexed(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Insert a message with empty text
	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1000000000.000001', 'U1', '')",
	)
	require.NoError(t, err)

	// FTS should have no rows
	var count int
	err = db.QueryRow("SELECT count(*) FROM messages_fts").Scan(&count)
	require.NoError(t, err)
	assert.Equal(t, 0, count)
}

func TestFTSUpdateTrigger(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1000000000.000001', 'U1', 'original text')",
	)
	require.NoError(t, err)

	// Update the text
	_, err = db.Exec(
		"UPDATE messages SET text = 'updated content' WHERE channel_id = 'C1' AND ts = '1000000000.000001'",
	)
	require.NoError(t, err)

	// Old text should not be found
	var count int
	err = db.QueryRow(
		"SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'original'",
	).Scan(&count)
	require.NoError(t, err)
	assert.Equal(t, 0, count)

	// New text should be found
	err = db.QueryRow(
		"SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'updated'",
	).Scan(&count)
	require.NoError(t, err)
	assert.Equal(t, 1, count)
}

func TestFTSDeleteTrigger(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1000000000.000001', 'U1', 'removable message')",
	)
	require.NoError(t, err)

	_, err = db.Exec(
		"DELETE FROM messages WHERE channel_id = 'C1' AND ts = '1000000000.000001'",
	)
	require.NoError(t, err)

	var count int
	err = db.QueryRow(
		"SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'removable'",
	).Scan(&count)
	require.NoError(t, err)
	assert.Equal(t, 0, count)
}

func TestFTSSoftDeleteUpdate(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1000000000.000001', 'U1', 'soft delete me')",
	)
	require.NoError(t, err)

	// Soft-delete by setting is_deleted
	_, err = db.Exec(
		"UPDATE messages SET is_deleted = 1 WHERE channel_id = 'C1' AND ts = '1000000000.000001'",
	)
	require.NoError(t, err)

	// FTS should no longer find it
	var count int
	err = db.QueryRow(
		"SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'soft'",
	).Scan(&count)
	require.NoError(t, err)
	assert.Equal(t, 0, count)
}

func TestTSUnixGeneratedColumn(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1234567890.123456', 'U1', 'test')",
	)
	require.NoError(t, err)

	var tsUnix float64
	err = db.QueryRow(
		"SELECT ts_unix FROM messages WHERE channel_id = 'C1' AND ts = '1234567890.123456'",
	).Scan(&tsUnix)
	require.NoError(t, err)
	assert.Equal(t, float64(1234567890), tsUnix)
}

func TestWatchListConstraints(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Valid insert
	_, err = db.Exec(
		"INSERT INTO watch_list (entity_type, entity_id, entity_name, priority) VALUES ('channel', 'C1', 'general', 'high')",
	)
	require.NoError(t, err)

	// Invalid entity_type should fail
	_, err = db.Exec(
		"INSERT INTO watch_list (entity_type, entity_id, entity_name, priority) VALUES ('invalid', 'X1', 'foo', 'normal')",
	)
	assert.Error(t, err)

	// Invalid priority should fail
	_, err = db.Exec(
		"INSERT INTO watch_list (entity_type, entity_id, entity_name, priority) VALUES ('user', 'U1', 'alice', 'urgent')",
	)
	assert.Error(t, err)
}

func TestUserCheckpointSingleton(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	_, err = db.Exec(
		"INSERT INTO user_checkpoints (id, last_checked_at) VALUES (1, '2025-01-01T00:00:00Z')",
	)
	require.NoError(t, err)

	// Trying to insert with id != 1 should fail
	_, err = db.Exec(
		"INSERT INTO user_checkpoints (id, last_checked_at) VALUES (2, '2025-01-01T00:00:00Z')",
	)
	assert.Error(t, err)
}

func TestChannelTypeConstraint(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Valid types
	for _, typ := range []string{"public", "private", "dm", "group_dm"} {
		_, err = db.Exec(
			"INSERT INTO channels (id, name, type) VALUES (?, ?, ?)",
			"C_"+typ, "test-"+typ, typ,
		)
		require.NoError(t, err, "type %q should be valid", typ)
	}

	// Invalid type
	_, err = db.Exec(
		"INSERT INTO channels (id, name, type) VALUES ('C_bad', 'bad', 'invalid')",
	)
	assert.Error(t, err)
}

func TestMessageUpsert(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Insert
	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1000000000.000001', 'U1', 'v1')",
	)
	require.NoError(t, err)

	// Upsert via INSERT OR REPLACE
	_, err = db.Exec(
		"INSERT OR REPLACE INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1000000000.000001', 'U1', 'v2')",
	)
	require.NoError(t, err)

	var text string
	err = db.QueryRow(
		"SELECT text FROM messages WHERE channel_id = 'C1' AND ts = '1000000000.000001'",
	).Scan(&text)
	require.NoError(t, err)
	assert.Equal(t, "v2", text)
}

func TestCloseDatabase(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)

	err = db.Close()
	require.NoError(t, err)

	// After close, queries should fail
	_, err = db.Exec("SELECT 1")
	assert.Error(t, err)
}

func TestUnicodeMessage(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	text := "Hello 世界! 🚀 デプロイメント"
	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1000000000.000001', 'U1', ?)",
		text,
	)
	require.NoError(t, err)

	var got string
	err = db.QueryRow(
		"SELECT text FROM messages WHERE channel_id = 'C1' AND ts = '1000000000.000001'",
	).Scan(&got)
	require.NoError(t, err)
	assert.Equal(t, text, got)
}

func TestNullableFields(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Message with NULL thread_ts
	_, err = db.Exec(
		"INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1000000000.000001', 'U1', 'test')",
	)
	require.NoError(t, err)

	var threadTS sql.NullString
	err = db.QueryRow(
		"SELECT thread_ts FROM messages WHERE channel_id = 'C1' AND ts = '1000000000.000001'",
	).Scan(&threadTS)
	require.NoError(t, err)
	assert.False(t, threadTS.Valid)

	// Channel with NULL dm_user_id
	_, err = db.Exec(
		"INSERT INTO channels (id, name, type) VALUES ('C2', 'test', 'public')",
	)
	require.NoError(t, err)

	var dmUserID sql.NullString
	err = db.QueryRow("SELECT dm_user_id FROM channels WHERE id = 'C2'").Scan(&dmUserID)
	require.NoError(t, err)
	assert.False(t, dmUserID.Valid)
}

// tableColumns returns a set of column names for a table.
func tableColumns(t *testing.T, database *DB, table string) map[string]bool {
	t.Helper()
	rows, err := database.Query("PRAGMA table_info(" + table + ")")
	require.NoError(t, err)
	defer rows.Close()
	cols := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, colType string
		var notNull, pk int
		var dflt sql.NullString
		require.NoError(t, rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk))
		cols[name] = true
	}
	require.NoError(t, rows.Err())
	return cols
}

// requireCol asserts that a column exists in the column set returned by tableColumns.
func requireCol(t *testing.T, cols map[string]bool, col string) {
	t.Helper()
	if !cols[col] {
		t.Errorf("expected column %q to exist", col)
	}
}

// tableExists checks whether a table exists in the database.
func tableExists(t *testing.T, database *DB, table string) bool {
	t.Helper()
	var cnt int
	err := database.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", table).Scan(&cnt)
	require.NoError(t, err)
	return cnt > 0
}

// TestMigration_v67_Backfill verifies the migration backfill logic by directly
// creating a pre-v67 inbox_items table (without item_class) and running the v67 migration SQL.

func TestSetReadOnlyBlocksWrites(t *testing.T) {
	database := openTestDB(t)

	require.NoError(t, database.SetReadOnly())

	_, err := database.Exec(`INSERT INTO users (id, name, is_stub) VALUES ('U1', 'alice', 1)`)
	require.Error(t, err, "INSERT must fail on a query_only connection")

	var n int
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM users`).Scan(&n), "reads must keep working")
}
