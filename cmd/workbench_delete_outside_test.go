package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// PROJ-02's exception (owner decision 2026-10-14, ask #118): when the
// folder's settings.local.json links outside the folder, the removal never
// writes through it (PROJ-04), yet the delete completes and names the exact
// file holding Watchtower's hooks and what to remove by hand — on stderr and
// in --json's removal_hints.
func TestProj02_DeleteWithASettingsLinkOutsideNamesTheLeftoverHooks(t *testing.T) {
	database := writeActionsConfig(t)
	useFakeWorkbenchClaude(t)
	prev := workbenchExecutable
	workbenchExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	t.Cleanup(func() { workbenchExecutable = prev })
	folder := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(folder, ".git", "info"), 0o755))
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	p, err := database.GetWorkbench(pid)
	require.NoError(t, err)
	var out bytes.Buffer
	require.NoError(t, runWorkbenchInstall(context.Background(), &out, p), out.String())

	// The hooks now live in a file outside the folder, reached through a link.
	settings := filepath.Join(folder, ".claude", "settings.local.json")
	outside := filepath.Join(t.TempDir(), "settings.json")
	require.NoError(t, os.Rename(settings, outside))
	require.NoError(t, os.Symlink(outside, settings))
	before, err := os.ReadFile(outside)
	require.NoError(t, err)

	stdout, stderr, err := runWorkbench(t, "delete", strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err, stderr)
	var got workbenchDeleteJSON
	require.NoError(t, json.Unmarshal([]byte(stdout), &got), stdout)
	realOutside, err := filepath.EvalSymlinks(outside)
	require.NoError(t, err)
	hint := "Watchtower's hooks stay in " + realOutside + " — remove the entries marked watchtower by hand"
	assert.True(t, got.Deleted)
	assert.False(t, got.RemovalOK)
	assert.Equal(t, []string{hint}, got.RemovalHints)
	assert.Empty(t, got.RemovalError, "the hinted refusal is not repeated as an error")
	assert.Contains(t, stderr, "warning: "+hint)
	_, err = database.GetWorkbench(pid)
	assert.Error(t, err, "the workbench row is deleted anyway")
	after, err := os.ReadFile(outside)
	require.NoError(t, err)
	assert.Equal(t, string(before), string(after), "nothing is written outside the folder")
}
