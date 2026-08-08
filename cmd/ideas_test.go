package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// setupIdeasTestEnv creates a temp HOME with a config file and an empty
// workspace DB, points flagConfig at it, and returns the opened DB (the
// setupMemoryTestEnv precedent). Caller must Close() the returned DB.
func setupIdeasTestEnv(t *testing.T) *db.DB {
	t.Helper()
	tmpDir := t.TempDir()

	configPath := filepath.Join(tmpDir, "config.yaml")
	configYAML := `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
`
	require.NoError(t, os.WriteFile(configPath, []byte(configYAML), 0o600))

	wsDir := filepath.Join(tmpDir, ".local", "share", "watchtower", "test-ws")
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(filepath.Join(wsDir, "watchtower.db"))
	require.NoError(t, err)

	t.Setenv("HOME", tmpDir)
	oldFlagConfig := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = oldFlagConfig })

	return database
}

func seedIdeaRowCmd(t *testing.T, database *db.DB, idea db.Idea) int64 {
	t.Helper()
	tx, err := database.Begin()
	require.NoError(t, err)
	id, err := database.CreateIdeaTx(tx, idea)
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	return id
}

// TestIdeasList_PrintsSeededTitle verifies `ideas list` prints a seeded
// idea's title in its table output.
func TestIdeasList_PrintsSeededTitle(t *testing.T) {
	database := setupIdeasTestEnv(t)
	seedIdeaRowCmd(t, database, db.Idea{
		Kind:          "idea",
		Title:         "Ship the ideas registry CLI",
		Essence:       "Wire the daemon phase and the CLI commands.",
		Status:        "proposed",
		Source:        "mined",
		LastMentionAt: "2026-08-07T12:00:00Z",
	})
	database.Close()

	var buf bytes.Buffer
	ideasListCmd.SetOut(&buf)
	ideasListCmd.SetArgs(nil)
	require.NoError(t, ideasListCmd.Flags().Set("kind", ""))
	require.NoError(t, ideasListCmd.Flags().Set("status", ""))
	require.NoError(t, ideasListCmd.RunE(ideasListCmd, nil))

	out := buf.String()
	require.Contains(t, out, "Ship the ideas registry CLI")
	require.Contains(t, out, "proposed")
}

// TestIdeasList_KindFilter_ExcludesOtherKind verifies the --kind flag is
// passed through to the DB filter.
func TestIdeasList_KindFilter_ExcludesOtherKind(t *testing.T) {
	database := setupIdeasTestEnv(t)
	seedIdeaRowCmd(t, database, db.Idea{
		Kind: "idea", Title: "An idea", Status: "proposed", LastMentionAt: "2026-08-07T12:00:00Z",
	})
	seedIdeaRowCmd(t, database, db.Idea{
		Kind: "decision", Title: "A decision", Status: "proposed", LastMentionAt: "2026-08-07T12:00:00Z",
	})
	database.Close()

	var buf bytes.Buffer
	ideasListCmd.SetOut(&buf)
	require.NoError(t, ideasListCmd.Flags().Set("kind", "decision"))
	t.Cleanup(func() { require.NoError(t, ideasListCmd.Flags().Set("kind", "")) })
	require.NoError(t, ideasListCmd.RunE(ideasListCmd, nil))

	out := buf.String()
	require.Contains(t, out, "A decision")
	require.NotContains(t, out, "An idea")
}

// TestIdeasMine_Disabled_NoOp verifies `ideas mine` short-circuits cleanly
// (no generator call, no error) when ideas.enabled is false.
func TestIdeasMine_Disabled_NoOp(t *testing.T) {
	database := setupIdeasTestEnv(t)
	database.Close()

	configPath := flagConfig
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(configPath, append(data, []byte("ideas:\n  enabled: false\n")...), 0o600))

	var buf bytes.Buffer
	ideasMineCmd.SetOut(&buf)
	require.NoError(t, ideasMineCmd.RunE(ideasMineCmd, nil))

	require.Contains(t, buf.String(), "disabled")
}
