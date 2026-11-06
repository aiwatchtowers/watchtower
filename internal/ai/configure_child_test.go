package ai

import (
	"context"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestConfigureChild_AlwaysGroup pins the group-only runner (spec
// 2026-11-05 §3.4): ConfigureChild has no non-group branch, and a client
// built with no setter at all still runs its child in a process group of its
// own that a cancel reaps whole, a SIGINT-ignoring grandchild included.
func TestConfigureChild_AlwaysGroup(t *testing.T) {
	cmd := exec.Command("/usr/bin/true")
	reap := ConfigureChild(cmd)
	t.Cleanup(reap)
	require.NotNil(t, cmd.SysProcAttr)
	assert.True(t, cmd.SysProcAttr.Setpgid, "the child leads its own process group")
	assert.Equal(t, GroupKillGrace, cmd.WaitDelay)

	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := "trap '' INT\n(trap '' INT; exec sleep 60) >/dev/null 2>&1 </dev/null &\n" +
		"echo $$ > " + pidFile + ".tmp; mv " + pidFile + ".tmp " + pidFile + "\nwait\n"
	t.Cleanup(func() {
		if pid := readPid(pidFile); pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
	c := NewClient("m", "", "") // no process-group setter exists any more
	c.claudeCmd = writeMockClaude(t, script)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, _, err := c.QuerySync(ctx, "sys", "hi", "")
		done <- err
	}()
	pgid := waitPid(t, pidFile)
	cancel()
	select {
	case err := <-done:
		require.Error(t, err)
	case <-time.After(10 * time.Second):
		t.Fatal("QuerySync did not return")
	}
	requireGroupGone(t, pgid)
}
