package cmd

import (
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

func TestEnvWithoutAgentMarkers(t *testing.T) {
	got := envWithoutAgentMarkers([]string{"PATH=/bin", "WATCHTOWER_TERMINAL_SESSION_ID=4", "WATCHTOWER_AUTOMATION_RUN_ID=9", "HOME=/h"})
	assert.Equal(t, []string{"PATH=/bin", "HOME=/h"}, got)
}

func TestLaunchSpecReview_Detached(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := filepath.Join(dir, "fake.sh")
	// Arguments: workbench spec-review run --ask N; the stub ignores them.
	require.NoError(t, os.WriteFile(script, []byte("#!/bin/sh\necho $$ > "+pidFile+"\nsleep 5\n"), 0o700))

	require.NoError(t, LaunchSpecReview(script, 7, filepath.Join(dir, "logs")))

	var pid int
	require.Eventually(t, func() bool {
		b, err := os.ReadFile(pidFile)
		if err != nil || !strings.HasSuffix(string(b), "\n") {
			return false
		}
		pid, err = strconv.Atoi(strings.TrimSpace(string(b)))
		return err == nil
	}, 5*time.Second, 20*time.Millisecond)
	// Setsid makes the child a session and group leader: -pid reaps its group.
	t.Cleanup(func() {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		_ = syscall.Kill(pid, syscall.SIGKILL)
	})

	sid, err := syscall.Getsid(pid)
	require.NoError(t, err)
	assert.Equal(t, pid, sid, "the reviewer leads its own session")
	assert.NotEqual(t, syscall.Getpid(), sid)
	info, err := os.Stat(filepath.Join(dir, "logs", "spec-review.log"))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
}
