package daemon

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The tests here mutate searchRebuildBudget, searchRebuildChunkRows and the
// db's free-disk, chunk-gap and drain seams; no t.Parallel.

// newSearchRebuildTestDaemon builds a Daemon over a file database (the
// fill's disk rule reads the volume; an in-memory database always fits) and
// returns its log buffer.
func newSearchRebuildTestDaemon(t *testing.T) (*Daemon, *db.DB, *bytes.Buffer) {
	t.Helper()
	orch, cfg, _ := testDaemonWithTempHome(t)
	database, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	logs := &bytes.Buffer{}
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(logs, "", 0))
	d.SetDB(database)
	t.Cleanup(db.SetFTSRebuildChunkGapForTest(0))
	return d, database, logs
}

// seedPendingSearchFill inserts n indexable messages and replays the 00147
// upgrade, so the fill is pending with an empty new index.
func seedPendingSearchFill(t *testing.T, database *db.DB, n int) {
	t.Helper()
	for i := range n {
		_, err := database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', ?, 'U1', ?)`,
			fmt.Sprintf("%d.000001", 1700000000+i), fmt.Sprintf("deploy note %d", i))
		require.NoError(t, err)
	}
	require.NoError(t, db.ReplayMessagesSearchUpgradeForTest(database))
	check, err := database.CheckMessagesSearchRebuild()
	require.NoError(t, err)
	require.True(t, check.Pending)
}

func setSearchRebuildSeams(t *testing.T, budget time.Duration, chunkRows int) {
	t.Helper()
	prevBudget, prevRows := searchRebuildBudget, searchRebuildChunkRows
	searchRebuildBudget, searchRebuildChunkRows = budget, chunkRows
	t.Cleanup(func() { searchRebuildBudget, searchRebuildChunkRows = prevBudget, prevRows })
}

func searchRebuildQueryInt(t *testing.T, database *db.DB, q string) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(q).Scan(&n))
	return n
}

func hasLegacySearchTable(t *testing.T, database *db.DB) bool {
	t.Helper()
	return searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM sqlite_master WHERE name = 'messages_fts_legacy'`) > 0
}

func TestPhaseMessagesSearchRebuild_InertWhenNotPending(t *testing.T) {
	d, database, logs := newSearchRebuildTestDaemon(t)

	d.phaseMessagesSearchRebuild(context.Background())

	assert.Empty(t, logs.String())
	assert.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM db_maintenance`))
	assert.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM pipeline_runs`))
}

func TestPhaseMessagesSearchRebuild_InertOnCancelledCtx(t *testing.T) {
	d, database, logs := newSearchRebuildTestDaemon(t)
	seedPendingSearchFill(t, database, 3)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	d.phaseMessagesSearchRebuild(ctx)

	assert.Empty(t, logs.String())
	assert.True(t, hasLegacySearchTable(t, database))
	assert.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages_fts`))
}

func TestPhaseMessagesSearchRebuild_FillsAcrossCycles(t *testing.T) {
	d, database, logs := newSearchRebuildTestDaemon(t)
	seedPendingSearchFill(t, database, 10)
	setSearchRebuildSeams(t, time.Nanosecond, 3)
	fillKeys := func() int {
		return searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM db_maintenance WHERE key LIKE 'fts_rebuild_%'`)
	}

	d.phaseMessagesSearchRebuild(context.Background())
	assert.False(t, hasLegacySearchTable(t, database), "cycle 1 frees the small legacy index in one chunk")
	assert.Contains(t, logs.String(), "search index: clearing the old index, continuing next cycle")
	d.phaseMessagesSearchRebuild(context.Background())
	check, err := database.CheckMessagesSearchRebuild()
	require.NoError(t, err)
	require.True(t, check.Pending, "one chunk of 3 must not finish 10 messages")
	assert.Positive(t, searchRebuildQueryInt(t, database, `SELECT CAST(value AS INTEGER) FROM db_maintenance WHERE key = 'fts_rebuild_cursor_messages'`))
	assert.Contains(t, logs.String(), "search index: 3 messages indexed, continuing next cycle")

	for cycle := 3; cycle <= 7 && fillKeys() > 0; cycle++ {
		d.phaseMessagesSearchRebuild(context.Background())
	}

	assert.Zero(t, fillKeys(), "the fill must finish within 7 cycles")
	assert.Equal(t, 10, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages_fts`))
	assert.Equal(t, 10, searchRebuildQueryInt(t, database, `SELECT COUNT(DISTINCT rowid) FROM messages_fts`))
	assert.Contains(t, logs.String(), "search index: rebuilt")
	assert.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM pipeline_runs`))
}

func TestPhaseMessagesSearchRebuild_NotBlockedByCompactionGaveUp(t *testing.T) {
	d, database, logs := newSearchRebuildTestDaemon(t)
	seedPendingSearchFill(t, database, 4)
	_, err := database.Exec(`INSERT INTO db_maintenance(key, value) VALUES ('compact_failures', '3'), ('compact_failures_version', 'dev')`)
	require.NoError(t, err)

	d.phaseMessagesSearchRebuild(context.Background())

	assert.False(t, hasLegacySearchTable(t, database))
	assert.Equal(t, 4, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages_fts`))
	assert.Contains(t, logs.String(), "search index: rebuilt")
}

