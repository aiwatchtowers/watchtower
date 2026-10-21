package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
// pending (the real 00147 upgrade replayed), and returns it with its path
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
	assert.Equal(t, FTSRebuildResult{Done: true, Indexed: 20, Chunks: 8, DrainChunks: 1}, res, "one drop, then 7 fill chunks")

	for _, q := range ftsFillQueries {
		hits, err := d.SearchMessages(q, SearchOpts{})
		require.NoError(t, err)
		assert.Equal(t, before[q], hits, q)
	}
	assertIndexMatchesMessages(t, d)
	assertFillFinished(t, d)
}

// setChunkTextBytes sets the fill chunk's text budget for the test.
func setChunkTextBytes(t *testing.T, n int64) {
	t.Helper()
	prev := ftsRebuildChunkTextBytes
	ftsRebuildChunkTextBytes = n
	t.Cleanup(func() { ftsRebuildChunkTextBytes = prev })
}

// pendingLongFillDB opens a file database holding seedFillMessages followed
// by one message per entry of sizes (each that many bytes of text) with the
// fill pending.
func pendingLongFillDB(t *testing.T, sizes ...int) *DB {
	t.Helper()
	noChunkGap(t)
	d, err := Open(compactFixture(t))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	seedFillMessages(t, d)
	for i, n := range sizes {
		text := strings.Repeat("rollout ", n/8+1)[:n]
		_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C9', ?, 'U1', ?)`,
			fmt.Sprintf("%d.000001", 1800000000+i), text)
		require.NoError(t, err)
	}
	require.NoError(t, ReplayMessagesSearchUpgradeForTest(d))
	return d
}

func TestRebuildMessagesSearch_ChunkBoundedByTextBytes(t *testing.T) {
	// The 20 short indexable messages hold well under 1000 bytes. With a
	// 4000-byte budget the first chunk takes them and two 3000-byte messages
	// (the text before the second is under the budget), the second the other
	// two: a rows-only bound would fill everything in one chunk.
	d := pendingLongFillDB(t, 3000, 3000, 3000, 3000)
	setChunkTextBytes(t, 4000)

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true, Indexed: 24, Chunks: 3, DrainChunks: 1}, res, "one drop, then 2 fill chunks")
	hits, err := d.SearchMessages("rollout", SearchOpts{})
	require.NoError(t, err)
	assert.Len(t, hits, 4)
	assertIndexMatchesMessages(t, d)
	assertFillFinished(t, d)
}

func TestRebuildMessagesSearch_MessageOverTextBudgetProgresses(t *testing.T) {
	// Each long message alone exceeds the budget: every chunk still takes at
	// least one row, so each gets a chunk of its own after the short ones.
	d := pendingLongFillDB(t, 5000, 5000)
	setChunkTextBytes(t, 100)

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
	require.NoError(t, err)
	assert.True(t, res.Done)
	assert.EqualValues(t, 22, res.Indexed)
	assert.Greater(t, res.Chunks-res.DrainChunks, 2, "the long messages in chunks of their own")
	assertIndexMatchesMessages(t, d)
	assertFillFinished(t, d)
}

