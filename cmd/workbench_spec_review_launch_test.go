package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"

	"watchtower/internal/aiconsent"
	"watchtower/internal/aiconsent/aiconsenttest"
)

// No cmd test may launch the real executable, which here is the test binary.
func init() { specReviewExe = func() (string, error) { return "/usr/bin/false", nil } }

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

	require.NoError(t, LaunchSpecReview(script, 7, filepath.Join(dir, "logs"), nil))

	var pid int
	waitFor(t, "the detached child's pid", func() bool {
		b, err := os.ReadFile(pidFile)
		if err != nil || !strings.HasSuffix(string(b), "\n") {
			return false
		}
		pid, err = strconv.Atoi(strings.TrimSpace(string(b)))
		return err == nil
	})
	// Setsid makes the child a session and group leader: -pid reaps its group.
	t.Cleanup(func() {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		_ = syscall.Kill(pid, syscall.SIGKILL)
	})

	sid, err := unix.Getsid(pid)
	require.NoError(t, err)
	assert.Equal(t, pid, sid, "the reviewer leads its own session")
	assert.NotEqual(t, syscall.Getpid(), sid)
	info, err := os.Stat(filepath.Join(dir, "logs", "spec-review.log"))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
}

// captureSpecReviewStart swaps the launcher's start for one that records the
// command and starts nothing, so no reviewer outlives the test.
func captureSpecReviewStart(t *testing.T) *[]*exec.Cmd {
	t.Helper()
	var got []*exec.Cmd
	old := specReviewStart
	specReviewStart = func(c *exec.Cmd) error {
		got = append(got, c)
		return nil
	}
	t.Cleanup(func() { specReviewStart = old })
	return &got
}

// D20 (#1886): the daemon sweep's relaunch passes its origin to the
// reviewer, whose consent check then reads it; the owner's launch passes
// none and drops one this process inherited.
func TestLaunchSpecReview_SweepSetsOrigin(t *testing.T) {
	t.Setenv(aiconsent.EnvOrigin, "background")
	t.Setenv(aiconsent.EnvAdmitted, "phase:inherited")
	started := captureSpecReviewStart(t)
	logs := filepath.Join(t.TempDir(), "logs")

	require.NoError(t, LaunchSpecReview("/usr/bin/true", 7, logs, []string{aiconsent.EnvOrigin + "=background", aiconsent.EnvAdmitted + "=review:7"}))
	require.NoError(t, LaunchSpecReview("/usr/bin/true", 8, logs, nil))

	require.Len(t, *started, 2)
	sweep, owner := (*started)[0].Env, (*started)[1].Env
	assert.Contains(t, sweep, aiconsent.EnvOrigin+"=background")
	assert.Contains(t, sweep, aiconsent.EnvAdmitted+"=review:7")
	assert.NotContains(t, sweep, aiconsent.EnvAdmitted+"=phase:inherited")
	for _, kv := range owner {
		assert.False(t, strings.HasPrefix(kv, aiconsent.EnvOrigin+"=") || strings.HasPrefix(kv, aiconsent.EnvAdmitted+"="), kv)
	}
}

// The owner's process passes no origin; a process a background unit started
// (an automation's shell() running `spec-review start`) passes its own on.
func TestProcessOriginEnv(t *testing.T) {
	assert.Empty(t, processOriginEnv())
	aiconsenttest.Use(t, "cli", map[string]string{aiconsent.EnvOrigin: "background", aiconsent.EnvAdmitted: "run:3"}, false)
	assert.Equal(t, []string{aiconsent.EnvOrigin + "=background", aiconsent.EnvAdmitted + "=run:3"}, processOriginEnv())
}
