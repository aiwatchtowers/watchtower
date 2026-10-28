package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/llmusage"
)

// llmWiringHome points HOME and --config at a temp dir and restores the
// recorder's process-wide state afterwards.
func llmWiringHome(t *testing.T) (dataRoot string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	origConfig, origWorkspace := flagConfig, flagWorkspace
	flagConfig = filepath.Join(home, ".config", "watchtower", "config.yaml")
	flagWorkspace = ""
	t.Cleanup(func() {
		flagConfig, flagWorkspace = origConfig, origWorkspace
		llmusage.SetSpoolPath("")
		llmusage.SetFallback(nil)
		llmusage.SetLogPath("")
		llmusage.SetSink(nil)
	})
	return filepath.Join(home, ".local", "share", "watchtower") // not created: a fresh install
}

// writeWiringConfig writes a config whose active workspace is ws, at the
// current schema format so the pre-run does no upgrade.
func writeWiringConfig(t *testing.T, ws string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(flagConfig), 0o700))
	body := fmt.Sprintf("active_workspace: %s\nworkspaces:\n  %s: {}\ndb:\n  schema_format: %d\n", ws, ws, db.CurrentSchemaFormat)
	require.NoError(t, os.WriteFile(flagConfig, []byte(body), 0o600))
}

func TestSpoolPathWithoutConfig(t *testing.T) {
	root := llmWiringHome(t)
	require.NoError(t, ensureSchemaFormat(nil, nil))

	llmusage.Record(context.Background(), llmusage.Call{Purpose: "probe", Model: "m", OK: true})

	calls, err := llmusage.ReadSpool(llmusage.SpoolPath(root))
	require.NoError(t, err)
	require.Len(t, calls, 1, "the setup spool under the missing data root holds the call")
	assert.Equal(t, "probe", calls[0].Purpose)
}

func TestSpoolPathConfigWithoutWorkspaceIsTheSetupSpool(t *testing.T) {
	root := llmWiringHome(t)
	require.NoError(t, os.MkdirAll(filepath.Dir(flagConfig), 0o700))
	body := fmt.Sprintf("db:\n  schema_format: %d\n", db.CurrentSchemaFormat)
	require.NoError(t, os.WriteFile(flagConfig, []byte(body), 0o600))
	require.NoError(t, ensureSchemaFormat(nil, nil))

	llmusage.Record(context.Background(), llmusage.Call{Purpose: "probe", Model: "m", OK: true})

	calls, err := llmusage.ReadSpool(llmusage.SpoolPath(root))
	require.NoError(t, err)
	require.Len(t, calls, 1, "no workspace resolves: the setup spool holds the call")
	assert.Equal(t, "probe", calls[0].Purpose)
	assert.NoFileExists(t, filepath.Join(root, "watchtower.log"), "nothing was lost")
}

func TestSpoolPathWithConfigIsTheWorkspaceSpool(t *testing.T) {
	root := llmWiringHome(t)
	writeWiringConfig(t, "ws")
	flagWorkspace = "other" // its directory does not exist yet
	require.NoError(t, ensureSchemaFormat(nil, nil))

	llmusage.Record(context.Background(), llmusage.Call{Purpose: "chat", Model: "m", OK: true})

	calls, err := llmusage.ReadSpool(llmusage.SpoolPath(filepath.Join(root, "other")))
	require.NoError(t, err)
	assert.Len(t, calls, 1, "--workspace picks the spool")
	assert.NoFileExists(t, llmusage.SpoolPath(root), "a config never writes the setup spool")
}

func TestFallbackInsertsWhenSpoolUnwritable(t *testing.T) {
	root := llmWiringHome(t)
	writeWiringConfig(t, "ws")
	wsDir := filepath.Join(root, "ws")
	database, err := db.Open(filepath.Join(wsDir, "watchtower.db"))
	require.NoError(t, err)
	require.NoError(t, database.Close())
	spool := llmusage.SpoolPath(wsDir)
	require.NoError(t, os.WriteFile(spool, nil, 0o400))
	require.NoError(t, ensureSchemaFormat(nil, nil))

	llmusage.Record(context.Background(), llmusage.Call{Purpose: "briefing", Model: "m", OK: true})

	database, err = db.Open(filepath.Join(wsDir, "watchtower.db"))
	require.NoError(t, err)
	defer database.Close()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM llm_calls WHERE purpose = 'briefing'`).Scan(&n))
	assert.Equal(t, 1, n, "the call lands in the workspace database")
	assert.NoFileExists(t, filepath.Join(wsDir, "watchtower.log"), "nothing was lost")
}

func TestFallbackNeverCreatesADatabase(t *testing.T) {
	root := llmWiringHome(t)
	writeWiringConfig(t, "ws")
	wsDir := filepath.Join(root, "ws")
	require.NoError(t, os.MkdirAll(wsDir, 0o700))
	require.NoError(t, os.WriteFile(llmusage.SpoolPath(wsDir), nil, 0o400))
	require.NoError(t, ensureSchemaFormat(nil, nil))

	llmusage.Record(context.Background(), llmusage.Call{Purpose: "briefing", Model: "m", OK: true})

	assert.NoFileExists(t, filepath.Join(wsDir, "watchtower.db"))
	log, err := os.ReadFile(filepath.Join(wsDir, "watchtower.log"))
	require.NoError(t, err)
	assert.Contains(t, string(log), "llmusage: call not recorded (briefing,")
}

func TestNoConfigLostCallLogsUnderDataRoot(t *testing.T) {
	root := llmWiringHome(t)
	require.NoError(t, os.MkdirAll(root, 0o700))
	require.NoError(t, os.WriteFile(llmusage.SpoolPath(root), nil, 0o400))
	require.NoError(t, ensureSchemaFormat(nil, nil))

	llmusage.Record(context.Background(), llmusage.Call{Purpose: "probe", Model: "m", OK: true})

	log, err := os.ReadFile(filepath.Join(root, "watchtower.log"))
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(string(log), "llmusage: call not recorded (probe,"))
}