func TestRebuildMessagesSearch_ResumesAfterInterrupt(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	setChunkHook(t, func(chunk int) {
		if chunk == 3 { // the drop, then two fill chunks
			cancel()
		}
	})

	res, err := d.RebuildMessagesSearch(ctx, FTSRebuildOptions{ChunkRows: 4})
	require.ErrorIs(t, err, context.Canceled)
	assert.Equal(t, 3, res.Chunks)
	assert.False(t, res.Done)
	var eighth, cursor int64
	require.NoError(t, d.QueryRow(`SELECT rowid FROM messages ORDER BY rowid LIMIT 1 OFFSET 7`).Scan(&eighth))
	cursor, err = readMaintenanceInt(d, maintFTSRebuildCursor)
	require.NoError(t, err)
	assert.Equal(t, eighth, cursor)
	pending, _, err := readMaintenance(d, maintFTSRebuildPending)
	require.NoError(t, err)
	assert.Equal(t, "1", pending)
	assert.False(t, hasSchemaTable(t, d, "messages_fts_legacy"), "the legacy index goes before the fill")

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
		if chunk != 2 { // the drop, then the first fill chunk
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

// TestRebuildMessagesSearch_DrainLegacyInChunks pins the daemon's path:
// with DrainLegacy the legacy shadow rows go in chunk transactions, the
// table stays until they are gone, nothing is filled before it is dropped,
// and the search results are unchanged at the end.
func TestRebuildMessagesSearch_DrainLegacyInChunks(t *testing.T) {
	d, _, before := pendingFillDB(t)
	t.Cleanup(SetFTSLegacyDrainRowsForTest(4))
	opts := FTSRebuildOptions{Budget: time.Nanosecond, ChunkRows: 100, DrainLegacy: true}
	left := legacyShadowRows(t, d)
	require.Greater(t, left, 8, "the fixture must need more than one drain chunk")

	freeCalls := 0
	for range 30 {
		if !hasSchemaTable(t, d, "messages_fts_legacy") {
			break
		}
		res, err := d.RebuildMessagesSearch(context.Background(), opts)
		require.NoError(t, err)
		require.False(t, res.Done)
		assert.Zero(t, res.Indexed, "filled before the legacy index was gone")
		assert.Equal(t, FTSRebuildResult{Chunks: 1, DrainChunks: 1}, res)
		freeCalls++
		if hasSchemaTable(t, d, "messages_fts_legacy") {
			now := legacyShadowRows(t, d)
			require.Less(t, now, left, "a drain chunk deleted nothing")
			left = now
		}
	}
	require.False(t, hasSchemaTable(t, d, "messages_fts_legacy"), "the drain never finished")
	assert.GreaterOrEqual(t, freeCalls, 3, "two drain chunks at least, then the drop")
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	pending, _, err := readMaintenance(d, maintFTSRebuildPending)
	require.NoError(t, err)
	assert.Equal(t, "1", pending, "the fill is still pending after the drop")

	res, err := d.RebuildMessagesSearch(context.Background(), opts)
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Indexed: 20, Chunks: 1}, res, "one chunk fills all 25 rows")
	res, err = d.RebuildMessagesSearch(context.Background(), opts)
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true}, res)
	assertFillFinished(t, d)
	assertIndexMatchesMessages(t, d)
	for _, q := range ftsFillQueries {
		hits, err := d.SearchMessages(q, SearchOpts{})
		require.NoError(t, err)
		assert.Equal(t, before[q], hits, q)
	}
}

// TestRebuildMessagesSearch_NoDrainDropsDirectly pins the launch step's
// path: without DrainLegacy the first chunk drops the untouched legacy table
// in one transaction, before any fill chunk.
func TestRebuildMessagesSearch_NoDrainDropsDirectly(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	require.Positive(t, legacyShadowRows(t, d))

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{Budget: time.Nanosecond, ChunkRows: 100})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Chunks: 1, DrainChunks: 1}, res)
	assert.False(t, hasSchemaTable(t, d, "messages_fts_legacy"))
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))

	res, err = d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{ChunkRows: 100})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true, Indexed: 20, Chunks: 1}, res)
	assertFillFinished(t, d)
	assertIndexMatchesMessages(t, d)
}

