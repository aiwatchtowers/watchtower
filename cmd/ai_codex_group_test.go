package cmd

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// codexTreeStub is a fake codex that starts a grandchild (a background
// sleep, which a non-interactive shell runs with SIGINT ignored, holding
// codex's stdout) and waits for it. It writes the grandchild's pid to
// <dir>/grandchild once it is running.
func codexTreeStub(t *testing.T) (bin string, grandchild func() int) {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "grandchild")
	bin = filepath.Join(dir, "codex")
	script := "#!/bin/sh\n" +
		`case "$1" in --version) echo "codex-cli 0.200.0"; exit 0;; esac` + "\n" +
		"cat > /dev/null\n" +
		"sleep 30 &\n" +
		"echo $! > " + pidFile + ".tmp; mv " + pidFile + ".tmp " + pidFile + "\n" +
		"wait\n"
	require.NoError(t, os.WriteFile(bin, []byte(script), 0o755))
	grandchild = func() int {
		b, err := os.ReadFile(pidFile)
		if err != nil {
			return 0
		}
		n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
		return n
	}
	t.Cleanup(func() {
		if pid := grandchild(); pid > 0 {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	return bin, grandchild
}

// assertTreeDiesOnCancel runs one streaming query on p, cancels it once the
// stub's grandchild is up, and requires the query to end promptly with the
// grandchild dead.
func assertTreeDiesOnCancel(t *testing.T, p ai.Provider, grandchild func() int) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	textCh, errCh, sidCh := p.Query(ctx, "sys", "hi", "")
	done := make(chan struct{})
	go func() {
		for range textCh {
		}
		for range errCh {
		}
		for range sidCh {
		}
		close(done)
	}()
	require.Eventually(t, func() bool { return grandchild() > 0 }, 20*time.Second, 20*time.Millisecond)
	pid := grandchild()
	cancel()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the cancelled codex query did not end: a descendant still holds its stdout")
	}
	require.Eventually(t, func() bool {
		return syscall.Kill(pid, 0) == syscall.ESRCH
	}, 5*time.Second, 50*time.Millisecond, "codex's grandchild %d survived the cancel", pid)
}

func codexGroupTestConfig(t *testing.T, bin string) (*config.Config, *db.DB, string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CODEX_HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "codex"}, CodexPath: bin}
	dbPath := cfg.DBPath()
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return cfg, database, dbPath
}

// Stop/close of a codex chat session cancels the turn: codex's whole
// process tree dies, as the warm claude session's group does.
func TestCodexSessionClient_CancelKillsTheProcessTree(t *testing.T) {
	bin, grandchild := codexTreeStub(t)
	cfg, database, dbPath := codexGroupTestConfig(t, bin)
	c := codexSessionClient(sessionWiring{cfg: cfg, database: database, dbPath: dbPath, model: "m",
		mcpArgs: []string{"--chat", "--surface", "main"}})
	assertTreeDiesOnCancel(t, c, grandchild)
}

// `ai query` on codex — the embedded chats (--tools chat) and the
// read-folder code questions — ends the whole tree on a stop too.
func TestCodexQueryClient_CancelKillsTheProcessTree(t *testing.T) {
	oldTools, oldModel := aiFlagTools, aiFlagModel
	t.Cleanup(func() { aiFlagTools, aiFlagModel = oldTools, oldModel })
	for _, toolsFlag := range []string{"chat", ""} {
		t.Run("tools="+toolsFlag, func(t *testing.T) {
			bin, grandchild := codexTreeStub(t)
			cfg, _, dbPath := codexGroupTestConfig(t, bin)
			aiFlagTools, aiFlagModel = toolsFlag, "m"
			client, cleanup, err := newQueryClient(cfg, dbPath)
			require.NoError(t, err)
			t.Cleanup(cleanup)
			if toolsFlag == "" {
				c, ok := client.(readFolderConfigurable)
				require.True(t, ok, "%T", client)
				c.SetReadFolder(t.TempDir())
			}
			assertTreeDiesOnCancel(t, client, grandchild)
		})
	}
}
