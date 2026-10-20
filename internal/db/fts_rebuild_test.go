package db

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The tests here mutate ftsRebuildChunkHook, ftsRebuildChunkGap and
// freeDiskBytes; no t.Parallel.

// noChunkGap drops the pause between fill chunks for the test.
func noChunkGap(t testing.TB) {
	t.Helper()
	prev := ftsRebuildChunkGap
	ftsRebuildChunkGap = 0
	t.Cleanup(func() { ftsRebuildChunkGap = prev })
}

// ftsFillQueries are the searches compared before the upgrade and after the
// fill.
var ftsFillQueries = []string{"deploy", "rollback", "payments"}

// seedFillMessages inserts 25 messages in rowid order, 5 of them not
// indexable (empty text or tombstoned).
func seedFillMessages(t *testing.T, d *DB) {
	t.Helper()
	words := []string{"deploy finished", "rollback planned", "payments review", "deploy rollback", "payments deploy"}
	for i := range 25 {
		text, deleted := fmt.Sprintf("message %d %s", i, words[i%len(words)]), 0
		switch i {
		case 3, 11:
			text = ""
		case 7, 15, 22:
			deleted = 1
		}
		_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, is_deleted) VALUES (?, ?, 'U1', ?, ?)`,
			fmt.Sprintf("C%d", i%3), fmt.Sprintf("%d.000001", 1700000000+i), text, deleted)
		require.NoError(t, err)
	}
}

// pendingFillDB opens a file database holding seedFillMessages with the fill
// pending (the real 00146 upgrade replayed), and returns it with its path
// and the search results captured before the upgrade.
func pendingFillDB(t *testing.T) (*DB, string, map[string][]Message) {
	t.Helper()
	noChunkGap(t)
	path := compactFixture(t)
	d, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	seedFillMessages(t, d)
	before := map[string][]Message{}
	for _, q := range ftsFillQueries {
		hits, err := d.SearchMessages(q, SearchOpts{})
		require.NoError(t, err)
		require.NotEmpty(t, hits, q)
		before[q] = hits
	}
	require.NoError(t, ReplayMessagesSearchUpgradeForTest(d))
	require.True(t, hasSchemaTable(t, d, "messages_fts_legacy"))
	require.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	return d, path, before
}

func setChunkHook(t *testing.T, fn func(chunk int)) {
	t.Helper()
	t.Cleanup(SetFTSRebuildChunkHookForTest(fn))
}

// assertIndexMatchesMessages checks the index holds exactly one row per
// indexable message, under its rowid, with its current values.
func assertIndexMatchesMessages(t *testing.T, d *DB) {
	t.Helper()
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts f LEFT JOIN messages m ON m.rowid = f.rowid
		WHERE m.rowid IS NULL OR m.text = '' OR m.is_deleted != 0
		   OR m.channel_id != f.channel_id OR m.ts != f.ts OR m.text != f.text`), "stale or wrong index rows")
	assert.Equal(t, queryInt(t, d, `SELECT COUNT(*) FROM messages WHERE text != '' AND is_deleted = 0`),
		queryInt(t, d, `SELECT COUNT(DISTINCT rowid) FROM messages_fts`), "indexable messages missing from the index")
	assert.Equal(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`),
		queryInt(t, d, `SELECT COUNT(DISTINCT rowid) FROM messages_fts`), "a rowid appears twice")
}

func assertFillFinished(t *testing.T, d *DB) {
	t.Helper()
	assert.False(t, hasSchemaTable(t, d, "messages_fts_legacy"), "legacy table left")
	assert.Zero(t, maintenanceKeyCount(t, d), "fill keys left")
}

func TestRebuildMessagesSearch_FillsAndDropsLegacy(t *testing.T) {
	d, _, before := pendingFillDB(t)

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{ChunkRows: 4})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true, Indexed: 20, Chunks: 7}, res)

	for _, q := range ftsFillQueries {
		hits, err := d.SearchMessages(q, SearchOpts{})
		require.NoError(t, err)
		assert.Equal(t, before[q], hits, q)
	}
	assertIndexMatchesMessages(t, d)
	assertFillFinished(t, d)
}

func TestRebuildMessagesSearch_ResumesAfterInterrupt(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	setChunkHook(t, func(chunk int) {
		if chunk == 2 {
			cancel()
		}
	})

	res, err := d.RebuildMessagesSearch(ctx, FTSRebuildOptions{ChunkRows: 4})
	require.ErrorIs(t, err, context.Canceled)
	assert.Equal(t, 2, res.Chunks)
	assert.False(t, res.Done)
	var eighth, cursor int64
	require.NoError(t, d.QueryRow(`SELECT rowid FROM messages ORDER BY rowid LIMIT 1 OFFSET 7`).Scan(&eighth))
	cursor, err = readMaintenanceInt(d, maintFTSRebuildCursor)
	require.NoError(t, err)
	assert.Equal(t, eighth, cursor)
	pending, _, err := readMaintenance(d, maintFTSRebuildPending)
	require.NoError(t, err)
	assert.Equal(t, "1", pending)
	assert.True(t, hasSchemaTable(t, d, "messages_fts_legacy"))

	res, err = d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{ChunkRows: 4})
	require.NoError(t, err)
	assert.True(t, res.Done)
	assert.Equal(t, 20, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	assertIndexMatchesMessages(t, d)
	assertFillFinished(t, d)
}

// A context cancelled before the first chunk writes nothing: no index row,
// no cursor.
func TestRebuildMessagesSearch_CancelledBeforeAnyChunkWritesNothing(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := d.RebuildMessagesSearch(ctx, FTSRebuildOptions{ChunkRows: 4})
	require.ErrorIs(t, err, context.Canceled)
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM db_maintenance WHERE key = ?`, maintFTSRebuildCursor))
}

