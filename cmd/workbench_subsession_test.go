package cmd

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

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