// TestRebuildMessagesSearch_DirectDropAfterPartialDrain pins the cross-path
// case: the daemon drained part of the legacy shadow tables, then the launch
// step (no DrainLegacy) drops the rest directly and fills.
func TestRebuildMessagesSearch_DirectDropAfterPartialDrain(t *testing.T) {
	d, _, before := pendingFillDB(t)
	t.Cleanup(SetFTSLegacyDrainRowsForTest(4))
	full := legacyShadowRows(t, d)
	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{Budget: time.Nanosecond, ChunkRows: 100, DrainLegacy: true})
	require.NoError(t, err)
	require.Equal(t, FTSRebuildResult{Chunks: 1, DrainChunks: 1}, res)
	require.Less(t, legacyShadowRows(t, d), full)
	require.Positive(t, legacyShadowRows(t, d), "the drain must be partial")

	res, err = d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true, Indexed: 20, Chunks: 2, DrainChunks: 1}, res)
	assertFillFinished(t, d)
	assertIndexMatchesMessages(t, d)
	for _, q := range ftsFillQueries {
		hits, err := d.SearchMessages(q, SearchOpts{})
		require.NoError(t, err)
		assert.Equal(t, before[q], hits, q)
	}
}

// TestCheckMessagesSearchRebuild_FixedFloor pins the fill's disk rule: a
// fixed floor of free space, whatever the legacy index's size.
func TestCheckMessagesSearchRebuild_FixedFloor(t *testing.T) {
	d, _, _ := pendingFillDB(t)
	stubFreeDisk(t, ftsRebuildMinFreeBytes-1)
	c, err := d.CheckMessagesSearchRebuild()
	require.NoError(t, err)
	assert.Equal(t, MessagesSearchCheck{Pending: true, NeedsDiskBytes: ftsRebuildMinFreeBytes, FreeDiskBytes: ftsRebuildMinFreeBytes - 1}, c)

	stubFreeDisk(t, ftsRebuildMinFreeBytes)
	c, err = d.CheckMessagesSearchRebuild()
	require.NoError(t, err)
	assert.True(t, c.DiskOK, "exactly the floor")
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
	d := rawFileDBAt(t, 147)
	require.True(t, hasSchemaTable(t, d, "messages_fts_legacy"))
	require.Equal(t, 1, maintenanceKeyCount(t, d))

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true, Chunks: 1, DrainChunks: 1}, res)
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
	assert.Equal(t, FTSRebuildResult{Done: true, Indexed: 20, Chunks: 8, DrainChunks: 1}, res, "the drop sets the pending key")
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
	require.NoError(t, gooseUpTo(raw, "migrations", 146))
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

func TestCheckMessagesSearchRebuild_ReadsOnly(t *testing.T) {
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
	assert.Equal(t, MessagesSearchCheck{Pending: true, NeedsDiskBytes: ftsRebuildMinFreeBytes, FreeDiskBytes: 1 << 50, DiskOK: true}, c)

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
	setChunkHook(t, func(chunk int) {
		if fired || chunk != 2 { // the drop, then the first fill chunk
			return
		}
		fired = true
		res, err := a.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
		require.NoError(t, err)
		require.True(t, res.Done)
	})

	res, err := b.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{ChunkRows: 4})
	require.NoError(t, err)
	assert.Equal(t, FTSRebuildResult{Done: true, Indexed: 3, Chunks: 2, DrainChunks: 1}, res)
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

