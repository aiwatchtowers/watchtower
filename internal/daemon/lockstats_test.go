package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/db/lockmetrics"
)

// readLockEvents returns the events of one kind in the sink beside dbPath.
func readLockEvents(t *testing.T, dbPath, kind string) []lockmetrics.Event {
	t.Helper()
	f, err := os.Open(filepath.Join(filepath.Dir(dbPath), lockmetrics.FileName))
	if os.IsNotExist(err) {
		return nil
	}
	require.NoError(t, err)
	defer func() { _ = f.Close() }()
	var out []lockmetrics.Event
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var e lockmetrics.Event
		require.NoError(t, json.Unmarshal(sc.Bytes(), &e), "line %q", sc.Text())
		if e.Kind == kind {
			out = append(out, e)
		}
	}
	require.NoError(t, sc.Err())
	return out
}

// Every sync cycle starts with one WAL sample; a cancelled cycle (shutdown)
// takes none.
func TestDaemon_RunSyncSamplesWALOncePerCycle(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	path := filepath.Join(t.TempDir(), "watchtower.db")
	database, err := db.Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	lockmetrics.Configure(path)
	t.Cleanup(func() { lockmetrics.Configure("") })

	d := newQuietDaemon(t)
	d.SetDB(database)

	d.runSync(context.Background())
	wal := readLockEvents(t, path, lockmetrics.KindWAL)
	require.Len(t, wal, 1, "one wal event per cycle")
	assert.GreaterOrEqual(t, wal[0].WALBytes, int64(0))
	assert.Regexp(t, `^busy=-?\d+ log=-?\d+ ckpt=-?\d+$`, wal[0].Checkpoint)
	assert.Empty(t, wal[0].Err)
	assert.Equal(t, database.Stats().MaxOpenConnections, d.lockStats.MaxOpenConnections,
		"the cycle keeps the pool stats for the next delta")

	d.runSync(context.Background())
	assert.Len(t, readLockEvents(t, path, lockmetrics.KindWAL), 2, "the next cycle samples again")

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d.runSync(ctx)
	assert.Len(t, readLockEvents(t, path, lockmetrics.KindWAL), 2, "a cancelled cycle takes no sample")
}

func TestDaemon_SampleLockStatsWithoutDB(t *testing.T) {
	d := newQuietDaemon(t)
	assert.NotPanics(t, func() { d.sampleLockStats(context.Background()) })
}
