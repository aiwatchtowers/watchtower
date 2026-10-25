package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/automations/authoring"
	"watchtower/internal/db"
)

// TestDaemonStart_SweepsExtractSpool: the startup sweep removes the prompt
// temp leftovers and the extract spool files a killed process left, and
// keeps the fresh ones.
func TestDaemonStart_SweepsExtractSpool(t *testing.T) {
	d := newQuietDaemon(t)
	d.config.ActiveWorkspace = "test"
	t.Setenv("HOME", t.TempDir())
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	spool := filepath.Join(d.config.WorkspaceDir(), "tmp", "extract")
	require.NoError(t, os.MkdirAll(spool, 0o700))

	old := time.Now().Add(-11 * time.Minute)
	write := func(p string, at time.Time) string {
		require.NoError(t, os.WriteFile(p, []byte("x"), 0o600))
		require.NoError(t, os.Chtimes(p, at, at))
		return p
	}
	oldSpool := write(filepath.Join(spool, "att-old.pdf"), old)
	freshSpool := write(filepath.Join(spool, "att-new.pdf"), time.Now())
	oldPrompt := write(filepath.Join(tmp, "wt-chat-prompt-1.txt"), old)

	d.sweepStaleTemp()

	require.NoFileExists(t, oldSpool)
	require.NoFileExists(t, oldPrompt)
	require.FileExists(t, freshSpool)
}

// TestDaemonStart_ImportsLegacyDraftCache: an older version's draft cache
// file is in the database after startup, and gone from the workspace.
func TestDaemonStart_ImportsLegacyDraftCache(t *testing.T) {
	d := newQuietDaemon(t)
	d.config.ActiveWorkspace = "test"
	t.Setenv("HOME", t.TempDir())
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	d.db = database
	_, err = database.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (5, '', 1, 1)`)
	require.NoError(t, err)
	dir := filepath.Join(d.config.WorkspaceDir(), authoring.DraftCacheDir)
	require.NoError(t, os.MkdirAll(dir, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "5.jsonl"),
		[]byte(`{"recipe_text":"r","result":null,"at":"2026-10-20T10:00:00Z"}`+"\n"), 0o600))

	d.importLegacyDraftCache()

	got, err := database.DraftCache(5)
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.NoDirExists(t, dir)
}