func TestPhaseMessagesSearchRebuild_DiskShortLogsOnce(t *testing.T) {
	d, database, logs := newSearchRebuildTestDaemon(t)
	seedPendingSearchFill(t, database, 4)
	t.Cleanup(db.SetFreeDiskBytesForTest(func(string) (int64, error) { return 0, nil }))

	d.phaseMessagesSearchRebuild(context.Background())
	d.phaseMessagesSearchRebuild(context.Background())

	assert.Equal(t, 1, strings.Count(logs.String(), "search index: rebuild needs"), logs.String())
	assert.Equal(t, 1, strings.Count(logs.String(), "\n"), "nothing but the disk line: %q", logs.String())
	assert.True(t, hasLegacySearchTable(t, database))
	assert.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages_fts`))
	check, err := database.CheckMessagesSearchRebuild()
	require.NoError(t, err)
	assert.True(t, check.Pending)
}

// TestPhaseMessagesSearchRebuild_DrainsLegacyBeforeDrop pins the daemon's
// order: the legacy index is emptied over several cycles of short
// transactions and dropped, never in one DROP beside live writers, before
// any row of the new index is filled.
func TestPhaseMessagesSearchRebuild_DrainsLegacyBeforeDrop(t *testing.T) {
	d, database, logs := newSearchRebuildTestDaemon(t)
	seedPendingSearchFill(t, database, 6)
	setSearchRebuildSeams(t, time.Nanosecond, 100)
	t.Cleanup(db.SetFTSLegacyDrainRowsForTest(2))

	freeCycles := 0
	for range 20 {
		if !hasLegacySearchTable(t, database) {
			break
		}
		d.phaseMessagesSearchRebuild(context.Background())
		freeCycles++
		require.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages_fts`), "filled before the legacy index was gone")
	}
	assert.False(t, hasLegacySearchTable(t, database), "the drain never finished")
	assert.GreaterOrEqual(t, freeCycles, 3, "6 content rows at 2 per chunk need several cycles")
	assert.Contains(t, logs.String(), "search index: clearing the old index, continuing next cycle")

	d.phaseMessagesSearchRebuild(context.Background())
	assert.Equal(t, 6, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages_fts`), "one chunk fills every row")
	d.phaseMessagesSearchRebuild(context.Background())
	assert.Contains(t, logs.String(), "search index: rebuilt")
	assert.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM db_maintenance WHERE key LIKE 'fts_rebuild_%'`))
}

// stubSearchFillDisk sets the fill's free-space floor and the free space the
// check reads.
func stubSearchFillDisk(t *testing.T, floor, free int64) {
	t.Helper()
	t.Cleanup(db.SetFTSRebuildMinFreeBytesForTest(floor))
	t.Cleanup(db.SetFreeDiskBytesForTest(func(string) (int64, error) { return free, nil }))
}

