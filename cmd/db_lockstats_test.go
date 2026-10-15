package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db/lockmetrics"
)

// lockstatsTestEnv sets up a config whose workspace has a DB directory and
// returns the dblock.jsonl path next to the DB, with no log in either
// generation: the setup's own db.Open measures its migration, and on a loaded
// machine that crosses the threshold and lands in the very log the tests
// control. Flags are reset afterwards.
func lockstatsTestEnv(t *testing.T) string {
	t.Helper()
	cleanup := setupWatchTestEnv(t)
	t.Cleanup(cleanup)
	oldSince, oldJSON := dbLockstatsFlagSince, dbLockstatsFlagJSON
	t.Cleanup(func() { dbLockstatsFlagSince, dbLockstatsFlagJSON = oldSince, oldJSON })
	dbLockstatsFlagSince, dbLockstatsFlagJSON = 24*time.Hour, false

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	path := filepath.Join(filepath.Dir(cfg.DBPath()), lockmetrics.FileName)
	for _, p := range []string{path, path + ".1"} {
		require.NoError(t, os.RemoveAll(p))
	}
	return path
}

// writeLockLog writes synthetic events (seeded from time.Now, no fixed
// dates) plus extra raw lines to path.
func writeLockLog(t *testing.T, path string, events []lockmetrics.Event, raw ...string) {
	t.Helper()
	var b bytes.Buffer
	for _, e := range events {
		line, err := json.Marshal(e)
		require.NoError(t, err)
		b.Write(line)
		b.WriteByte('\n')
	}
	for _, l := range raw {
		b.WriteString(l + "\n")
	}
	require.NoError(t, os.WriteFile(path, b.Bytes(), 0o600))
}

func runLockstats(t *testing.T) string {
	t.Helper()
	var out bytes.Buffer
	dbLockstatsCmd.SetOut(&out)
	t.Cleanup(func() { dbLockstatsCmd.SetOut(nil) })
	require.NoError(t, dbLockstatsCmd.RunE(dbLockstatsCmd, nil))
	return out.String()
}

func TestDbLockstatsSubcommandRegistered(t *testing.T) {
	c, _, err := rootCmd.Find([]string{"db", "lockstats"})
	require.NoError(t, err)
	assert.Equal(t, "lockstats", c.Name())
	assert.NotNil(t, c.Flags().Lookup("since"))
	assert.NotNil(t, c.Flags().Lookup("json"))
}

func TestDbLockstats_NoLogYet(t *testing.T) {
	path := lockstatsTestEnv(t)
	out := runLockstats(t)
	assert.Equal(t, "no lock events recorded yet ("+path+")\n", out)
}

func TestDbLockstats_TextReadsBothGenerations(t *testing.T) {
	path := lockstatsTestEnv(t)
	now := time.Now().UTC()
	writeLockLog(t, path+".1", []lockmetrics.Event{
		{TS: now.Add(-2 * time.Hour), PID: 100, Proc: "daemon", Kind: lockmetrics.KindTx, HoldMS: 6000, Site: "internal/sync.(*Syncer).saveMessages"},
	})
	writeLockLog(t, path, []lockmetrics.Event{
		{TS: now.Add(-2*time.Hour + time.Second), PID: 200, Proc: "hook:session-state", Kind: lockmetrics.KindBusy,
			Site: "internal/workbench.(*Store).SetState", Err: "SQLITE_BUSY", BusyTimeoutMS: 5000},
		{TS: now.Add(-48 * time.Hour), PID: 100, Proc: "daemon", Kind: lockmetrics.KindTx, HoldMS: 1, Site: "too-old"},
	}, "{broken")

	out := runLockstats(t)
	assert.Contains(t, out, "1 malformed lines skipped")
	assert.Contains(t, out, "internal/sync.(*Syncer).saveMessages")
	assert.Contains(t, out, "held by daemon pid 100 tx internal/sync.(*Syncer).saveMessages hold 6000ms")
	assert.NotContains(t, out, "too-old", "the default --since is 24h")
}

func TestDbLockstats_JSON(t *testing.T) {
	path := lockstatsTestEnv(t)
	now := time.Now().UTC()
	writeLockLog(t, path, []lockmetrics.Event{
		{TS: now.Add(-3 * time.Hour), PID: 300, Proc: "mcp", Kind: lockmetrics.KindPoolWait, WaitMS: 250},
		{TS: now.Add(-30 * time.Minute), PID: 100, Proc: "daemon", Kind: lockmetrics.KindWAL, WALBytes: 4096, Checkpoint: "busy=0 log=3 ckpt=3"},
	})
	dbLockstatsFlagJSON = true
	dbLockstatsFlagSince = time.Hour

	var report map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(runLockstats(t)), &report))
	var keys []string
	for k := range report {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"busy", "busy_holders", "exec_sites", "malformed", "pool_wait", "procs", "sites", "wal", "window"}, keys)
	assert.JSONEq(t, `[]`, string(report["pool_wait"]), "--since 1h drops the 3h-old pool wait")
	// procs keeps the 3h-old mcp line: it tells a role that stopped writing
	// apart from a quiet one.
	var procs []struct {
		Proc   string    `json:"proc"`
		LastTS time.Time `json:"last_ts"`
		Events int       `json:"events"`
	}
	require.NoError(t, json.Unmarshal(report["procs"], &procs))
	require.Len(t, procs, 2)
	assert.Equal(t, "daemon", procs[0].Proc)
	assert.Equal(t, 1, procs[0].Events)
	assert.Equal(t, "mcp", procs[1].Proc)
	assert.Zero(t, procs[1].Events)
	assert.WithinDuration(t, now.Add(-3*time.Hour), procs[1].LastTS, time.Millisecond)
	var wal struct {
		Samples int `json:"samples"`
	}
	require.NoError(t, json.Unmarshal(report["wal"], &wal))
	assert.Equal(t, 1, wal.Samples)
}

func TestDbLockstats_RejectsNonPositiveSince(t *testing.T) {
	lockstatsTestEnv(t)
	dbLockstatsFlagSince = 0
	err := dbLockstatsCmd.RunE(dbLockstatsCmd, nil)
	require.Error(t, err)
	assert.True(t, strings.Contains(err.Error(), "--since"), err.Error())
}