// TestRebuildMessagesSearch_FileDoesNotGrow pins the order that lets the
// fill run on a nearly full volume: the legacy index is freed before the new
// one is written, so the new index reuses its pages and the file never holds
// both. page_count is sampled after every chunk; the slack (a tenth of the
// legacy index) covers FTS5 segment merges and freelist trunk pages. Filling
// first would grow the file by about the whole legacy index.
func TestRebuildMessagesSearch_FileDoesNotGrow(t *testing.T) {
	noChunkGap(t)
	path := compactFixture(t)
	d, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	tx, err := d.Begin()
	require.NoError(t, err)
	for i := range 4000 {
		_, err := tx.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES (?, ?, 'U1', ?)`,
			fmt.Sprintf("C%d", i%7), fmt.Sprintf("%d.000001", 1700000000+i),
			fmt.Sprintf("note %d about the topic%d rollout, word%d and word%d, owner%d", i, i%311, i%523, i%977, i%41))
		require.NoError(t, err)
	}
	require.NoError(t, tx.Commit())
	require.NoError(t, ReplayMessagesSearchUpgradeForTest(d))
	pages := func() int { return queryInt(t, d, `PRAGMA page_count`) }
	legacyPages := queryInt(t, d, `SELECT COUNT(*) FROM dbstat WHERE name LIKE 'messages_fts_legacy%'`)
	require.Greater(t, legacyPages, 100, "the fixture's legacy index must be large enough to measure")
	before := pages()
	most := before
	setChunkHook(t, func(int) { most = max(most, pages()) })

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{ChunkRows: 500})
	require.NoError(t, err)
	require.True(t, res.Done)
	most = max(most, pages())
	assert.LessOrEqual(t, most, before+legacyPages/10,
		"the file grew by %d pages during the fill (legacy index: %d pages)", most-before, legacyPages)
	assertIndexMatchesMessages(t, d)
}

// TestRebuildMessagesSearch_SearchAfterCompact pins that a compaction after
// the fill keeps the index in step with messages: VACUUM keeps the rowids
// the index is keyed by, so search returns the same results.
func TestRebuildMessagesSearch_SearchAfterCompact(t *testing.T) {
	d, path, before := pendingFillDB(t)
	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
	require.NoError(t, err)
	require.True(t, res.Done)
	_, err = d.Exec(`DELETE FROM messages WHERE rowid IN (SELECT rowid FROM messages ORDER BY rowid LIMIT 2)`)
	require.NoError(t, err)
	want := map[string][]Message{}
	for _, q := range ftsFillQueries {
		hits, err := d.SearchMessages(q, SearchOpts{})
		require.NoError(t, err)
		require.NotEmpty(t, hits, q)
		want[q] = hits
	}
	require.NotEqual(t, before, want, "the deletes must change some results")
	require.NoError(t, d.Close())

	cres, err := Compact(context.Background(), path, CompactOptions{Reason: "manual", Version: "1.0.0"})
	require.NoError(t, err)
	require.True(t, cres.Compacted)

	d2, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d2.Close() })
	for _, q := range ftsFillQueries {
		hits, err := d2.SearchMessages(q, SearchOpts{})
		require.NoError(t, err)
		assert.Equal(t, want[q], hits, q)
	}
	assertIndexMatchesMessages(t, d2)
}

func TestMessagesSearchPendingAt(t *testing.T) {
	d, path, _ := pendingFillDB(t)
	pending, err := MessagesSearchPendingAt(path)
	require.NoError(t, err)
	assert.True(t, pending)

	res, err := d.RebuildMessagesSearch(context.Background(), FTSRebuildOptions{})
	require.NoError(t, err)
	require.True(t, res.Done)
	pending, err = MessagesSearchPendingAt(path)
	require.NoError(t, err)
	assert.False(t, pending)

	_, err = MessagesSearchPendingAt(filepath.Join(t.TempDir(), "missing.db"))
	assert.Error(t, err)
}

func TestIsInterruption(t *testing.T) {
	assert.True(t, isInterruption(context.Canceled))
	assert.True(t, isInterruption(fmt.Errorf("chunk: %w", context.DeadlineExceeded)))
	assert.False(t, isInterruption(errors.New("disk I/O error")))

	// A statement the cancelled ctx interrupts.
	d := openTestDB(t)
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(20 * time.Millisecond); cancel() }()
	_, err := d.ExecContext(ctx, `WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT COUNT(*) FROM n`)
	require.Error(t, err)
	assert.True(t, isInterruption(err), "%v", err)
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
	if _, kind, err := d.fillMessagesSearchChunk(ctx, ftsRebuildChunkRows, false); err != nil || kind != chunkDropped {
		b.Fatalf("legacy drop: kind=%v err=%v", kind, err)
	}
	b.ResetTimer()
	for range b.N {
		indexed, kind, err := d.fillMessagesSearchChunk(ctx, ftsRebuildChunkRows, false)
		if err != nil || kind != chunkFilled || indexed != ftsRebuildChunkRows {
			b.Fatalf("chunk: indexed=%d kind=%v err=%v", indexed, kind, err)
		}
	}
}