func TestRebuildMessagesSearch_ConcurrentWritesBetweenChunks(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	rowidAt := func(offset int) int64 {
		var r int64
		require.NoError(t, d.QueryRow(`SELECT rowid FROM messages ORDER BY rowid LIMIT 1 OFFSET ?`, offset).Scan(&r))
		return r
	}
	below, tombstone, gone := rowidAt(1), rowidAt(9), rowidAt(13)
	setChunkHook(t, func(chunk int) {
		if chunk != 1 {
			return
		}
		for _, stmt := range []struct {
			q    string
			args []any
		}{
			{`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C9', '1800000000.000001', 'U1', 'late deploy arrival')`, nil},
			{`UPDATE messages SET text = 'edited deploy wording' WHERE rowid = ?`, []any{below}},
			{`UPDATE messages SET is_deleted = 1 WHERE rowid = ?`, []any{tombstone}},
			{`DELETE FROM messages WHERE rowid = ?`, []any{gone}},
		} {
			_, err := d.Exec(stmt.q, stmt.args...)
			require.NoError(t, err)
		}
	})

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{ChunkRows: 4})
	require.NoError(t, err)
	require.True(t, res.Done)
	assertIndexMatchesMessages(t, d)
	assertFillFinished(t, d)
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'late'`))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'edited'`))
}

func TestRebuildMessagesSearch_BudgetStopsBetweenChunks(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{Budget: time.Nanosecond, ChunkRows: 4})
	require.NoError(t, err)
	assert.Equal(t, 1, res.Chunks)
	assert.False(t, res.Done)

	for range 20 {
		if res.Done {
			break
		}
		res, err = d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{Budget: time.Nanosecond, ChunkRows: 4})
		require.NoError(t, err)
	}
	require.True(t, res.Done, "repeated budgeted calls never finished")
	assertIndexMatchesMessages(t, d)
	assertFillFinished(t, d)
}

// legacyShadowRows counts the rows left in the legacy index's rowid shadow
// tables.
func legacyShadowRows(t *testing.T, d *DB) int {
	t.Helper()
	n := 0
	for _, dr := range ftsLegacyDrain {
		n += queryInt(t, d, `SELECT COUNT(*) FROM `+dr.table)
	}
	return n
}

