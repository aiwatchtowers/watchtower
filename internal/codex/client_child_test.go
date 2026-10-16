package codex

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func writeStubCodex(t *testing.T, script string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "codex")
	require.NoError(t, os.WriteFile(path, []byte("#!/bin/sh\n"+script), 0o755))
	return path
}

func TestCodexQuerySync_ChildEnvReplacesEnviron(t *testing.T) {
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("SLACK_TOKEN", "xoxp-fake")
	out := filepath.Join(t.TempDir(), "env.txt")
	c := NewClient("m", "", "")
	c.codexCmd = writeStubCodex(t, "env > "+out+"\n"+
		`printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'`+"\n")
	c.SetChildEnv([]string{"HOME=/tmp/acme-home", "FOO=bar"})

	_, _, err := c.QuerySync(context.Background(), "sys", "hi", "")
	require.NoError(t, err)

	data, err := os.ReadFile(out)
	require.NoError(t, err)
	var got []string
	for _, l := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if strings.HasPrefix(l, "PWD=") || strings.HasPrefix(l, "SHLVL=") || strings.HasPrefix(l, "_=") || strings.HasPrefix(l, "OLDPWD=") {
			continue
		}
		got = append(got, l)
	}
	require.Len(t, got, 3, "env: %v", got)
	assert.Contains(t, got, "HOME=/tmp/acme-home")
	assert.Contains(t, got, "FOO=bar")
	assert.NotContains(t, strings.Join(got, "\n"), "SLACK_TOKEN")
	assert.NotContains(t, strings.Join(got, "\n"), "CLAUDECODE")
}

func TestCodexProcessGroupKilledOnCancel(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	readPid := func() int {
		b, err := os.ReadFile(pidFile)
		if err != nil {
			return 0
		}
		n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
		return n
	}
	t.Cleanup(func() {
		if pid := readPid(); pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
	c := NewClient("m", "", "")
	c.codexCmd = writeStubCodex(t, "echo $$ > "+pidFile+".tmp; mv "+pidFile+".tmp "+pidFile+"\nsleep 60 &\nwait\n")
	c.SetProcessGroup(true)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, _, err := c.QuerySync(ctx, "sys", "hi", "")
		done <- err
	}()
	require.Eventually(t, func() bool { return readPid() > 0 }, 5*time.Second, 20*time.Millisecond)
	pgid := readPid()
	cancel()
	select {
	case err := <-done:
		require.Error(t, err)
	case <-time.After(15 * time.Second):
		t.Fatal("QuerySync did not return")
	}
	require.Eventually(t, func() bool {
		return syscall.Kill(-pgid, 0) == syscall.ESRCH
	}, 10*time.Second, 50*time.Millisecond, "process group %d still alive", pgid)
}
