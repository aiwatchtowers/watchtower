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

// cliTreeStub is a fake provider CLI named name (codex or claude) that
// answers --version with version and otherwise starts a grandchild (a
// background sleep, which a non-interactive shell runs with SIGINT ignored,
// holding the CLI's stdout) and waits for it. It writes its own pid to
// <dir>/stub.pid and the grandchild's to <dir>/grandchild once it is running.
func cliTreeStub(t *testing.T, name, version string) (bin string, grandchild func() int) {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "grandchild")
	stubPidFile := filepath.Join(dir, "stub.pid")
	bin = filepath.Join(dir, name)
	script := "#!/bin/sh\n" +
		`case "$1" in --version) echo "` + version + `"; exit 0;; esac` + "\n" +
		"echo $$ > " + stubPidFile + "\n" +
		"cat > /dev/null\n" +
		"sleep 30 &\n" +
		"echo $! > " + pidFile + ".tmp; mv " + pidFile + ".tmp " + pidFile + "\n" +
		"wait\n"
	require.NoError(t, os.WriteFile(bin, []byte(script), 0o755))
	readPid := func(path string) int {
		b, err := os.ReadFile(path)
		if err != nil {
			return 0
		}
		n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
		return n
	}
	grandchild = func() int { return readPid(pidFile) }
	t.Cleanup(func() {
		// The stub's group when it has one (the fixed wiring), and both
		// pids by name either way (an unfixed run left them in ours).
		var killed []int
		if pid := readPid(stubPidFile); pid > 0 {
			if pgid, err := syscall.Getpgid(pid); err == nil && pgid == pid {
				_ = syscall.Kill(-pid, syscall.SIGKILL)
			}
			_ = syscall.Kill(pid, syscall.SIGKILL)
			killed = append(killed, pid)
		}
		if pid := grandchild(); pid > 0 {
			_ = syscall.Kill(pid, syscall.SIGKILL)
			killed = append(killed, pid)
		}
		// Wait until both are gone (reaped by their parent or by init), so
		// no stub outlives the test.
		for _, pid := range killed {
			require.Eventually(t, func() bool { return syscall.Kill(pid, 0) == syscall.ESRCH },
				5*time.Second, 20*time.Millisecond, "stub process %d is still alive or unreaped after SIGKILL", pid)
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
		t.Fatal("the cancelled query did not end: a descendant still holds its stdout")
	}
	require.Eventually(t, func() bool {
		return syscall.Kill(pid, 0) == syscall.ESRCH
	}, 5*time.Second, 50*time.Millisecond, "the CLI's grandchild %d survived the cancel", pid)
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
	bin, grandchild := cliTreeStub(t, "codex", "codex-cli 0.200.0")
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
			bin, grandchild := cliTreeStub(t, "codex", "codex-cli 0.200.0")
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

// `ai query` on claude — the embedded chats (--tools chat), the read-folder
// code questions, and the same through the provider router — ends claude's
// whole tree on a stop, as the codex path does: its MCP servers and shells
// die with it.
func TestClaudeQueryClient_CancelKillsTheProcessTree(t *testing.T) {
	oldTools, oldModel := aiFlagTools, aiFlagModel
	t.Cleanup(func() { aiFlagTools, aiFlagModel = oldTools, oldModel })
	for _, tc := range []struct {
		name   string
		tools  string
		model  string
		routed bool
	}{
		{name: "tools=chat", tools: "chat", model: "m"},
		{name: "read-folder", model: "m"},
		{name: "routed tools=chat", tools: "chat", routed: true},
		{name: "routed read-folder", routed: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bin, grandchild := cliTreeStub(t, "claude", "2.1.0 (Claude Code)")
			t.Setenv("HOME", t.TempDir())
			cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "claude"}, ClaudePath: bin}
			if tc.routed {
				cfg.AI.Fallback.Enabled, cfg.AI.Fallback.Provider = true, "codex"
			}
			dbPath := cfg.DBPath()
			database, err := db.Open(dbPath)
			require.NoError(t, err)
			t.Cleanup(func() { _ = database.Close() })
			aiFlagTools, aiFlagModel = tc.tools, tc.model
			client, cleanup, err := newQueryClient(cfg, dbPath)
			require.NoError(t, err)
			t.Cleanup(cleanup)
			if tc.routed {
				_, ok := client.(*toolRouteProvider)
				require.True(t, ok, "%T", client)
			}
			if tc.tools == "" {
				c, ok := client.(readFolderConfigurable)
				require.True(t, ok, "%T", client)
				c.SetReadFolder(t.TempDir())
			}
			assertTreeDiesOnCancel(t, client, grandchild)
		})
	}
}
