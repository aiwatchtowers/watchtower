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
// db's free-disk seam; no t.Parallel.

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
	return d, database, logs
}

// seedPendingSearchFill inserts n indexable messages and replays the 00146
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

	d.phaseMessagesSearchRebuild(context.Background())
	check, err := database.CheckMessagesSearchRebuild()
	require.NoError(t, err)
	require.True(t, check.Pending, "one chunk of 3 must not finish 10 messages")
	assert.Positive(t, searchRebuildQueryInt(t, database, `SELECT CAST(value AS INTEGER) FROM db_maintenance WHERE key = 'fts_rebuild_cursor_messages'`))
	assert.Contains(t, logs.String(), "search index: 3 messages indexed, continuing next cycle")

	for cycle := 2; cycle <= 5 && hasLegacySearchTable(t, database); cycle++ {
		d.phaseMessagesSearchRebuild(context.Background())
	}

	assert.False(t, hasLegacySearchTable(t, database), "the fill must finish within 5 cycles")
	assert.Equal(t, 10, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages_fts`))
	assert.Equal(t, 10, searchRebuildQueryInt(t, database, `SELECT COUNT(DISTINCT rowid) FROM messages_fts`))
	assert.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM db_maintenance WHERE key LIKE 'fts_rebuild_%'`))
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
// completion: the legacy index is emptied over several cycles of short
// transactions before it is dropped, never in one DROP beside live writers.
func TestPhaseMessagesSearchRebuild_DrainsLegacyBeforeDrop(t *testing.T) {
	d, database, logs := newSearchRebuildTestDaemon(t)
	seedPendingSearchFill(t, database, 6)
	setSearchRebuildSeams(t, time.Nanosecond, 100)
	t.Cleanup(db.SetFTSLegacyDrainRowsForTest(2))

	d.phaseMessagesSearchRebuild(context.Background())
	require.Equal(t, 6, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM messages_fts`), "cycle 1 fills every row")
	require.True(t, hasLegacySearchTable(t, database))

	drainCycles := 0
	for range 20 {
		if !hasLegacySearchTable(t, database) {
			break
		}
		d.phaseMessagesSearchRebuild(context.Background())
		drainCycles++
	}

	assert.False(t, hasLegacySearchTable(t, database), "the drain never finished")
	assert.GreaterOrEqual(t, drainCycles, 3, "6 content rows at 2 per chunk need several cycles")
	assert.Contains(t, logs.String(), "search index: clearing the old index, continuing next cycle")
	assert.Contains(t, logs.String(), "search index: rebuilt")
	assert.Zero(t, searchRebuildQueryInt(t, database, `SELECT COUNT(*) FROM db_maintenance WHERE key LIKE 'fts_rebuild_%'`))
}
