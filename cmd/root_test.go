package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestRootCommandHelp(t *testing.T) {
	buf := new(bytes.Buffer)
	rootCmd.SetOut(buf)
	rootCmd.SetErr(buf)
	rootCmd.SetArgs([]string{"--help"})

	err := rootCmd.Execute()
	assert.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "watchtower")
	assert.Contains(t, output, "Slack workspace into a local SQLite database")
}

func TestRootCommandPersistentFlags(t *testing.T) {
	assert.NotNil(t, rootCmd.PersistentFlags().Lookup("workspace"))
	assert.NotNil(t, rootCmd.PersistentFlags().Lookup("config"))
	assert.NotNil(t, rootCmd.PersistentFlags().Lookup("verbose"))
}

func TestDefaultConfigPath(t *testing.T) {
	path := defaultConfigPath()
	assert.Contains(t, path, ".config/watchtower/config.yaml")
}

func TestWorkspaceFlagDefault(t *testing.T) {
	flag := rootCmd.PersistentFlags().Lookup("workspace")
	assert.Equal(t, "", flag.DefValue)
}

func TestVerboseFlagDefault(t *testing.T) {
	flag := rootCmd.PersistentFlags().Lookup("verbose")
	assert.Equal(t, "false", flag.DefValue)
}

// TestRootSweepStaleTemp: the sweep every process start runs removes an old
// prompt temp file and keeps a fresh one.
func TestRootSweepStaleTemp(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	old := filepath.Join(tmp, "wt-system-prompt-old.txt")
	fresh := filepath.Join(tmp, "wt-system-prompt-new.txt")
	for _, p := range []string{old, fresh} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	past := time.Now().Add(-11 * time.Minute)
	if err := os.Chtimes(old, past, past); err != nil {
		t.Fatal(err)
	}
	sweepStaleTemp()
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Errorf("old prompt temp file survived: %v", err)
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Errorf("fresh prompt temp file removed: %v", err)
	}
}
