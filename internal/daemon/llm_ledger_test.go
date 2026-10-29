package daemon

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/llmusage"
)

// llmLedgerDaemon is a daemon of workspace ws under the current HOME.
func llmLedgerDaemon(t *testing.T, ws string) (*Daemon, *db.DB) {
	t.Helper()
	cfg := &config.Config{ActiveWorkspace: ws}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	database := db.OpenTestDB(t)
	d := New(cfg)
	d.SetLogger(log.New(&testLogWriter{t}, "", 0))
	d.SetDB(database)
	return d, database
}

type testLogWriter struct{ t *testing.T }

func (w *testLogWriter) Write(p []byte) (int, error) { w.t.Log(string(p)); return len(p), nil }

func writeSpool(t *testing.T, path string, at time.Time, ids ...string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	require.NoError(t, err)
	defer f.Close()
	for _, id := range ids {
		line, err := json.Marshal(llmusage.Call{CallID: id, At: at.UTC().Format(time.RFC3339),
			Surface: "watchtower", Purpose: "probe", Process: "cli:ai models", Model: "m", OK: true})
		require.NoError(t, err)
		_, err = f.Write(append(line, '\n'))
		require.NoError(t, err)
	}
}

func ledgerIDs(t *testing.T, database *db.DB) []string {
	t.Helper()
	rows, err := database.Query(`SELECT call_id FROM llm_calls ORDER BY call_id`)
	require.NoError(t, err)
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		require.NoError(t, rows.Scan(&id))
		ids = append(ids, id)
	}
	require.NoError(t, rows.Err())
	return ids
}

func setupSpoolPath(t *testing.T) string {
	t.Helper()
	root, err := config.DataRoot()
	require.NoError(t, err)
	return llmusage.SpoolPath(root)
}

func TestPhaseLLMLedgerImportsBothSpools(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d, database := llmLedgerDaemon(t, "ws")
	now := time.Now()
	wsSpool := llmusage.SpoolPath(d.config.WorkspaceDir())
	writeSpool(t, wsSpool, now, "w1", "w2")
	writeSpool(t, setupSpoolPath(t), now, "s1")

	d.phaseLLMLedger(context.Background())

	assert.Equal(t, []string{"s1", "w1", "w2"}, ledgerIDs(t, database))
	assert.NoFileExists(t, wsSpool)
	assert.NoFileExists(t, wsSpool+llmusage.ImportingSuffix)
	assert.NoFileExists(t, setupSpoolPath(t))

	// A later cycle with nothing spooled changes nothing.
	d.phaseLLMLedger(context.Background())
	assert.Len(t, ledgerIDs(t, database), 3)
}

func TestPhaseLLMLedgerSetupSpoolClaimedOnce(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	a, dbA := llmLedgerDaemon(t, "ws-a")
	b, dbB := llmLedgerDaemon(t, "ws-b")
	writeSpool(t, setupSpoolPath(t), time.Now(), "s1", "s2", "s3")

	a.phaseLLMLedger(context.Background())
	b.phaseLLMLedger(context.Background())

	assert.Equal(t, []string{"s1", "s2", "s3"}, ledgerIDs(t, dbA))
	assert.Empty(t, ledgerIDs(t, dbB), "the second workspace finds no setup spool")
	assert.NoFileExists(t, setupSpoolPath(t))

	// A line spooled after the claim goes to whichever daemon runs next.
	writeSpool(t, setupSpoolPath(t), time.Now(), "s4")
	b.phaseLLMLedger(context.Background())
	a.phaseLLMLedger(context.Background())
	assert.Equal(t, []string{"s4"}, ledgerIDs(t, dbB))
	assert.Len(t, ledgerIDs(t, dbA), 3)
}

func TestPhaseLLMLedgerPrunesDaily(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d, database := llmLedgerDaemon(t, "ws")
	old := time.Now().Add(-91 * 24 * time.Hour)
	require.NoError(t, database.InsertLLMCalls([]llmusage.Call{
		{CallID: "old1", At: old.UTC().Format(time.RFC3339), Surface: "watchtower", OK: true},
		{CallID: "new1", At: time.Now().UTC().Format(time.RFC3339), Surface: "watchtower", OK: true},
	}))

	d.phaseLLMLedger(context.Background())
	assert.Equal(t, []string{"new1"}, ledgerIDs(t, database))

	// Within a day of the last prune, an old row stays.
	require.NoError(t, database.InsertLLMCalls([]llmusage.Call{
		{CallID: "old2", At: old.UTC().Format(time.RFC3339), Surface: "watchtower", OK: true},
	}))
	d.phaseLLMLedger(context.Background())
	assert.Equal(t, []string{"new1", "old2"}, ledgerIDs(t, database))

	d.lastLLMPrune = time.Now().Add(-25 * time.Hour)
	d.phaseLLMLedger(context.Background())
	assert.Equal(t, []string{"new1"}, ledgerIDs(t, database))
}

func TestPhaseLLMLedgerUnreadableSpoolIsNotFatal(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d, database := llmLedgerDaemon(t, "ws")
	// The workspace spool's lock cannot be opened: logged, and the setup
	// spool is still imported.
	wsSpool := llmusage.SpoolPath(d.config.WorkspaceDir())
	require.NoError(t, os.MkdirAll(wsSpool+".lock", 0o700))
	writeSpool(t, setupSpoolPath(t), time.Now(), "s1")

	d.phaseLLMLedger(context.Background())
	assert.Equal(t, []string{"s1"}, ledgerIDs(t, database))
}
