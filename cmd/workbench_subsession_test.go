package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// start_session's start in the home folder without Watchtower's install:
// a sub-session (--parent) is refused not_installed and writes no row, while
// an ordinary start there keeps starting (spec §6.5).
func TestSubSessionStartRefusesAnUninstalledHome(t *testing.T) {
	database := writeActionsConfig(t)
	ctx := context.Background()
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	home, err := database.HomeFolder(ctx, wb)
	require.NoError(t, err)
	parent, err := database.CreateTerminalSession(ctx, db.NewTerminalSession{WorkbenchID: wb, Kind: "claude",
		Title: "p", FolderPath: home.FolderPath, ClaudeSessionID: "uuid"})
	require.NoError(t, err)
	sessionHostForTest(t)
	spawnedFinishes(t)

	out, err := runSession(t, "start", "--workbench", strconv.FormatInt(wb, 10), "--agent", "claude",
		"--folder", home.Name, "--parent", strconv.FormatInt(parent, 10), "--json")
	var ec *exitCodeError
	require.ErrorAs(t, err, &ec, out)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	assert.Equal(t, map[string]any{"ok": false, "error_code": "not_installed",
		"error": "not_installed: Install Watchtower in " + home.Name + " first"}, m)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM terminal_sessions`).Scan(&n))
	assert.Equal(t, 1, n, "only the parent")

	out, err = runSession(t, "start", "--workbench", strconv.FormatInt(wb, 10), "--agent", "claude", "--json")
	require.NoError(t, err, out)
}

// start_session's start (spec 2026-11-18 §6.5) is this binary's `workbench
// session start` with the brief on stdin: stdout comes back as the answer,
// and a failed start carries its stderr.
func TestSubSessionStartRunsTheCLIWithTheBriefOnStdin(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "watchtower")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" > \"" + dir + "/args\"\n" +
		"cat > \"" + dir + "/brief\"\n" +
		"echo '{\"ok\":true,\"session_id\":5}'\n" +
		"if [ -n \"$FAIL\" ]; then echo 'Error: the session host is not running' >&2; exit 1; fi\n"
	require.NoError(t, os.WriteFile(bin, []byte(script), 0o755))
	prev := workbenchExecutable
	workbenchExecutable = func() (string, error) { return bin, nil }
	t.Cleanup(func() { workbenchExecutable = prev })

	out, err := runSubSessionStart(context.Background(), []string{"--workbench", "1", "--folder", "2", "--parent", "3"}, "the brief")
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true,"session_id":5}`, string(out))
	args, err := os.ReadFile(filepath.Join(dir, "args"))
	require.NoError(t, err)
	assert.True(t, strings.HasPrefix(string(args), "workbench\nsession\nstart\n--workbench\n1\n--folder\n2\n--parent\n3\n--config\n"),
		"args: %q", args)
	brief, err := os.ReadFile(filepath.Join(dir, "brief"))
	require.NoError(t, err)
	assert.Equal(t, "the brief", string(brief))

	t.Setenv("FAIL", "1")
	out, err = runSubSessionStart(context.Background(), nil, "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "the session host is not running")
	assert.JSONEq(t, `{"ok":true,"session_id":5}`, string(out), "stdout comes back with the failure")
}
