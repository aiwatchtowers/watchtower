package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/devpack"
)

const launchArgsTestBin = "/Users/example/Library/Application Support/Watchtower/bin/watchtower"

// setupLaunchArgs points flagConfig at a temp config (codexPath as its
// codex_path when set), fixes the watchtower binary path and makes the codex
// lookup answer find.
func setupLaunchArgs(t *testing.T, codexPath string, find func() (string, error)) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfgFile := filepath.Join(t.TempDir(), "config.yaml")
	body := "active_workspace: test\n"
	if codexPath != "" {
		body += "codex_path: " + codexPath + "\n"
	}
	require.NoError(t, os.WriteFile(cfgFile, []byte(body), 0o600))
	origCfg, origExe, origFind := flagConfig, workbenchExecutable, codexFindBinary
	flagConfig = cfgFile
	workbenchExecutable = func() (string, error) { return launchArgsTestBin, nil }
	codexFindBinary = find
	t.Cleanup(func() { flagConfig, workbenchExecutable, codexFindBinary = origCfg, origExe, origFind })
}

func runLaunchArgs(t *testing.T, args ...string) (string, int) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&bytes.Buffer{})
	rootCmd.SetArgs(append([]string{"workbench", "launch-args"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	launchArgsFlagAgent, launchArgsFlagWorkbench, launchArgsFlagJSON = "", 0, false
	code := 0
	if err != nil {
		code = 1
		var ec *exitCodeError
		if errors.As(err, &ec) {
			code = ec.code
		}
	}
	return out.String(), code
}

func writeFakeCodex(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "nvm bin", "codex")
	require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o755))
	require.NoError(t, os.WriteFile(p, []byte("#!/usr/bin/env node\n"), 0o755))
	return p
}

func decodeLaunchArgs(t *testing.T, out string) devpack.LaunchArgs {
	t.Helper()
	var la devpack.LaunchArgs
	require.NoError(t, json.Unmarshal([]byte(out), &la), out)
	return la
}

func noFind(t *testing.T) func() (string, error) {
	return func() (string, error) { t.Fatal("the codex lookup must not run"); return "", nil }
}

func TestLaunchArgs_CodexPathConfigWins(t *testing.T) {
	configured := writeFakeCodex(t)
	setupLaunchArgs(t, configured, noFind(t))
	out, code := runLaunchArgs(t, "--agent", "codex", "--workbench", "7", "--json")
	require.Equal(t, 0, code, out)
	la := decodeLaunchArgs(t, out)
	assert.Equal(t, configured, la.Binary)
	assert.Equal(t, []string{"--no-daemon", "-c", "check_for_update_on_startup=false"}, la.Args[:3],
		"the update notice would take a typed Enter as consent to npm install")
	assert.Contains(t, la.Args, `mcp_servers.watchtower-workbench.args=["mcp","--workbench","7","--agent","codex"]`)
	assert.Contains(t, la.Args, `mcp_servers.watchtower-workbench.command="`+launchArgsTestBin+`"`)
}

func TestLaunchArgs_FallsBackToFindBinary(t *testing.T) {
	found := writeFakeCodex(t)
	setupLaunchArgs(t, "", func() (string, error) { return found, nil })
	out, code := runLaunchArgs(t, "--agent", "codex", "--workbench", "7", "--json")
	require.Equal(t, 0, code, out)
	assert.Equal(t, found, decodeLaunchArgs(t, out).Binary)

	// A codex_path that names nothing falls back too.
	setupLaunchArgs(t, "/nonexistent/codex", func() (string, error) { return found, nil })
	out, code = runLaunchArgs(t, "--agent", "codex", "--workbench", "7", "--json")
	require.Equal(t, 0, code, out)
	assert.Equal(t, found, decodeLaunchArgs(t, out).Binary)
}

func TestLaunchArgs_MissingCodexExits3WithJSON(t *testing.T) {
	// codex.FindBinary answers a bare "codex" on a miss.
	for name, find := range map[string]func() (string, error){
		"bare codex": func() (string, error) { return "codex", nil },
		"stale path": func() (string, error) { return "/nonexistent/codex", nil },
	} {
		setupLaunchArgs(t, "", find)
		out, code := runLaunchArgs(t, "--agent", "codex", "--workbench", "7", "--json")
		assert.Equal(t, 3, code, name)
		assert.JSONEq(t, `{"error":"codex_not_found"}`, out, name)
	}
}

func TestLaunchArgs_PathPrependIsBinaryDir(t *testing.T) {
	found := writeFakeCodex(t)
	setupLaunchArgs(t, "", func() (string, error) { return found, nil })
	out, code := runLaunchArgs(t, "--agent", "codex", "--workbench", "7", "--json")
	require.Equal(t, 0, code, out)
	assert.Equal(t, filepath.Dir(found), decodeLaunchArgs(t, out).PathPrepend)
}

func TestLaunchArgs_UnknownAgentIsUsageError(t *testing.T) {
	setupLaunchArgs(t, "", noFind(t))
	for _, args := range [][]string{
		{"--agent", "gemini", "--workbench", "7", "--json"},
		{"--agent", "", "--workbench", "7", "--json"},
		{"--agent", "shell", "--workbench", "7", "--json"},
		{"--agent", "Codex", "--workbench", "7", "--json"},
		{"--agent", "codex", "--json"},
		{"--agent", "codex", "--workbench", "-1", "--json"},
		{"--agent", "codex", "--workbench", "7"},
	} {
		out, code := runLaunchArgs(t, args...)
		assert.Equal(t, 2, code, args)
		assert.Empty(t, out, args)
	}
}

func TestLaunchArgs_ClaudeAgentNotSupported(t *testing.T) {
	setupLaunchArgs(t, "", noFind(t))
	out, code := runLaunchArgs(t, "--agent", "claude", "--workbench", "7", "--json")
	assert.Equal(t, 2, code)
	assert.Empty(t, out)
}
