package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/devpack"
)

type whichOut struct {
	Provider string `json:"provider"`
	Path     string `json:"path"`
	Found    bool   `json:"found"`
}

func runWhich(t *testing.T, provider string) (whichOut, string, error) {
	t.Helper()
	old := flagProvider
	flagProvider = provider
	defer func() { flagProvider = old }()
	buf := &bytes.Buffer{}
	aiWhichCmd.SetOut(buf)
	err := runAIWhich(aiWhichCmd, nil)
	var o whichOut
	if err == nil {
		require.NoError(t, json.Unmarshal(buf.Bytes(), &o))
	}
	return o, buf.String(), err
}

func tempExe(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "agent")
	require.NoError(t, os.WriteFile(p, []byte("#!/bin/sh\n"), 0o755))
	return p
}

func stubSeams(t *testing.T, claude string, codex string, codexErr error) {
	t.Helper()
	oc, ox := claudeFindBinary, codexFindBinary
	claudeFindBinary = func() string { return claude }
	codexFindBinary = func() (string, error) { return codex, codexErr }
	t.Cleanup(func() { claudeFindBinary, codexFindBinary = oc, ox })
}

func TestAIWhich_ConfiguredPath(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	exe := tempExe(t)
	f, err := os.OpenFile(flagConfig, os.O_APPEND|os.O_WRONLY, 0o600)
	require.NoError(t, err)
	_, err = f.WriteString("codex_path: " + exe + "\n")
	require.NoError(t, err)
	require.NoError(t, f.Close())
	stubSeams(t, "claude", "", devpack.ErrCodexNotFound)

	o, _, err := runWhich(t, "codex")
	require.NoError(t, err)
	assert.Equal(t, whichOut{Provider: "codex", Path: exe, Found: true}, o)
}

func TestAIWhich_NotFound(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	stubSeams(t, "claude", "", devpack.ErrCodexNotFound)

	o, _, err := runWhich(t, "claude")
	require.NoError(t, err)
	assert.Equal(t, whichOut{Provider: "claude"}, o)
	o, _, err = runWhich(t, "codex")
	require.NoError(t, err)
	assert.Equal(t, whichOut{Provider: "codex"}, o)

	stubSeams(t, "", "codex", nil)
	o, _, err = runWhich(t, "claude")
	require.NoError(t, err)
	assert.False(t, o.Found)
	o, _, err = runWhich(t, "codex")
	require.NoError(t, err)
	assert.False(t, o.Found)
}

func TestAIWhich_SeamPath(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	exe := tempExe(t)
	stubSeams(t, exe, exe, nil)

	for _, p := range []string{"claude", "codex"} {
		o, _, err := runWhich(t, p)
		require.NoError(t, err)
		assert.Equal(t, whichOut{Provider: p, Path: exe, Found: true}, o)
	}
}

func TestAIWhich_PinnedKeys(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	stubSeams(t, "claude", "", devpack.ErrCodexNotFound)

	_, raw, err := runWhich(t, "claude")
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(raw), &m))
	assert.Len(t, m, 3)
	assert.Contains(t, m, "provider")
	assert.Contains(t, m, "path")
	assert.Contains(t, m, "found")
}

func TestAIWhich_UnknownProvider(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	_, _, err := runWhich(t, "ollama")
	var ec *exitCodeError
	require.ErrorAs(t, err, &ec)
	assert.Equal(t, 2, ec.code)
}