// TestRebuildMessagesSearch_DrainLegacyInChunks pins the daemon's completion:
// with DrainLegacy the legacy shadow rows go in chunk transactions, the
// table stays until they are gone, and the search results are unchanged.
func TestRebuildMessagesSearch_DrainLegacyInChunks(t *testing.T) {
	d, _, before := pendingFillDB(t)
	t.Cleanup(SetFTSLegacyDrainRowsForTest(4))
	opts := FTSRebuildOptions{Budget: time.Nanosecond, ChunkRows: 100, DrainLegacy: true}

	res, err := d.RebuildMessagesSearch(context.Background(), opts)
	require.NoError(t, err)
	require.False(t, res.Done)
	require.Equal(t, int64(20), res.Indexed, "one chunk fills all 25 rows")
	left := legacyShadowRows(t, d)
	require.Greater(t, left, 8, "the fixture must need more than one drain chunk")

	drainCalls := 0
	for range 30 {
		res, err = d.RebuildMessagesSearch(context.Background(), opts)
		require.NoError(t, err)
		if res.Done {
			break
		}
		drainCalls++
		assert.Zero(t, res.Indexed)
		require.True(t, hasSchemaTable(t, d, "messages_fts_legacy"), "dropped before the drain finished")
		now := legacyShadowRows(t, d)
		require.Less(t, now, left, "a drain chunk deleted nothing")
		left = now
	}
	require.True(t, res.Done, "the drain never finished")
	assert.GreaterOrEqual(t, drainCalls, 2)
	assertFillFinished(t, d)
	assertIndexMatchesMessages(t, d)
	for _, q := range ftsFillQueries {
		hits, err := d.SearchMessages(q, SearchOpts{})
		require.NoError(t, err)
		assert.Equal(t, before[q], hits, q)
	}
}

// TestRebuildMessagesSearch_NoDrainDropsDirectly pins the launch step's
// completion: without DrainLegacy the first call past the cursor drops the
// untouched legacy table in one transaction.
func TestRebuildMessagesSearch_NoDrainDropsDirectly(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	opts := FTSRebuildOptions{Budget: time.Nanosecond, ChunkRows: 100}

	res, err := d.RebuildMessagesSearch(context.Background(), opts)
	require.NoError(t, err)
	require.False(t, res.Done)
	require.Positive(t, legacyShadowRows(t, d))

	res, err = d.RebuildMessagesSearch(context.Background(), opts)
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true}, res)
	assertFillFinished(t, d)
	assertIndexMatchesMessages(t, d)
}