// TestPhaseMessagesSearchRebuild_ShortDiskAboveFloorCompletes pins the fix
// for a volume with less free space than the legacy index: the daemon frees
// the legacy index first and fills into its pages, so free space just above
// the small floor is enough, even with a Slack sync adding a message before
// every cycle (phaseSlackSync runs before this phase). The old rule — free
// space for the whole new index next to the legacy one — skipped such a
// volume forever.
func TestPhaseMessagesSearchRebuild_ShortDiskAboveFloorCompletes(t *testing.T) {
	d, database, logs := newSearchRebuildTestDaemon(t)
	seedPendingSearchFill(t, database, 6)
	legacyBytes := searchRebuildQueryInt(t, database, `SELECT SUM(pgsize) FROM dbstat WHERE name LIKE 'messages_fts_legacy%'`)
	const floor = 4096
	require.Greater(t, legacyBytes, 2*floor, "the free space must be well below the legacy index's size")
	stubSearchFillDisk(t, floor, floor+1)
	setSearchRebuildSeams(t, time.Nanosecond, 100)
	t.Cleanup(db.SetFTSLegacyDrainRowsForTest(2))

	syncMessage := func(i int) {
		_, err := database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C2', ?, 'U1', ?)`,
			fmt.Sprintf("%d.000001", 1800000000+i), fmt.Sprintf("synced note %d", i))
		require.NoError(t, err)
	}
	cycles := 0
	for ; cycles < 20 && hasLegacySearchTable(t, database); cycles++ {
		syncMessage(cycles)
		d.phaseMessagesSearchRebuild(context.Background())
	}
	require.False(t, hasLegacySearchTable(t, database), "the legacy index was never freed")
	require.GreaterOrEqual(t, cycles, 2, "the drain must take several cycles")

	searchRebuildBudget = time.Minute // setSearchRebuildSeams restores it
	syncMessage(cycles)
	d.phaseMessagesSearchRebuild(context.Background())

	indexable := searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages WHERE text != '' AND is_deleted = 0`)
	assert.Equal(t, indexable, searchRebuildQueryInt(t, database, `SELECT COUNT(DISTINCT rowid) FROM messages_fts`))
	assert.Equal(t, indexable, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages_fts`))
	assert.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM db_maintenance WHERE key LIKE 'fts_rebuild_%'`))
	assert.NotContains(t, logs.String(), "rebuild needs")
	assert.Contains(t, logs.String(), "search index: rebuilt")
}

// TestPhaseMessagesSearchRebuild_BelowFloorSkipsAndRelogs pins the floor and
// the log latch: below the floor nothing is written and the line is logged
// once; a cycle that finds room resets the latch, so a later short volume is
// logged again.
func TestPhaseMessagesSearchRebuild_BelowFloorSkipsAndRelogs(t *testing.T) {
	d, database, logs := newSearchRebuildTestDaemon(t)
	seedPendingSearchFill(t, database, 30)
	setSearchRebuildSeams(t, time.Nanosecond, 3)
	free := int64(4095)
	t.Cleanup(db.SetFTSRebuildMinFreeBytesForTest(4096))
	t.Cleanup(db.SetFreeDiskBytesForTest(func(string) (int64, error) { return free, nil }))

	d.phaseMessagesSearchRebuild(context.Background())
	d.phaseMessagesSearchRebuild(context.Background())
	assert.Equal(t, 1, strings.Count(logs.String(), "search index: rebuild needs"), logs.String())
	assert.True(t, hasLegacySearchTable(t, database), "a cycle below the floor wrote")

	free = 4096
	d.phaseMessagesSearchRebuild(context.Background())
	assert.False(t, hasLegacySearchTable(t, database), "a cycle at the floor must drop the legacy index")

	free = 4095
	d.phaseMessagesSearchRebuild(context.Background())
	assert.Equal(t, 2, strings.Count(logs.String(), "search index: rebuild needs"), logs.String())
}

// TestDaemon_RunSync_RebuildsSearchIndex pins that runSync runs the fill
// phase, after the Slack sync whose messages the triggers index.
func TestDaemon_RunSync_RebuildsSearchIndex(t *testing.T) {
	order := runSyncCallOrder(t)
	rebuild, ok := order["phaseMessagesSearchRebuild"]
	require.True(t, ok, "runSync must call phaseMessagesSearchRebuild")
	slackSync, ok := order["phaseSlackSync"]
	require.True(t, ok, "runSync must call phaseSlackSync")
	assert.Greater(t, rebuild, slackSync)
}