func TestRebuildMessagesSearch_NotPendingIsNoOp(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "C1", TS: "1.000001", UserID: "U1", Text: "indexed by the trigger"}))
	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true}, res)
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM db_maintenance`))
}

// The post-goose cleanup did not run (crash between goose's commit and it,
// or it failed) on an install with no message: the pending key and the
// legacy table are there over an empty messages table. The fill converges.
func TestRebuildMessagesSearch_PendingWithEmptyMessagesCompletes(t *testing.T) {
	d := rawFileDBAt(t, 146)
	require.True(t, hasSchemaTable(t, d, "messages_fts_legacy"))
	require.Equal(t, 1, maintenanceKeyCount(t, d))

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true}, res)
	assertFillFinished(t, d)
}

// A pending key and a stale cursor with no legacy table (another process
// already dropped it) are cleared.
func TestRebuildMessagesSearch_PendingWithoutLegacyClearsKeys(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "C1", TS: "1.000001", UserID: "U1", Text: "indexed by the trigger"}))
	_, err := d.Exec(`INSERT INTO db_maintenance (key, value) VALUES (?, '1'), (?, '999')`, maintFTSRebuildPending, maintFTSRebuildCursor)
	require.NoError(t, err)

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
	require.NoError(t, err)
	assert.True(t, res.Done)
	assertFillFinished(t, d)
	assertIndexMatchesMessages(t, d)
}

// A legacy table left without its pending key is still pending: the fill
// runs from the start and drops it.
func TestRebuildMessagesSearch_LegacyWithoutKeyIsFilled(t *testing.T) {
	d, path, _ := pendingFillDB(t)
	_, err := d.Exec(`DELETE FROM db_maintenance WHERE key = ?`, maintFTSRebuildPending)
	require.NoError(t, err)
	if c := checkCompaction(t, path, "1.0.0"); !c.FTSRebuildPending || c.Reason != "fts_rebuild" {
		t.Fatalf("legacy without key: got pending=%v reason=%q, want pending fts_rebuild", c.FTSRebuildPending, c.Reason)
	}

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{ChunkRows: 4})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true, Indexed: 20, Chunks: 7}, res)
	assertIndexMatchesMessages(t, d)
	assertFillFinished(t, d)
}

func TestRebuildMessagesSearchAt_DiskShortSkips(t *testing.T) {
	d, path, _ := pendingFillDB(t)
	check, err := d.CheckMessagesSearchRebuild()
	require.NoError(t, err)
	require.NoError(t, d.Close())
	require.Positive(t, check.NeedsDiskBytes)
	t.Cleanup(SetFreeDiskBytesForTest(func(string) (int64, error) { return check.NeedsDiskBytes - 1, nil }))

	res, err := RebuildMessagesSearchAt(context.Background(), path, FTSRebuildRunOptions{})
	require.NoError(t, err)
	assert.Equal(t, CompactResult{Skipped: "disk"}, res)
	ro, err := OpenExisting(path, compactCheckBusy)
	require.NoError(t, err)
	assert.True(t, hasSchemaTable(t, ro, "messages_fts_legacy"))
	assert.Zero(t, queryInt(t, ro, `SELECT COUNT(*) FROM messages_fts`))
	require.NoError(t, ro.Close())

	res, err = RebuildMessagesSearchAt(context.Background(), path, FTSRebuildRunOptions{Force: true})
	require.NoError(t, err)
	assert.Equal(t, CompactResult{FTSRebuilt: true}, res)
	ro, err = OpenExisting(path, compactCheckBusy)
	require.NoError(t, err)
	defer ro.Close()
	assertIndexMatchesMessages(t, ro)
	assertFillFinished(t, ro)
}

func TestRebuildMessagesSearchAt_Interrupted(t *testing.T) {
	d, path, _ := pendingFillDB(t)
	require.NoError(t, d.Close())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	setChunkHook(t, func(int) { cancel() })

	res, err := RebuildMessagesSearchAt(ctx, path, FTSRebuildRunOptions{})
	require.NoError(t, err)
	assert.Equal(t, CompactResult{Skipped: "interrupted"}, res)
}

func TestRebuildMessagesSearchAt_SchemaPending(t *testing.T) {
	path := filepath.Join(t.TempDir(), "wt.db")
	raw, err := sql.Open("sqlite", path)
	require.NoError(t, err)
	raw.SetMaxOpenConns(1)
	require.NoError(t, gooseUpTo(raw, "migrations", 145))
	require.NoError(t, raw.Close())
	stubFreeDisk(t, 1<<50)
	versions := func() (int, int) {
		ro, err := OpenExisting(path, compactCheckBusy)
		require.NoError(t, err)
		defer ro.Close()
		return queryInt(t, ro, `SELECT COUNT(*) FROM goose_db_version`), queryInt(t, ro, `SELECT COUNT(*) FROM db_maintenance`)
	}
	gooseBefore, maintBefore := versions()

	res, err := RebuildMessagesSearchAt(context.Background(), path, FTSRebuildRunOptions{})
	require.NoError(t, err)
	assert.Equal(t, CompactResult{Skipped: "schema_pending"}, res)
	gooseAfter, maintAfter := versions()
	assert.Equal(t, gooseBefore, gooseAfter, "the run migrated")
	assert.Equal(t, maintBefore, maintAfter, "the run wrote db_maintenance")
}

func TestCheckMessagesSearchRebuild_ReadsOnlyLegacyPages(t *testing.T) {
	d, path, _ := pendingFillDB(t)
	require.NoError(t, d.Close())
	info, err := os.Stat(path)
	require.NoError(t, err)
	keys := maintenanceKeys(t, path)

	ro, err := OpenExisting(path, compactCheckBusy)
	require.NoError(t, err)
	defer ro.Close()
	c, err := ro.CheckMessagesSearchRebuild()
	require.NoError(t, err)
	assert.True(t, c.Pending)
	assert.Positive(t, c.LegacyBytes)
	assert.Equal(t, c.LegacyBytes*3/2, c.NeedsDiskBytes)
	assert.True(t, c.DiskOK)
	assert.Equal(t, int64(1<<50), c.FreeDiskBytes)
	dbBytes := info.Size()
	assert.Less(t, c.LegacyBytes, dbBytes, "the legacy size is the whole file, not its pages")

	after, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, info.ModTime(), after.ModTime())
	assert.Equal(t, keys, maintenanceKeys(t, path))
}

func TestCheckMessagesSearchRebuild_InMemoryReadsDiskOK(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "C1", TS: "1.000001", UserID: "U1", Text: "indexable"}))
	require.NoError(t, ReplayMessagesSearchUpgradeForTest(d))
	stubFreeDisk(t, 0)
	c, err := d.CheckMessagesSearchRebuild()
	require.NoError(t, err)
	assert.True(t, c.Pending)
	assert.True(t, c.DiskOK)
}

// Another process finishing the fill between two of this call's chunks ends
// the call at its next chunk: no cursor written back, no rescan.
func TestRebuildMessagesSearch_OtherProcessFinishesFirst(t *testing.T) {
	b, path, _ := pendingFillDB(t)
	a, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = a.Close() })
	fired := false
	setChunkHook(t, func(int) {
		if fired {
			return
		}
		fired = true
		res, err := a.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
		require.NoError(t, err)
		require.True(t, res.Done)
	})

	res, err := b.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{ChunkRows: 4})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true, Indexed: 3, Chunks: 1}, res)
	assertIndexMatchesMessages(t, b)
	assertFillFinished(t, b)
}

// A message above the cursor edited during the fill is indexed by the
// trigger and skipped by the fill: one index row, with the new text.
func TestRebuildMessagesSearch_EditAboveCursorIndexedOnce(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	var above int64
	require.NoError(t, d.QueryRow(`SELECT rowid FROM messages ORDER BY rowid LIMIT 1 OFFSET 20`).Scan(&above))
	setChunkHook(t, func(chunk int) {
		if chunk == 1 {
			_, err := d.Exec(`UPDATE messages SET text = 'reworded upstream note' WHERE rowid = ?`, above)
			require.NoError(t, err)
		}
	})

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{ChunkRows: 4})
	require.NoError(t, err)
	require.True(t, res.Done)
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE rowid = ?`, above))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'reworded'`))
	assert.Equal(t, 19, int(res.Indexed), "the edited row is the trigger's, not the fill's")
	assertIndexMatchesMessages(t, d)
}

// The pause between chunks ends early when ctx is cancelled.
func TestRebuildMessagesSearch_GapHonoursCancel(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	ftsRebuildChunkGap = time.Hour // noChunkGap's cleanup restores it
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	setChunkHook(t, func(int) { cancel() })

	start := time.Now()
	res, err := d.RebuildMessagesSearch(ctx, FTSRebuildOptions{ChunkRows: 4})
	require.ErrorIs(t, err, context.Canceled)
	assert.Equal(t, 1, res.Chunks)
	assert.Less(t, time.Since(start), time.Minute)
}

// BenchmarkMessagesSearchFillChunk times default-size chunks — each one write
// lock hold — walking a synthetic 200k-message file database from the start,
// so later chunks merge into an index that has grown:
// go test ./internal/db -run '^$' -bench MessagesSearchFillChunk -benchtime 40x
func BenchmarkMessagesSearchFillChunk(b *testing.B) {
	noChunkGap(b)
	prev := freeDiskBytes
	freeDiskBytes = func(string) (int64, error) { return 1 << 50, nil }
	b.Cleanup(func() { freeDiskBytes = prev })
	d, err := Open(filepath.Join(b.TempDir(), "bench.db"))
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = d.Close() })
	tx, err := d.Begin()
	if err != nil {
		b.Fatal(err)
	}
	pad := "please review the rollout plan for the payments service before friday and leave comments on the open questions in the doc"
	const chunks = 40
	if b.N > chunks {
		b.Skipf("-benchtime at most %dx: the table holds %d chunks", chunks, chunks)
	}
	for i := range chunks * ftsRebuildChunkRows {
		if _, err := tx.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES (?, ?, 'U1', ?)`,
			fmt.Sprintf("C%d", i%50), fmt.Sprintf("%d.000001", 1700000000+i), fmt.Sprintf("%d %s topic%d", i, pad, i%997)); err != nil {
			b.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		b.Fatal(err)
	}
	if err := ReplayMessagesSearchUpgradeForTest(d); err != nil {
		b.Fatal(err)
	}
	ctx := context.Background()
	b.ResetTimer()
	for range b.N {
		indexed, done, err := d.fillMessagesSearchChunk(ctx, ftsRebuildChunkRows, false)
		if err != nil || done || indexed != ftsRebuildChunkRows {
			b.Fatalf("chunk: indexed=%d done=%v err=%v", indexed, done, err)
		}
	}
}
